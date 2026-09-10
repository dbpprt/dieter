import AppKit
import SwiftUI
import WebKit

struct MarkdownFilePreview: View {
    let source: String
    var editing = false
    var onEdit: ((String, String) -> Bool)?
    var scrollCoordinator: MarkdownScrollCoordinator?
    @Environment(\.colorScheme) private var colorScheme
    @State private var failure: String?

    var body: some View {
        MarkdownPreviewWebView(
            source: source, theme: colorScheme == .dark ? "dark" : "light", editing: editing,
            onEdit: onEdit, scrollCoordinator: scrollCoordinator, failure: $failure
        )
        .overlay(alignment: .topLeading) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
            }
        }
        .accessibilityIdentifier("files.markdown.preview")
    }
}

enum MarkdownPreviewResources {
    static let scheme = "dieter-markdown"
    static let documentURL = URL(string: "dieter-markdown://preview/index.html")!
    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'none'; "
        + "font-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; media-src 'none'; "
        + "worker-src 'none'; base-uri 'none'; form-action 'none'"

    static var directory: URL? {
        let bundle: Bundle?
        if Bundle.main.bundleURL.pathExtension == "app" {
            // A packaged app must never depend on the development checkout's resource path.
            bundle = Bundle.main.resourceURL
                .flatMap { Bundle(url: $0.appendingPathComponent("DieterMac_DieterMac.bundle")) }
        } else {
            bundle = Bundle.module
        }
        return bundle?.url(forResource: "MarkdownPreview", withExtension: nil)
    }

    static func filename(for url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host == "preview",
            url.user == nil, url.password == nil, url.port == nil, url.query == nil
        else { return nil }
        switch url.path {
        case "", "/", "/index.html": return "index.html"
        case "/app.js": return "app.js"
        case "/app.css": return "app.css"
        default: return nil
        }
    }

    static func mimeType(for filename: String) -> String {
        switch filename {
        case "app.js": return "text/javascript"
        case "app.css": return "text/css"
        default: return "text/html"
        }
    }
}

enum MarkdownPreviewNavigation: Equatable {
    case document, externalLink, cancel

    static func decide(url: URL?, userActivated: Bool, mainFrame: Bool) -> Self {
        guard let url else { return .cancel }
        if userActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false
        {
            return .externalLink
        }
        if mainFrame, MarkdownPreviewResources.filename(for: url) == "index.html" {
            return .document
        }
        return .cancel
    }
}

/// Only the latest source/theme may report completion, including edits made while WebKit loads.
struct MarkdownPreviewRenderState {
    struct Request: Equatable {
        let revision: Int
        let source: String
        let theme: String
        let editing: Bool
    }

    private(set) var latest: Request?
    private(set) var ready = false
    private(set) var disposed = false

    mutating func update(source: String, theme: String, editing: Bool = false) -> Request? {
        guard !disposed, latest?.source != source || latest?.theme != theme || latest?.editing != editing else {
            return nil
        }
        latest = Request(revision: (latest?.revision ?? 0) + 1, source: source, theme: theme, editing: editing)
        return ready ? latest : nil
    }

    mutating func loaded() -> Request? {
        guard !disposed else { return nil }
        ready = true
        return latest
    }

    func accepts(_ revision: Int) -> Bool {
        ready && !disposed && latest?.revision == revision
    }

    /// Acknowledge an editor transaction without sending it back as a replacement.
    mutating func edited(source: String, revision: Int) -> Bool {
        guard accepts(revision), let latest, latest.editing else { return false }
        self.latest = Request(revision: revision, source: source, theme: latest.theme, editing: true)
        return true
    }

    mutating func dispose() {
        disposed = true
        ready = false
        latest = nil
    }
}

