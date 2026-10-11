import AppKit
import SwiftUI
import Testing
import WebKit
@testable import DieterMac

@MainActor private final class ConversationBrowserNavigationAction: WKNavigationAction {
    let destination: URL
    let kind: WKNavigationType

    init(destination: URL, kind: WKNavigationType) {
        self.destination = destination
        self.kind = kind
        super.init()
    }

    override var request: URLRequest { URLRequest(url: destination) }
    override var navigationType: WKNavigationType { kind }
    override var targetFrame: WKFrameInfo? { nil }
}

@Test @MainActor func claudeBrowserTabsStayOnClaudeAndShowArtifactFrames() throws {
    let browser = ConversationBrowserModel()
    browser.session = .claude
    var opened: [URL] = []
    browser.shouldOpenExternally = { url, session in
        ExternalBrowserRules.opensExternally(url, session: session, entries: [])
    }
    browser.openExternally = { opened.append($0) }
    func policy(_ address: String, kind: WKNavigationType, main: Bool) throws -> WKNavigationActionPolicy {
        browser.navigationPolicy(
            for: try #require(URL(string: address)), userInitiated: kind == .linkActivated, mainFrame: main)
    }

    #expect(try policy("https://claude.ai/login", kind: .other, main: true) == .allow)
    #expect(try policy("https://claude.ai/code/artifacts", kind: .linkActivated, main: true) == .allow)
    #expect(
        try policy("https://abc.claudeusercontent.com/index.html", kind: .other, main: false) == .allow,
        "An artifact renders in a frame from its own site")
    #expect(try policy("https://example.com/docs", kind: .other, main: true) == .cancel)
    #expect(opened.isEmpty)
    #expect(browser.failure?.contains("outside claude.ai") == true)
    #expect(try policy("https://example.com/docs", kind: .linkActivated, main: true) == .cancel)
    #expect(opened.map(\.absoluteString) == ["https://example.com/docs"])
}

@Test @MainActor func onlyClaudeTabsUseThePersistentClaudeSession() {
    let claude = ConversationBrowserModel()
    claude.session = .claude
    #expect(claude.webView.configuration.websiteDataStore.isPersistent)
    #expect(claude.webView.configuration.websiteDataStore === ClaudeBrowserSession.dataStore)
    #expect(!ConversationBrowserModel().webView.configuration.websiteDataStore.isPersistent)
}

@Test @MainActor func conversationBrowserOnlyLaunchesExternalNavigationForClickedLinks() throws {
    let destination = try #require(URL(string: "https://example.com/docs"))
    for kind in [WKNavigationType.other, .linkActivated] {
        let browser = ConversationBrowserModel()
        var opened: [URL] = []
        browser.shouldOpenExternally = { url, _ in url == destination }
        browser.openExternally = { opened.append($0) }
        let action = ConversationBrowserNavigationAction(destination: destination, kind: kind)
        var policy: WKNavigationActionPolicy?
        browser.webView(browser.webView, decidePolicyFor: action) { policy = $0 }
        #expect(policy == .cancel)
        #expect(opened == (kind == .linkActivated ? [destination] : []))

        opened = []
        #expect(
            browser.webView(
                browser.webView, createWebViewWith: WKWebViewConfiguration(),
                for: action, windowFeatures: WKWindowFeatures()) == nil)
        #expect(opened == (kind == .linkActivated ? [destination] : []))
    }
}

@Test @MainActor func mountingConversationBrowserNeverLaunchesAnExternalURL() throws {
    let browser = ConversationBrowserModel()
    let destination = try #require(URL(string: "https://example.com/docs"))
    var opened: [URL] = []
    browser.shouldOpenExternally = { url, _ in url == destination }
    browser.openExternally = { opened.append($0) }

    browser.open(destination)
    browser.open(destination)
    #expect(opened.isEmpty)
    #expect(browser.currentURL == destination)
    #expect(browser.failure != nil)
    #expect(!browser.loading)

    browser.reveal(destination)
    #expect(opened == [destination], "An explicit navigation still opens the configured browser")
    browser.open(destination)
    #expect(opened == [destination], "Remounting after that click must not open it again")
    browser.openAddress(destination.absoluteString)
    #expect(opened == [destination, destination])
}

@Test @MainActor func emptyConversationBrowserPinsItsAddressBarToTheTop() async throws {
    let browser = ConversationBrowserModel()
    let host = NSHostingView(
        rootView: ConversationBrowserView(browser: browser)
            .frame(width: 640, height: 700)
    )
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }

    let address = try #require(await waitForBrowserAddress(in: host))
    let frame = address.convert(address.bounds, to: host)
    let topGap = host.isFlipped ? frame.minY - host.bounds.minY : host.bounds.maxY - frame.maxY

    #expect(topGap >= 0 && topGap < 60)
    #expect(frame.width > host.bounds.width * 0.6)
}

@MainActor private func waitForBrowserAddress(in host: NSView) async -> NSTextField? {
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if let field = browserTextFields(in: host).first(where: { $0.placeholderString == "Enter a URL" }) {
            return field
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

@MainActor private func browserTextFields(in view: NSView) -> [NSTextField] {
    var values = view.subviews.flatMap { browserTextFields(in: $0) }
    if let field = view as? NSTextField { values.insert(field, at: 0) }
    return values
}
