import AppKit
import MarkdownEngine
import WebKit

struct NativeMarkdownDiagramKey: Hashable, Sendable {
    let code: String
    let language: String
    let width: Int
    let theme: String

    static func language(_ value: String) -> String? {
        switch value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "mermaid": "mermaid"
        case "vega-lite", "vegalite": "vega-lite"
        case "vega": "vega"
        default: nil
        }
    }

    var sourceID: String { language + "\n" + code }
}

/// A synchronous image provider for the native editor, backed by one asynchronous
/// offline web renderer. It never replaces or serializes the editor's source.
@MainActor
final class NativeMarkdownDiagramRenderer: RenderedCodeBlockRenderer {
    typealias Render = @MainActor (NativeMarkdownDiagramKey) async throws -> RenderedCodeBlockResult
    nonisolated let renderingDidChangeNotification: Notification.Name? =
        Notification.Name("DieterNativeMarkdownDiagram.\(UUID().uuidString)")
    private let customRender: Render?
    private let maximumEntries: Int
    private let maximumBytes: Int
    private var theme = "light"
    private var cache: [NativeMarkdownDiagramKey: CacheEntry] = [:]
    private var queue: [NativeMarkdownDiagramKey] = []
    private var placeholders: [NativeMarkdownDiagramKey: RenderedCodeBlockResult] = [:]
    private var desired: [String: NativeMarkdownDiagramKey] = [:]
    private var clock = 0
    private var generation = 0
    private var cacheRevision = 0
    private var notificationPending = false
    private var documentSource: String?
    private var isDisposed = false
    private var isActive = true
    private var renderingKey: NativeMarkdownDiagramKey?
    private var worker: Task<Void, Never>?
    private var webRenderer: NativeMarkdownDiagramWebRenderer?

    private struct CacheEntry {
        let result: RenderedCodeBlockResult
        let bytes: Int
        var used: Int
        var lastRequested: TimeInterval
    }

