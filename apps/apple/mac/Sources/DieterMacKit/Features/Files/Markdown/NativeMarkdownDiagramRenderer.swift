import AppKit
import Darwin
import DieterCore
import MarkdownEngine
import WebKit

struct NativeMarkdownDiagramSource: Hashable, Sendable {
    let code: String
    let language: String
    var byteCount: Int { code.utf8.count + language.utf8.count + 1 }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.language == rhs.language else { return false }
        let contiguous = lhs.code.utf8.withContiguousStorageIfAvailable { left in
            rhs.code.utf8.withContiguousStorageIfAvailable { right in
                guard left.count == right.count else { return false }
                if left.isEmpty || left.baseAddress == right.baseAddress { return true }
                guard let first = left.baseAddress, let second = right.baseAddress else { return false }
                return memcmp(first, second, left.count) == 0
            }
        }
        if let equal = contiguous ?? nil { return equal }
        return lhs.code.compare(rhs.code, options: .literal) == .orderedSame
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        let contiguous: Void? = code.utf8.withContiguousStorageIfAvailable {
            hasher.combine(bytes: UnsafeRawBufferPointer($0))
        }
        if contiguous == nil {
            Array(code.utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
        }
    }

    func isPresent(in document: String) -> Bool {
        if code.isEmpty { return true }
        // Fences are literal source slices. Unicode-equivalent substring search
        // repeatedly scans long, similar JSON prefixes and accepts changed bytes.
        // Borrow contiguous UTF-8 storage without copying a multi-megabyte body.
        let contiguous = document.utf8.withContiguousStorageIfAvailable { body in
            code.utf8.withContiguousStorageIfAvailable { needle in
                guard needle.count <= body.count, let start = body.baseAddress, let pattern = needle.baseAddress
                else { return false }
                return memmem(start, body.count, pattern, needle.count) != nil
            }
        }
        if let found = contiguous ?? nil { return found }
        return document.range(of: code, options: .literal) != nil
    }
}

struct NativeMarkdownDiagramKey: Hashable, Sendable {
    let sourceID: NativeMarkdownDiagramSource
    let width: Int
    let theme: String
    var code: String { sourceID.code }
    var language: String { sourceID.language }

    init(code: String, language: String, width: Int, theme: String) {
        sourceID = .init(code: code, language: language)
        self.width = width
        self.theme = theme
    }

    static func language(_ value: String) -> String? {
        SharedRules.shared.markdownDiagramKind(info: value)
    }
}

/// A synchronous image provider for the native editor, backed by a bounded asynchronous
/// offline web renderer pool. It never replaces or serializes the editor's source.
@MainActor
final class NativeMarkdownDiagramRenderer: RenderedCodeBlockRenderer {
    typealias Render = @MainActor (NativeMarkdownDiagramKey) async throws -> RenderedCodeBlockResult
    nonisolated let renderingDidChangeNotification: Notification.Name? =
        Notification.Name("DieterNativeMarkdownDiagram.\(UUID().uuidString)")
    private let customRender: Render?
    private let imageCache: NativeMarkdownDiagramImageCache?
    private let imageCacheRevision: UInt64?
    private let sourceOnFailure: Bool
    private var failedSources: Set<NativeMarkdownDiagramSource> = []
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let maximumConcurrentRenders: Int
    private var theme = "light"
    private var cache: [NativeMarkdownDiagramKey: CacheEntry] = [:]
    private var queue: [NativeMarkdownDiagramKey] = []
    private var placeholders: [NativeMarkdownDiagramKey: RenderedCodeBlockResult] = [:]
    private var desired: [NativeMarkdownDiagramSource: NativeMarkdownDiagramKey] = [:]
    private var generation = 0
    private var cacheRevision = 0
    private var notificationTask: Task<Void, Never>?
    private var documentSource: String?
    private var isDisposed = false
    private var isActive = true
    private var workers: [UUID: Worker] = [:]
    private var idleRenderers: [NativeMarkdownDiagramWebRenderer] = []

