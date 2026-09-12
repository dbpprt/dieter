import AppKit
import Darwin
import Observation
import SwiftUI
import WebKit

/// An ordinary page renderer with its own WebKit session. It has no access to
/// the Markdown preview's resources or any native script-message handlers.
struct ConversationBrowserView: View {
    let url: URL
    var allowsLoopback = true
    @State private var browser = ConversationBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Back", systemImage: "chevron.left") { browser.webView.goBack() }
                    .disabled(!browser.canGoBack)
                    .accessibilityIdentifier("conversation.browser.back")
                Button("Forward", systemImage: "chevron.right") { browser.webView.goForward() }
                    .disabled(!browser.canGoForward)
                    .accessibilityIdentifier("conversation.browser.forward")
                Button(
                    browser.loading ? "Stop loading" : "Reload",
                    systemImage: browser.loading ? "xmark" : "arrow.clockwise"
                ) {
                    if browser.loading { browser.webView.stopLoading() } else { browser.reload() }
                }
                Text((browser.currentURL ?? url).absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help((browser.currentURL ?? url).absoluteString)
                Button("Open in default browser", systemImage: "arrow.up.forward.app") {
                    let destination = browser.currentURL ?? url
                    if ConversationBrowserModel.permits(destination) { NSWorkspace.shared.open(destination) }
                }
                .accessibilityIdentifier("conversation.browser.external")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 36)
            ZStack(alignment: .leading) {
                Divider()
                if browser.loading {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Loading page")
                }
            }
            .frame(height: 2)
            if let failure = browser.failure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(failure).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Retry") { browser.reload() }
                }
                .font(.caption)
                .padding(12)
                .background(.quaternary)
                .accessibilityIdentifier("conversation.browser.failure")
            }
            ConversationWebSurface(browser: browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: url, initial: true) { _, destination in
            browser.allowsLoopback = allowsLoopback
            browser.open(destination)
        }
        .onDisappear { browser.webView.stopLoading() }
        .accessibilityIdentifier("conversation.content.browser")
    }
}

@MainActor @Observable
final class ConversationBrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    var allowsLoopback = true
    // SwiftUI may construct discarded State initial values during parent updates.
    // Only the retained model ever creates a WebKit process and observation set.
    @ObservationIgnored private(set) lazy var webView = makeWebView()
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loading = false
    private(set) var progress = 0.0
    private(set) var currentURL: URL?
    private(set) var failure: String?
    @ObservationIgnored private var requestedURL: URL?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
        ]
        return webView
    }

    nonisolated static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        return scheme == "https" || scheme == "http"
    }

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0" || host == "::" { return true }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 { return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127 }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { bytes in
            bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                || bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127
        }
    }

    func accepts(_ url: URL) -> Bool { Self.permits(url) && (allowsLoopback || !Self.isLoopback(url)) }

    func open(_ url: URL) {
        guard requestedURL != url else { return }
        requestedURL = url
        failure = nil
        guard accepts(url) else {
            failure =
                "This address is unavailable. Remote localhost forwarding is not supported; use a reachable HTTP or HTTPS address."
            return
        }
        currentURL = url
        webView.load(URLRequest(url: url))
    }

    func reload() {
        failure = nil
        if let url = currentURL ?? requestedURL, accepts(url) {
            if webView.url == url { webView.reload() } else { webView.load(URLRequest(url: url)) }
        }
    }

    nonisolated private func scheduleRefresh() {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func refresh() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        loading = webView.isLoading
        progress = webView.estimatedProgress
        if let url = webView.url { currentURL = url }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { refresh(); return }
        failure = error.localizedDescription
        refresh()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = "The page stopped responding. Reload to try again."
        refresh()
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let destination = navigationAction.request.url, accepts(destination) else {
            if navigationAction.targetFrame?.isMainFrame != false {
                failure =
                    "This link cannot be opened here. Use a reachable HTTP or HTTPS address; remote localhost forwarding is not available."
            }
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let destination = navigationAction.request.url, accepts(destination) {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private struct ConversationWebSurface: NSViewRepresentable {
    let browser: ConversationBrowserModel

    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}
