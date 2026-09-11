import AppKit
import UniformTypeIdentifiers
import WebKit

enum MarkdownFileExport {
    enum Format: String, CaseIterable {
        case pdf, html

        var title: String { "Export \(rawValue.uppercased())" }
        var contentType: UTType { self == .pdf ? .pdf : .html }
    }

    struct Document: Equatable {
        let name: String
        let source: String

        func filename(for format: Format) -> String {
            (name as NSString).deletingPathExtension + "." + format.rawValue
        }
    }

    @MainActor
    static func data(for document: Document, format: Format) async throws -> Data {
        let renderer = MarkdownExportRenderer()
        defer { renderer.dispose() }
        try await renderer.load()
        let body = try await renderer.render(source: document.source)
        switch format {
        case .html:
            guard let directory = MarkdownPreviewResources.directory else { throw MarkdownExportError.resources }
            let css = try String(contentsOf: directory.appendingPathComponent("app.css"), encoding: .utf8)
            return Data(html(title: document.name, body: body, stylesheet: css).utf8)
        case .pdf:
            return try await renderer.pdf(title: document.name)
        }
    }

    static func html(title: String, body: String, stylesheet: String) -> String {
        let title = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html>
            <html lang="en" data-theme="light">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
            <title>\(title)</title>
            <style>\(stylesheet)\n\(printStyles)</style>
            </head>
            <body>\(body)</body>
            </html>
            """
    }

    // Keep print colors independent of the app's theme and printer defaults.
    // Diagrams stay together; long prose, code and tables can span pages.
    static let printStyles = """
        :root { color-scheme: light; background: white; color: #242428; }
        .vega-bindings { display: none; }
        @media print {
          :root, body { background: white !important; color: #242428 !important; }
          * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          #preview { max-width: none; padding: 0; margin: 0; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid; }
          p, li { orphans: 3; widows: 3; }
          pre { white-space: pre-wrap; overflow-wrap: anywhere; overflow: visible; }
          table { display: table; width: 100%; table-layout: fixed; overflow: visible; }
          thead { display: table-header-group; }
          tr { break-inside: avoid; }
          .diagram { break-inside: avoid; overflow: visible; }
          .diagram svg { max-height: 900px; }
        }
        """
}

private enum MarkdownExportError: LocalizedError {
    case resources, navigation, rendering, timedOut, printBusy, printing

    var errorDescription: String? {
        switch self {
        case .resources: "The bundled Markdown renderer is unavailable."
        case .navigation: "The Markdown export renderer could not load."
        case .rendering: "The Markdown document could not finish rendering for export."
        case .timedOut: "Markdown export took too long. Try exporting a smaller document."
        case .printBusy: "Another print or PDF export is in progress. Try again when it finishes."
        case .printing: "The PDF could not be created."
        }
    }
}

/// The export owns its renderer and never loads or changes the on-screen preview.
@MainActor
private final class MarkdownExportRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var navigation: MarkdownExportResult<Void>?
    private var printing: CheckedContinuation<Bool, Never>?
    private var printOperation: NSPrintOperation?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(MarkdownPreviewSchemeHandler(), forURLScheme: MarkdownPreviewResources.scheme)
        // This width corresponds to A4's printable width at the browser's 96 dpi.
        let size = NSSize(width: 698, height: 1027)
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.underPageBackgroundColor = .white
        webView.appearance = NSAppearance(named: .aqua)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = webView
        window.setAccessibilityElement(false)
        super.init()
        webView.navigationDelegate = self
    }

    func load() async throws {
        let pending = MarkdownExportResult<Void>()
        navigation = pending
        defer { navigation = nil }
        try await pending.wait {
            webView.load(URLRequest(url: MarkdownPreviewResources.documentURL))
        }
    }

    func render(source: String) async throws -> String {
        let pending = MarkdownExportResult<String>()
        return try await pending.wait {
            webView.callAsyncJavaScript(
                Self.renderScript,
                arguments: ["source": source, "printCSS": MarkdownFileExport.printStyles],
                in: nil, in: .page
            ) { result in
                switch result {
                case .success(let value):
                    if let body = value as? String {
                        pending.finish(.success(body))
                    } else {
                        pending.finish(.failure(MarkdownExportError.rendering))
                    }
                case .failure(let error): pending.finish(.failure(error))
                }
            }
        }
    }

    func pdf(title: String) async throws -> Data {
        guard NSPrintOperation.current == nil else { throw MarkdownExportError.printBusy }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dieter-markdown-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("document.pdf")
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: output,
        ])
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.orientation = .portrait
        info.leftMargin = 36
        info.rightMargin = 36
        info.topMargin = 36
        info.bottomMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit's main-thread printing path is only a preview: until its
        // asynchronous page calculation returns it reports NSIntegerMax pages.
        // Real printing must use its worker thread, which waits for page data.
        operation.canSpawnSeparateThread = true
        printOperation = operation
        defer { printOperation = nil }
        let success = await withCheckedContinuation { continuation in
            printing = continuation
            operation.runModal(
                for: window, delegate: self,
                didRun: #selector(printFinished(_:success:contextInfo:)), contextInfo: nil)
        }
        guard success else { throw MarkdownExportError.printing }
        let data = try Data(contentsOf: output)
        guard data.starts(with: Data("%PDF-".utf8)) else { throw MarkdownExportError.printing }
        return data
    }

    @objc nonisolated private func printFinished(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in
            let continuation = printing
            printing = nil
            continuation?.resume(returning: success)
        }
    }

    func dispose() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigation?.finish(.failure(MarkdownExportError.rendering))
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed =
            navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url.flatMap(MarkdownPreviewResources.filename) == "index.html"
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { navigation?.finish(.failure(MarkdownExportError.navigation)) }
    }

    private static let renderScript = """
        const style = document.createElement('style');
        style.textContent = printCSS + '\\n#preview { padding: 0; max-width: none; margin: 0; }';
        document.head.append(style);
        const result = await window.dieterMarkdown.render(source, 'light', false, 1);
        const root = document.querySelector('#preview');
        if (result.stale || root?.dataset.renderState !== 'ready' || root.querySelector('[data-state="rendering"]')) {
          throw new Error('Markdown export did not finish rendering.');
        }
        const copy = root.cloneNode(true);
        copy.querySelectorAll('script, iframe, object, embed, link, meta, base, foreignObject, canvas, img, audio, video, source, input, button, select, textarea, .vega-bindings').forEach(node => node.remove());
        for (const node of [copy, ...copy.querySelectorAll('*')]) {
          for (const attribute of [...node.attributes]) {
            const name = attribute.name.toLowerCase();
            if (name.startsWith('on') || ['src', 'srcset', 'ping', 'formaction', 'contenteditable', 'data-source'].includes(name)) {
              node.removeAttribute(attribute.name);
            } else if (name === 'href' || name === 'xlink:href') {
              const value = attribute.value;
              const link = node.tagName.toLowerCase() === 'a' && /^https?:/i.test(value);
              if (!value.startsWith('#') && !link) node.removeAttribute(attribute.name);
            }
          }
        }
        copy.querySelectorAll('.diagram[data-state="error"] details').forEach(node => { node.open = true; });
        // Freeze completed SVGs before printing so resize observers cannot race pagination.
        await window.dieterMarkdown.dispose();
        root.replaceWith(copy);
        return copy.outerHTML;
        """
}

/// Web content has a deadline even if the web process never answers its callback.
@MainActor
private final class MarkdownExportResult<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadline: Task<Void, Never>?

    func wait(start: () -> Void) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    self?.finish(.failure(MarkdownExportError.timedOut))
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