    @MainActor
    private final class Worker {
        var key: NativeMarkdownDiagramKey?
        var task: Task<Void, Never>?
        var renderer: NativeMarkdownDiagramWebRenderer?

        func cancel() {
            task?.cancel()
            renderer?.dispose()
            renderer = nil
        }
    }

    private struct CacheEntry {
        let result: RenderedCodeBlockResult?
        let bytes: Int
    }

    init(
        maximumEntries: Int = 48, maximumBytes: Int = 24 * 1024 * 1024, sourceOnFailure: Bool = false,
        maximumConcurrentRenders: Int = 2, imageCache: NativeMarkdownDiagramImageCache? = nil,
        render: Render? = nil
    ) {
        self.sourceOnFailure = sourceOnFailure
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1024, maximumBytes)
        self.maximumConcurrentRenders = min(4, max(1, maximumConcurrentRenders))
        customRender = render
        self.imageCache = imageCache
        imageCacheRevision = imageCache?.revision
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

    nonisolated func shouldRevealSource(code: String, language: String) -> Bool {
        guard Thread.isMainThread, let language = NativeMarkdownDiagramKey.language(language) else { return false }
        return MainActor.assumeIsolated {
            let sourceID = NativeMarkdownDiagramSource(code: code, language: language)
            let overBudget = desired[sourceID].flatMap { cache[$0] }.map { $0.result == nil } ?? false
            return sourceOnFailure && (failedSources.contains(sourceID) || overBudget)
        }
    }

