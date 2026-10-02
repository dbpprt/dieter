import Foundation
import WebKit

/// The bundled Markdown renderer (`Resources/MarkdownPreview`) that exports
/// and diagram rendering load into an isolated web view.
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