    init(maximumEntries: Int = 48, maximumBytes: Int = 24 * 1024 * 1024, render: Render? = nil) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1024, maximumBytes)
        customRender = render
    }

    nonisolated func render(
        code: String, language: String, availableWidth: CGFloat, theme: MarkdownEditorTheme
    ) -> RenderedCodeBlockResult? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            request(code: code, language: language, availableWidth: availableWidth)
        }
    }

    nonisolated func fingerprint() -> AnyHashable {
        guard Thread.isMainThread else { return AnyHashable(ObjectIdentifier(self)) }
        return AnyHashable(MainActor.assumeIsolated { "\(ObjectIdentifier(self)):\(theme):\(cacheRevision)" })
    }

    func updateAppearance(_ appearance: NSAppearance) {
        let next = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        guard next != theme else { return }
        theme = next
        generation &+= 1
        worker?.cancel()
        worker = nil
        renderingKey = nil
        webRenderer?.dispose()
        webRenderer = nil
        queue.removeAll()
        placeholders.removeAll()
        desired.removeAll()
        cache.removeAll()
        cacheRevision &+= 1
        notify()
    }

    /// A retained but hidden rich editor keeps its completed images and undo
    /// state, without doing background WebKit work or invalidating its layout.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startWorker()
            notify()
        } else {
            generation &+= 1
            worker?.cancel()
            worker = nil
            if let renderingKey, desired[renderingKey.sourceID] == renderingKey,
                !queue.contains(renderingKey)
            {
                queue.insert(renderingKey, at: 0)
            }
            renderingKey = nil
            webRenderer?.dispose()
            webRenderer = nil
        }
    }

    /// Remove old edit versions without reparsing Markdown. Keeping a source
    /// that also occurs in another block is safe and preserves shared previews.
    func synchronizeSource(_ source: String) {
        isDisposed = false
        guard source != documentSource else { return }
        documentSource = source
        let obsoleteActive = renderingKey.map { !source.contains($0.code) } ?? false
        let previousCount = cache.count
        cache = cache.filter { source.contains($0.key.code) }
        queue.removeAll { !source.contains($0.code) }
        placeholders = placeholders.filter { source.contains($0.key.code) }
        desired = desired.filter { source.contains($0.value.code) }
        if obsoleteActive {
            generation &+= 1
            worker?.cancel()
            worker = nil
            renderingKey = nil
            webRenderer?.dispose()
            webRenderer = nil
            startWorker()
        }
        if previousCount != cache.count {
            cacheRevision &+= 1
            notify()
        }
    }

    func dispose() {
        isDisposed = true
        generation &+= 1
        worker?.cancel()
        worker = nil
        renderingKey = nil
        webRenderer?.dispose()
        webRenderer = nil
        queue.removeAll()
        placeholders.removeAll()
        desired.removeAll()
        cache.removeAll()
        documentSource = nil
        cacheRevision &+= 1
    }

    func request(code: String, language: String, availableWidth: CGFloat) -> RenderedCodeBlockResult? {
        guard !isDisposed, let language = NativeMarkdownDiagramKey.language(language), availableWidth.isFinite,
            availableWidth > 0
        else { return nil }
        if let documentSource, !documentSource.contains(code) { return nil }
        let width = max(1, Int(min(2048, floor(availableWidth))))
        guard code.utf8.count <= 1_000_000 else {
            return placeholder(
                width: width, message: "Diagram source exceeds 1 MB. Click to edit the source.", failed: true)
        }
        let key = NativeMarkdownDiagramKey(code: code, language: language, width: width, theme: theme)
        guard isActive else { return cache[key]?.result }
        clock &+= 1
        desired[key.sourceID] = key
        if desired.count > maximumEntries * 2 + 1 {
            let retained = Set(cache.keys.map(\.sourceID) + queue.map(\.sourceID) + [key.sourceID])
            desired = desired.filter { retained.contains($0.key) }
        }
        if var entry = cache[key] {
            entry.used = clock
            entry.lastRequested = ProcessInfo.processInfo.systemUptime
            cache[key] = entry
            return entry.result
        }
        if let pending = placeholders[key] { return pending }
        // Width changes replace the same diagram, including at the cache limit.
        for old in Array(cache.keys) where old.sourceID == key.sourceID && old != key { cache[old] = nil }
        for old in queue where old.sourceID == key.sourceID && old != key { placeholders[old] = nil }
        queue.removeAll { $0.sourceID == key.sourceID && $0 != key }
        // A restyle asks for every diagram again. Keep admission stable until
        // the document/appearance changes instead of repeatedly evicting and
        // rendering all its diagrams when a document exceeds the limit.
        if cache.count + placeholders.count >= maximumEntries {
            return placeholder(width: width, message: "Preview limit reached. Click to edit this diagram's source.")
        }
        // Source strings and bitmap backing each have their own half of the
        // cache budget. An unreasonable source set falls back to editable code.
        let admitted = Set(cache.keys.map(\.sourceID) + placeholders.keys.map(\.sourceID))
        let sourceBytes = admitted.reduce(0) { $0 + $1.utf8.count }
        guard sourceBytes + key.sourceID.utf8.count <= maximumBytes / 2 else { return nil }
        let loading = placeholder(width: width, message: "Rendering \(language)… Click to edit the source.")
        placeholders[key] = loading
        queue.append(key)
        startWorker()
        return loading
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty, !isDisposed, isActive else { return }
        let epoch = generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == epoch {
                    worker = nil
                    renderingKey = nil
                }
            }
            while !queue.isEmpty, !Task.isCancelled, generation == epoch {
                let key = queue.removeFirst()
                guard desired[key.sourceID] == key else { placeholders[key] = nil; continue }
                renderingKey = key
                let result: RenderedCodeBlockResult
                do {
                    if let customRender {
                        result = try await customRender(key)
                    } else {
                        if webRenderer == nil { webRenderer = NativeMarkdownDiagramWebRenderer() }
                        result = try await webRenderer!.render(key)
                    }
                } catch {
                    guard !Task.isCancelled, generation == epoch else { return }
                    webRenderer?.dispose()
                    webRenderer = nil
                    result = placeholder(width: key.width, message: error.localizedDescription, failed: true)
                }
                guard !Task.isCancelled, generation == epoch else { return }
                renderingKey = nil
                placeholders[key] = nil
                guard desired[key.sourceID] == key else { continue }
                cacheResult(result, for: key)
                notify()
            }
        }
    }

    private func cacheResult(_ result: RenderedCodeBlockResult, for key: NativeMarkdownDiagramKey) {
        for old in Array(cache.keys) where old.sourceID == key.sourceID && old != key { cache[old] = nil }
        clock &+= 1
        cache[key] = CacheEntry(
            result: result, bytes: Self.bitmapBytes(result) + key.sourceID.utf8.count, used: clock,
            lastRequested: ProcessInfo.processInfo.systemUptime)
        // Keep every admitted preview. Only reduce bitmap density when the
        // budget is reached; changing point size would move the user's text.
        // No eviction means a restyle never starts a render/eviction loop.
        if cachedBytes > maximumBytes {
            let sources = cache.keys.reduce(0) { $0 + $1.sourceID.utf8.count }
            let bitmapBudget = max(4, (maximumBytes - sources) / cache.count)
            for (cachedKey, entry) in Array(cache) where Self.bitmapBytes(entry.result) > bitmapBudget {
                guard let reduced = Self.downsample(entry.result, maximumBytes: bitmapBudget) else { continue }
                cache[cachedKey] = CacheEntry(
                    result: reduced, bytes: Self.bitmapBytes(reduced) + cachedKey.sourceID.utf8.count,
                    used: entry.used, lastRequested: entry.lastRequested)
            }
        }
        cacheRevision &+= 1
    }

    private static func bitmapBytes(_ result: RenderedCodeBlockResult) -> Int {
        result.image.representations.map { max(1, $0.pixelsWide) * max(1, $0.pixelsHigh) * 4 }.max()
            ?? Int(result.size.width * result.size.height * 4)
    }

    private static func downsample(
        _ result: RenderedCodeBlockResult, maximumBytes: Int
    ) -> RenderedCodeBlockResult? {
        let largest = result.image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        let originalWidth = max(1, largest?.pixelsWide ?? Int(ceil(result.size.width)))
        let originalHeight = max(1, largest?.pixelsHigh ?? Int(ceil(result.size.height)))
        let scale = min(1, sqrt(Double(maximumBytes) / Double(originalWidth * originalHeight * 4)))
        let pixelBudget = max(1, maximumBytes / 4)
        let width = min(pixelBudget, max(1, Int(floor(Double(originalWidth) * scale))))
        let height = min(pixelBudget / width, max(1, Int(floor(Double(originalHeight) * scale))))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        result.image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = result.size
        let image = NSImage(size: result.size)
        image.addRepresentation(bitmap)
        image.accessibilityDescription = result.image.accessibilityDescription
        return RenderedCodeBlockResult(image: image, size: result.size)
    }

    var cachedCount: Int { cache.count }
    var cachedBytes: Int { cache.values.reduce(0) { $0 + $1.bytes } }
    var pendingCount: Int { queue.count }

    private func notify() {
        guard !notificationPending, isActive, let name = renderingDidChangeNotification else { return }
        notificationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            guard !self.isDisposed, self.isActive else { return }
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    private func placeholder(width: Int, message: String, failed: Bool = false) -> RenderedCodeBlockResult {
        let size = CGSize(width: min(width, 620), height: failed ? 84 : 62)
        let dark = theme == "dark"
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: dark ? 0.16 : 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = (failed ? "Could not render diagram\n" : "") + message
        (text as NSString).draw(
            with: NSRect(x: 12, y: 10, width: max(1, size.width - 24), height: size.height - 20),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: failed ? NSColor.systemOrange : NSColor(white: dark ? 0.76 : 0.35, alpha: 1),
                .paragraphStyle: style,
            ])
        image.unlockFocus()
        image.accessibilityDescription = text
        return RenderedCodeBlockResult(image: image, size: size)
    }
}

