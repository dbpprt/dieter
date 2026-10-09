import DieterAPI
import DieterShared
import Foundation
import WebKit

/// Reads one workspace-relative file for an HTML preview: its bytes and the
/// daemon's media type.
package typealias HTMLPreviewRead = @MainActor (String) async throws -> (data: Data, mimeType: String)

/// A sandboxed preview of workspace HTML, such as a Claude Design standalone
/// export. The document loads from the shared core's private `dieter-preview:`
/// origin, so relative references resolve against its folder. Every request
/// returns here: only workspace files read through `read` are served, each
/// with the core's Content-Security-Policy, so a preview never reaches the
/// network. Cookies and storage are not kept, and a link the user clicks to an
/// HTTP(S) page opens in the system browser instead of the preview.
@MainActor package final class HTMLPreviewController: NSObject, WKNavigationDelegate, WKUIDelegate {
    package let documentPath: String
    private var documentText: String
    private let read: HTMLPreviewRead
    private let openExternally: @MainActor (URL) -> Void
    private var served = 0
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private lazy var schemeHandler = HTMLPreviewSchemeHandler(owner: self)
    package private(set) lazy var webView: WKWebView = makeWebView()

    package init(
        documentPath: String, text: String, read: @escaping HTMLPreviewRead,
        openExternally: @escaping @MainActor (URL) -> Void
    ) {
        self.documentPath = documentPath
        self.documentText = text
        self.read = read
        self.openExternally = openExternally
    }

    package var documentURL: URL {
        URL(string: SharedRules.shared.htmlPreviewDocumentUrl(documentPath: documentPath))!
    }

    /// Shows `text` as the document; its other files are read again.
    package func load(text: String) {
        documentText = text
        served = 0
        for task in tasks.values { task.cancel() }
        tasks = [:]
        webView.load(URLRequest(url: documentURL))
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: documentURL.scheme ?? "dieter-preview")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    fileprivate func start(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = SharedRules.shared.htmlPreviewResource(url: url.absoluteString)
        guard !path.isEmpty, served < Int(SharedRules.shared.htmlPreviewMaxResources()) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        served += 1
        if path == documentPath {
            Self.respond(task, url: url, path: path, data: Data(documentText.utf8), reported: "text/html")
            return
        }
        let key = ObjectIdentifier(task), read = read
        tasks[key] = Task { [weak self] in
            let outcome: Result<(data: Data, mimeType: String), Error>
            do { outcome = .success(try await read(path)) } catch { outcome = .failure(error) }
            // A stopped task must never be answered.
            guard let self, self.tasks.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
            switch outcome {
            case .success(let file): Self.respond(task, url: url, path: path, data: file.data, reported: file.mimeType)
            case .failure: task.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    fileprivate func stop(_ task: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    private static func respond(_ task: any WKURLSchemeTask, url: URL, path: String, data: Data, reported: String) {
        let type = SharedRules.shared.htmlPreviewMimeType(path: path, reported: reported)
        let textual = type.hasPrefix("text/") || type == "application/json" || type == "image/svg+xml"
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": textual ? "\(type); charset=utf-8" : type,
                "Content-Security-Policy": SharedRules.shared.htmlPreviewContentSecurityPolicy(),
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    package func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let destination = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Pages of the same export, e.g. a multi-page prototype, stay in the preview.
        if !SharedRules.shared.htmlPreviewResource(url: destination.absoluteString).isEmpty {
            decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow)
            return
        }
        if navigationAction.navigationType == .linkActivated,
            let scheme = destination.scheme?.lowercased(), scheme == "https" || scheme == "http"
        {
            openExternally(destination)
        }
        decisionHandler(.cancel)
    }

    package func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated, let destination = navigationAction.request.url,
            let scheme = destination.scheme?.lowercased(), scheme == "https" || scheme == "http"
        {
            openExternally(destination)
        }
        return nil
    }
}

/// Breaks the configuration's strong reference to its handler.
@MainActor
private final class HTMLPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var owner: HTMLPreviewController?

    init(owner: HTMLPreviewController) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let owner else {
            urlSchemeTask.didFailWithError(URLError(.cancelled))
            return
        }
        owner.start(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        owner?.stop(urlSchemeTask)
    }
}

extension CoreClient {
    /// Reads `path` in a files target for an HTML preview, through the core.
    @MainActor package func htmlPreviewRead(target: WorkspaceTarget) -> HTMLPreviewRead {
        { [weak self] path in
            guard let self else { throw CancellationError() }
            let document = try await self.dispatch {
                $0.admin = .with {
                    $0.readFile = .with {
                        $0.daemonID = target.daemonID
                        $0.projectID = target.projectID
                        $0.checkoutID = target.checkoutID
                        $0.cardID = target.conversationID
                        $0.path = path
                    }
                }
            }.fileDocument
            return (document.binary ? document.data : Data(document.content.utf8), document.mimeType)
        }
    }
}