private struct MarkdownPreviewWebView: NSViewRepresentable {
    let source: String
    let theme: String
    let editing: Bool
    let onEdit: ((String, String) -> Bool)?
    let scrollCoordinator: MarkdownScrollCoordinator?
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "markdown")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(MarkdownPreviewSchemeHandler(), forURLScheme: MarkdownPreviewResources.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.underPageBackgroundColor = .windowBackgroundColor
        view.setAccessibilityLabel("Rendered Markdown")
        view.setAccessibilityIdentifier("files.markdown.webview")
        context.coordinator.view = view
        view.load(URLRequest(url: MarkdownPreviewResources.documentURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.failure = $failure
        context.coordinator.onEdit = onEdit
        context.coordinator.scrollCoordinator = scrollCoordinator
        scrollCoordinator?.attachPreview(view) { [weak coordinator = context.coordinator] progress, token in
            guard let coordinator, coordinator.state.ready, !coordinator.state.disposed else { return }
            coordinator.view?.callAsyncJavaScript(
                "return window.dieterMarkdown.setScrollProgress(progress, token)",
                arguments: ["progress": progress, "token": token], in: nil, in: .page,
                completionHandler: nil)
        }
        if let request = context.coordinator.state.update(source: source, theme: theme, editing: editing) {
            context.coordinator.render(request)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
        coordinator.onEdit = nil
        coordinator.scrollCoordinator?.detachPreview(view)
        coordinator.scrollCoordinator = nil
        coordinator.state.dispose()
        view.evaluateJavaScript("window.dieterMarkdown?.dispose()", completionHandler: nil)
        view.stopLoading()
        view.navigationDelegate = nil
        coordinator.view = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view: WKWebView?
        var failure: Binding<String?>
        var state = MarkdownPreviewRenderState()
        var onEdit: ((String, String) -> Bool)?
        weak var scrollCoordinator: MarkdownScrollCoordinator?
        private var copyPayload: MarkdownClipboardPayload?

        init(failure: Binding<String?>) { self.failure = failure }

        func render(_ request: MarkdownPreviewRenderState.Request) {
            view?.callAsyncJavaScript(
                "return await window.dieterMarkdown.render(source, theme, editing, revision)",
                arguments: [
                    "source": request.source, "theme": request.theme,
                    "editing": request.editing, "revision": request.revision,
                ],
                in: nil, in: .page
            ) { [weak self] result in
                guard let self, self.state.accepts(request.revision) else { return }
                switch result {
                case .success: self.failure.wrappedValue = nil
                case .failure: self.failure.wrappedValue = "Markdown preview could not render this document."
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard !state.disposed, message.name == "markdown", message.frameInfo.isMainFrame,
                message.webView === view,
                MarkdownPreviewResources.filename(for: message.frameInfo.request.url ?? URL(fileURLWithPath: "/"))
                    == "index.html",
                let body = message.body as? [String: Any], let type = body["type"] as? String
            else { return }
            switch type {
            case "scroll":
                guard state.ready, let progress = body["progress"] as? Double, progress.isFinite, let view else {
                    return
                }
                scrollCoordinator?.previewDidScroll(progress, view: view)
            case "change":
                guard let revision = body["revision"] as? Int, state.accepts(revision),
                    let latest = state.latest, latest.editing, let source = body["source"] as? String,
                    source != latest.source, onEdit?(source, latest.source) == true
                else { return }
                _ = state.edited(source: source, revision: revision)
            case "contextMenu":
                guard let payload = MarkdownClipboardPayload(body: body) else { return }
                copyPayload = payload
                let menu = NSMenu(title: "Markdown")
                for (title, action) in [
                    ("Copy as Rich Text", #selector(copyRichText)),
                    ("Copy as Markdown", #selector(copyMarkdown)),
                ] {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                copyPayload = nil
            default: break
            }
        }

        @objc private func copyRichText() { copyPayload?.write(to: .general, richText: true) }
        @objc private func copyMarkdown() { copyPayload?.write(to: .general, richText: false) }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let request = state.loaded() { render(request) }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let decision = MarkdownPreviewNavigation.decide(
                url: navigationAction.request.url,
                userActivated: navigationAction.navigationType == .linkActivated,
                mainFrame: navigationAction.targetFrame?.isMainFrame == true
            )
            switch decision {
            case .document: decisionHandler(.allow)
            case .externalLink:
                decisionHandler(.cancel)
                if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            case .cancel: decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showLoadingFailure(error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            showLoadingFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !state.disposed else { return }
            failure.wrappedValue = "Markdown preview stopped. Reopen the file to reload it."
        }

        private func showLoadingFailure(_ error: Error) {
            guard !state.disposed, (error as NSError).code != NSURLErrorCancelled else { return }
            failure.wrappedValue = "Markdown preview could not load its bundled renderer."
        }
    }
}

/// The renderer can read only its three bundled assets, never a project or arbitrary local URL.
@MainActor
final class MarkdownPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let filename = MarkdownPreviewResources.filename(for: url),
            let directory = MarkdownPreviewResources.directory
        else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent(filename), options: .mappedIfSafe)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "\(MarkdownPreviewResources.mimeType(for: filename)); charset=utf-8",
                    "Content-Security-Policy": MarkdownPreviewResources.contentSecurityPolicy,
                    "X-Content-Type-Options": "nosniff",
                    "X-DNS-Prefetch-Control": "off",
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