private enum NativeMarkdownDiagramError: LocalizedError {
    case failed(String), timedOut
    var errorDescription: String? {
        switch self {
        case .failed(let message): String(message.prefix(500))
        case .timedOut: "The diagram took too long to render. Click to edit its source."
        }
    }
}

@MainActor
private final class NativeMarkdownDiagramWebRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loaded = false
    private var navigation: NativeDiagramPending<Bool>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(MarkdownPreviewSchemeHandler(), forURLScheme: MarkdownPreviewResources.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 400), configuration: configuration)
        webView.underPageBackgroundColor = .clear
        window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setAccessibilityElement(false)
        super.init()
        webView.navigationDelegate = self
    }

    func render(_ key: NativeMarkdownDiagramKey) async throws -> RenderedCodeBlockResult {
        if !loaded {
            let pending = NativeDiagramPending<Bool>()
            navigation = pending
            defer { navigation = nil }
            loaded = try await pending.wait { webView.load(URLRequest(url: MarkdownPreviewResources.documentURL)) }
        }
        let appearance = NSAppearance(named: key.theme == "dark" ? .darkAqua : .aqua)
        window.appearance = appearance
        webView.appearance = appearance
        window.setContentSize(NSSize(width: key.width, height: 400))
        let pending = NativeDiagramPending<[Double]>()
        let dimensions = try await pending.wait {
            webView.callAsyncJavaScript(
                """
                const root = document.querySelector('#preview');
                root.style.transform = ''; root.style.transformOrigin = ''; root.style.width = '';
                const result = await window.dieterMarkdown.renderDiagram(kind, source, theme, blockID);
                if (result.stale || result.failedBlocks || !(result.width > 0 && result.height > 0)) {
                  throw new Error(result.error || 'The diagram could not render. Click to edit its source.');
                }
                const factor = Math.min(1, 1600 / result.height);
                root.style.transformOrigin = 'top left';
                root.style.transform = `scale(${factor})`;
                return [Math.min(result.width, width) * factor, result.height * factor];
                """,
                arguments: [
                    "kind": key.language, "source": key.code, "theme": key.theme,
                    "blockID": UUID().uuidString, "width": key.width,
                ], in: nil, in: .page
            ) { result in
                switch result {
                case .success(let value):
                    if let values = value as? [Double], values.count == 2 {
                        pending.finish(.success(values))
                    } else {
                        pending.finish(.failure(NativeMarkdownDiagramError.failed("Invalid diagram dimensions.")))
                    }
                case .failure(let error): pending.finish(.failure(error))
                }
            }
        }
        guard dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw NativeMarkdownDiagramError.failed("Invalid diagram dimensions.")
        }
        let size = CGSize(width: ceil(dimensions[0]), height: ceil(dimensions[1]))
        window.setContentSize(NSSize(width: key.width, height: Int(size.height)))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        let scale = min(2, sqrt(4_000_000 / (size.width * size.height)))
        configuration.snapshotWidth = NSNumber(value: Double(size.width * scale / max(1, window.backingScaleFactor)))
        let snapshot = NativeDiagramPending<NSImage>()
        let image = try await snapshot.wait {
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    snapshot.finish(.success(image))
                } else {
                    snapshot.finish(
                        .failure(error ?? NativeMarkdownDiagramError.failed("The diagram image could not be captured."))
                    )
                }
            }
        }
        image.size = size
        image.accessibilityDescription = "\(key.language) diagram. Click to edit source."
        return RenderedCodeBlockResult(image: image, size: size)
    }

    func dispose() {
        navigation?.finish(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { self.navigation?.finish(.success(true)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigation?.finish(.failure(NativeMarkdownDiagramError.failed("The diagram renderer stopped.")))
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(
            navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url.flatMap(MarkdownPreviewResources.filename) == "index.html"
                ? .allow : .cancel)
    }
}

@MainActor
private final class NativeDiagramPending<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadline: Task<Void, Never>?
    func wait(start: () -> Void) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    self?.finish(.failure(NativeMarkdownDiagramError.timedOut))
                }
                start()
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }
    func finish(_ result: Result<Value, Error>) {
        let continuation = continuation
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        continuation?.resume(with: result)
    }
}