    func updateAppearance(_ appearance: NSAppearance) {
        let next = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        guard next != theme else { return }
        theme = next
        generation &+= 1
        cancelWorkers()
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
            for worker in workers.values {
                if let key = worker.key, desired[key.sourceID] == key, !queue.contains(key) {
                    queue.insert(key, at: 0)
                }
            }
            cancelWorkers()
        }
    }

    /// Remove old edit versions without reparsing Markdown. Keeping a source
    /// that also occurs in another block is safe and preserves shared previews.
    func synchronizeSource(_ source: String) {
        isDisposed = false
        // A document without diagrams has nothing to prune: keep the source
        // without comparing it, as the editor calls this on every update.
        guard !workers.isEmpty || !cache.isEmpty || !queue.isEmpty || !placeholders.isEmpty || !desired.isEmpty
        else {
            documentSource = source
            return
        }
        guard source != documentSource else { return }
        documentSource = source
        failedSources = failedSources.filter { $0.isPresent(in: source) }
        let previousCount = cache.count
        cache = cache.filter { $0.key.sourceID.isPresent(in: source) }
        queue.removeAll { !$0.sourceID.isPresent(in: source) }
        placeholders = placeholders.filter { $0.key.sourceID.isPresent(in: source) }
        desired = desired.filter { $0.value.sourceID.isPresent(in: source) }
        for (id, worker) in Array(workers) where worker.key.map({ !$0.sourceID.isPresent(in: source) }) == true {
            worker.cancel()
            workers[id] = nil
        }
        startWorker()
        if previousCount != cache.count {
            cacheRevision &+= 1
            notify()
        }
    }

    func dispose() {
        isDisposed = true
        generation &+= 1
        cancelWorkers()
        queue.removeAll()
        placeholders.removeAll()
        desired.removeAll()
        cache.removeAll()
        documentSource = nil
        failedSources.removeAll()
        cacheRevision &+= 1
    }

    func request(code: String, language: String, availableWidth: CGFloat) -> RenderedCodeBlockResult? {
        guard !isDisposed, let language = NativeMarkdownDiagramKey.language(language), availableWidth.isFinite,
            availableWidth > 0
        else { return nil }
        if let documentSource,
            !NativeMarkdownDiagramSource(code: code, language: language).isPresent(in: documentSource)
        {
            return nil
        }
        if sourceOnFailure && failedSources.contains(.init(code: code, language: language)) { return nil }
        let width = max(1, Int(min(2048, floor(availableWidth))))
        guard code.utf8.count <= 1_000_000 else {
            if sourceOnFailure { return nil }
            return placeholder(
                width: width, message: "Diagram source exceeds 1 MB. Click to edit the source.", failed: true)
        }
        let key = NativeMarkdownDiagramKey(code: code, language: language, width: width, theme: theme)
        guard isActive else { return cache[key]?.result }
        desired[key.sourceID] = key
        if desired.count > maximumEntries * 2 + 1 {
            let retained = Set(cache.keys.map(\.sourceID) + queue.map(\.sourceID) + [key.sourceID])
            desired = desired.filter { retained.contains($0.key) }
        }
        if let entry = cache[key] {
            if let result = entry.result { return result }
            return sourceOnFailure
                ? nil
                : placeholder(
                    width: width, message: "Preview memory limit reached. Click to edit this diagram's source.")
        }
        if let pending = placeholders[key] { return pending }
        // Width changes replace the same diagram, including at the cache limit.
        for old in Array(cache.keys) where old.sourceID == key.sourceID && old != key { cache[old] = nil }
        for old in Array(placeholders.keys) where old.sourceID == key.sourceID && old != key { placeholders[old] = nil }
        queue.removeAll { $0.sourceID == key.sourceID && $0 != key }
        // A restyle asks for every diagram again. Keep admission stable until
        // the document/appearance changes instead of repeatedly evicting and
        // rendering all its diagrams when a document exceeds the limit.
        if cache.count + placeholders.count >= maximumEntries {
            if sourceOnFailure { return nil }
            return placeholder(width: width, message: "Preview limit reached. Click to edit this diagram's source.")
        }
        // Source strings use at most half of the cache budget.
        // An unreasonable source set falls back to editable code.
        let admitted = Set(cache.keys.map(\.sourceID) + placeholders.keys.map(\.sourceID))
        let sourceBytes = admitted.reduce(0) { $0 + $1.byteCount }
        guard sourceBytes + key.sourceID.byteCount <= maximumBytes / 2 else { return nil }
        if imageCache?.revision == imageCacheRevision, let result = imageCache?.result(for: key) {
            cacheResult(result, for: key)
            notify(flush: true)
            if let cached = cache[key]?.result { return cached }
            return sourceOnFailure
                ? nil
                : placeholder(
                    width: width, message: "Preview memory limit reached. Click to edit this diagram's source.")
        }
        let loading = placeholder(
            width: width,
            message: sourceOnFailure ? "Rendering \(language)…" : "Rendering \(language)… Click to edit the source.")
        placeholders[key] = loading
        queue.append(key)
        startWorker()
        return loading
    }

    private func cancelWorkers() {
        notificationTask?.cancel()
        notificationTask = nil
        for worker in workers.values { worker.cancel() }
        workers.removeAll()
        for renderer in idleRenderers { renderer.dispose() }
        idleRenderers.removeAll()
    }

    private func startWorker() {
        guard !queue.isEmpty, !isDisposed, isActive else { return }
        let epoch = generation
        // Each slot owns its own WebKit page, including Mermaid's global state.
        // Overlap independent renders without racing themes or sharing a DOM.
        for _ in 0..<min(queue.count, max(0, maximumConcurrentRenders - workers.count)) {
            let id = UUID()
            let worker = Worker()
            worker.renderer = idleRenderers.popLast()
            workers[id] = worker
            worker.task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if let renderer = worker.renderer {
                        if !Task.isCancelled, generation == epoch, isActive, !isDisposed {
                            idleRenderers.append(renderer)
                        } else {
                            renderer.dispose()
                        }
                    }
                    worker.renderer = nil
                    workers[id] = nil
                }
                while !queue.isEmpty, !Task.isCancelled, generation == epoch {
                    let key = queue.removeFirst()
                    guard desired[key.sourceID] == key else { placeholders[key] = nil; continue }
                    worker.key = key
                    let result: RenderedCodeBlockResult
                    do {
                        if let customRender {
                            result = try await customRender(key)
                        } else {
                            if worker.renderer == nil { worker.renderer = NativeMarkdownDiagramWebRenderer() }
                            result = try await worker.renderer!.render(key)
                        }
                    } catch {
                        guard !Task.isCancelled, generation == epoch else { return }
                        worker.renderer?.dispose()
                        worker.renderer = nil
                        worker.key = nil
                        placeholders[key] = nil
                        // An obsolete failure must not reveal a newer width's source.
                        guard desired[key.sourceID] == key else { continue }
                        if sourceOnFailure {
                            failedSources.insert(key.sourceID)
                            cacheRevision &+= 1
                            notify(flush: queue.isEmpty && workers.values.allSatisfy { $0.key == nil })
                            continue
                        }
                        result = placeholder(width: key.width, message: error.localizedDescription, failed: true)
                    }
                    guard !Task.isCancelled, generation == epoch else { return }
                    worker.key = nil
                    placeholders[key] = nil
                    guard desired[key.sourceID] == key else { continue }
                    cacheResult(result, for: key)
                    notify(flush: queue.isEmpty && workers.values.allSatisfy { $0.key == nil })
                }
            }
        }
    }

    private func cacheResult(_ result: RenderedCodeBlockResult, for key: NativeMarkdownDiagramKey) {
        for old in Array(cache.keys) where old.sourceID == key.sourceID && old != key { cache[old] = nil }
        let bytes = Self.imageBytes(result) + key.sourceID.byteCount
        let fits = cachedBytes + bytes <= maximumBytes
        // Keep vector representations at full fidelity. Unusually complex output
        // that exceeds the byte budget falls back to source instead of silently
        // blurring every chart. Retain that decision to avoid render/retry loops.
        cache[key] = CacheEntry(
            result: fits ? result : nil, bytes: fits ? bytes : key.sourceID.byteCount)
        if fits, imageCache?.revision == imageCacheRevision { imageCache?.insert(result, for: key) }
        cacheRevision &+= 1
    }

    private static func imageBytes(_ result: RenderedCodeBlockResult) -> Int {
        result.image.representations.reduce(0) { bytes, representation in
            if let pdf = representation as? NSPDFImageRep { return bytes + pdf.pdfRepresentation.count }
            return bytes + max(1, representation.pixelsWide) * max(1, representation.pixelsHigh) * 4
        }
    }

    var failedCount: Int { failedSources.count + cache.values.filter { $0.result == nil }.count }
    var cachedCount: Int { cache.values.filter { $0.result != nil }.count }
    var cachedBytes: Int { cache.values.reduce(0) { $0 + $1.bytes } }
    var pendingCount: Int { queue.count }
    var reuseCount: Int { imageCache?.reuseCount ?? 0 }

    private func notify(flush: Bool = false) {
        guard isActive, !isDisposed, let name = renderingDidChangeNotification else { return }
        guard flush || notificationTask == nil else { return }
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            if !flush {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.notificationTask = nil
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
final class NativeMarkdownDiagramWebRenderer: NSObject, WKNavigationDelegate {
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
        // underPageBackgroundColor only controls the area behind/around the
        // page. WebKit otherwise composites a default page fill into snapshots,
        // even when the document and SVG backgrounds are transparent.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
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
        // Keep SVG paths and text as vector PDF drawing commands. A bitmap
        // snapshot fixes their resolution and forces large documents to trade
        // sharpness for cache memory. AppKit draws this representation at the
        // destination's backing scale, including when the window changes screens.
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        let capture = NativeDiagramPending<Data>()
        let data = try await capture.wait {
            webView.createPDF(configuration: configuration) { result in capture.finish(result) }
        }
        guard let representation = NSPDFImageRep(data: data) else {
            throw NativeMarkdownDiagramError.failed("The diagram image could not be captured.")
        }
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        image.cacheMode = .never
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
