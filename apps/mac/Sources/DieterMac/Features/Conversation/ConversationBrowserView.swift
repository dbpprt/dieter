import AppKit
import DieterShared
import Darwin
import Observation
import SwiftUI
import WebKit

/// Ordinary pages retain a WebKit session per tab, independently of Markdown
/// previews and their native rendering bridge.
struct ConversationBrowserView: View {
    var initialURL: URL?
    var allowsLoopback = true
    private var retainedBrowser: ConversationBrowserModel?
    private var scopeID: UUID?
    @State private var ownedBrowser = ConversationBrowserModel()
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    private var browser: ConversationBrowserModel { retainedBrowser ?? ownedBrowser }

    init(url: URL, allowsLoopback: Bool = true) {
        initialURL = url
        self.allowsLoopback = allowsLoopback
    }

    init(browser: ConversationBrowserModel, initialURL: URL? = nil, scopeID: UUID? = nil) {
        self.scopeID = scopeID
        retainedBrowser = browser
        self.initialURL = initialURL
        allowsLoopback = browser.allowsLoopback
    }

    private func scopedTarget(_ name: String) -> String {
        guard let scopeID else { return "conversation.browser.\(name)" }
        return "conversation.browser.\(scopeID.uuidString).\(name)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left") { browser.webView.goBack() }
                    .disabled(!browser.canGoBack)
                    .accessibilityIdentifier("conversation.browser.back").smokeTarget("conversation.browser.back")
                    .smokeTarget(scopedTarget("back"))
                Button("Forward", systemImage: "chevron.right") { browser.webView.goForward() }
                    .disabled(!browser.canGoForward)
                    .accessibilityIdentifier("conversation.browser.forward").smokeTarget("conversation.browser.forward")
                    .smokeTarget(scopedTarget("forward"))
                Button(
                    browser.loading ? "Stop loading" : "Reload",
                    systemImage: browser.loading ? "xmark" : "arrow.clockwise"
                ) {
                    if browser.loading { browser.webView.stopLoading() } else { browser.reload() }
                }.disabled(browser.currentURL == nil)
                TextField("Enter a URL", text: $address)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($addressFocused)
                    .onSubmit {
                        browser.openAddress(address); addressFocused = false
                    }
                    .padding(.horizontal, 9).frame(height: 27)
                    .dieterCapsuleChrome(interactive: false)
                    .accessibilityLabel("Browser address")
                    .accessibilityIdentifier("conversation.browser.address").smokeTarget("conversation.browser.address")
                    .smokeTarget(scopedTarget("address"))
                Button("Open in default browser", systemImage: "arrow.up.forward.app") {
                    if let destination = browser.currentURL, browser.accepts(destination) {
                        NSWorkspace.shared.open(destination)
                    }
                }
                .disabled(browser.currentURL == nil)
                .accessibilityIdentifier("conversation.browser.external").smokeTarget("conversation.browser.external")
                .smokeTarget(scopedTarget("external"))
            }
            .labelStyle(.iconOnly).buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
            .padding(.horizontal, 10).frame(height: 38)
            ZStack(alignment: .leading) {
                Divider()
                if browser.loading {
                    ProgressView(value: browser.progress).progressViewStyle(.linear).accessibilityLabel("Loading page")
                }
            }.frame(height: 2)
            if let failure = browser.failure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(failure).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Retry") { browser.reload() }.buttonStyle(DieterBarButtonStyle(size: 26))
                }
                .font(.caption).padding(12).background(DieterTheme.tile)
                .accessibilityIdentifier("conversation.browser.failure")
            }
            if browser.currentURL != nil {
                ConversationWebSurface(browser: browser).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Browser", systemImage: "globe",
                    description: Text("Enter a web address above to browse alongside this conversation.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("conversation.browser.empty")
                .smokeTarget(scopedTarget("empty"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: initialURL, initial: true) { _, destination in
            browser.allowsLoopback = allowsLoopback
            if let destination { browser.open(destination) }
            address = browser.currentURL?.absoluteString ?? ""
        }
        .onChange(of: browser.currentURL) { _, url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .accessibilityIdentifier("conversation.content.browser")
    }
}

/// The WebKit session a workspace browser tab uses.
enum ConversationBrowserSession: Equatable {
    /// A private session that keeps no cookies or site data.
    case ephemeral
    /// The user's claude.ai session for Claude artifacts and designs, shared by
    /// every such tab and kept until they sign out in Settings.
    case claude
}

/// The persistent website data behind `ConversationBrowserSession.claude`. It
/// holds only claude.ai's own data: that session never navigates elsewhere.
@MainActor
enum ClaudeBrowserSession {
    static let identifier = UUID(uuidString: "6B7C1F0E-3D52-4C1A-9E3B-2A4D5C6E7F81")!
    static let home = URL(string: "https://claude.ai/code/artifacts")!
    private static var store: WKWebsiteDataStore?

    static var dataStore: WKWebsiteDataStore {
        if let store { return store }
        let created = WKWebsiteDataStore(forIdentifier: identifier)
        store = created
        return created
    }

    /// Signs the workspace browser out of claude.ai by removing all of its data.
    static func signOut() async {
        let store = dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }
}

@MainActor @Observable
final class ConversationBrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    var allowsLoopback = true
    /// Set before the tab first loads; the WebKit view keeps the session it started with.
    var session = ConversationBrowserSession.ephemeral
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
    @ObservationIgnored var openExternally: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var shouldOpenExternally: @MainActor (URL, ConversationBrowserSession) -> Bool = {
        ExternalBrowserRules.opensExternally($0, session: $1, entries: ExternalBrowserRules.entries())
    }

    private func routeExternally(_ url: URL, userInitiated: Bool, showsFallback: Bool = true) -> Bool {
        guard shouldOpenExternally(url, session) else { return false }
        if userInitiated {
            openExternally(url)
        } else if showsFallback {
            currentURL = url
            failure =
                session == .claude
                ? "This page is outside claude.ai. Open it using the default browser button."
                : ExternalBrowserRules.systemBrowserNotice(url)
                    ?? "Open this address using the default browser button."
        }
        return true
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = session == .claude ? ClaudeBrowserSession.dataStore : .nonPersistent()
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

    /// Whether `url` reaches this machine, as the shared core's browser rule sees it.
    nonisolated static func isLoopback(_ url: URL) -> Bool {
        SharedRules.shared.isLoopbackBrowserHost(host: url.host ?? "")
    }

    func accepts(_ url: URL) -> Bool { Self.permits(url) && (allowsLoopback || !Self.isLoopback(url)) }

    func openAddress(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if trimmed.contains("://") {
            text = trimmed
        } else if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.") || trimmed.hasPrefix("[::1]") {
            text = "http://" + trimmed
        } else {
            text = "https://" + trimmed
        }
        guard !trimmed.isEmpty, let url = URL(string: text), Self.permits(url) else {
            failure = "Enter a valid HTTP or HTTPS web address."
            return
        }
        reveal(url)
    }

    /// Explicit navigation must win even after the page navigated internally.
    /// Ordinary view remounts still use open(), preserving the tab's history.
    func reveal(_ url: URL) {
        if accepts(url), routeExternally(url, userInitiated: true) { return }
        if currentURL != url || failure != nil { requestedURL = nil }
        open(url)
    }

    func open(_ url: URL) {
        guard requestedURL != url else { return }
        failure = nil
        guard accepts(url) else {
            failure =
                "This address is unavailable. Remote localhost forwarding is not supported; use a reachable HTTP or HTTPS address."
            return
        }
        requestedURL = url
        currentURL = url
        // Mounting a retained browser tab is passive, including when the
        // user's external-browser preferences changed while it was hidden.
        if routeExternally(url, userInitiated: false) { return }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        failure = nil
        if let url = currentURL ?? requestedURL, accepts(url) {
            if routeExternally(url, userInitiated: true) { return }
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
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let policy = navigationPolicy(
            for: navigationAction.request.url, userInitiated: navigationAction.navigationType == .linkActivated,
            mainFrame: navigationAction.targetFrame?.isMainFrame != false)
        if policy == .allow, navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
        } else {
            decisionHandler(policy)
        }
    }

    /// Whether a navigation to `destination` may proceed in this tab.
    func navigationPolicy(for destination: URL?, userInitiated: Bool, mainFrame: Bool) -> WKNavigationActionPolicy {
        guard let destination, accepts(destination) else {
            if mainFrame {
                failure =
                    "This link cannot be opened here. Use a reachable HTTP or HTTPS address; remote localhost forwarding is not available."
            }
            return .cancel
        }
        // A claude.ai page shows artifacts in frames from their own sites.
        if session == .claude, !mainFrame { return .allow }
        if routeExternally(destination, userInitiated: userInitiated, showsFallback: mainFrame) { return .cancel }
        return .allow
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let destination = navigationAction.request.url, accepts(destination),
            !routeExternally(destination, userInitiated: navigationAction.navigationType == .linkActivated)
        {
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
