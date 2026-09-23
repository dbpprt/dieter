import AppKit
import DieterAPI
import Observation
import SwiftUI
import Testing
@testable import DieterMac

@MainActor @Suite(.serialized)
struct ChatNavigationTests {
    @Test func conversationToolbarUsesOneRailOrTwoSidebarRails() {
        #expect(ConversationToolbarRailMode(workspacePresented: false) == .unified)
        #expect(ConversationToolbarRailMode(workspacePresented: false).railCount == 1)
        #expect(ConversationToolbarRailMode(workspacePresented: true) == .sidebar)
        #expect(ConversationToolbarRailMode(workspacePresented: true).railCount == 2)
    }

    @Test func allChatsKeepsItsBrowserWhenTheSelectedChatPresentsContent() async throws {
        let suite = "ChatNavigationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DieterStore(themeDefaultsOverride: defaults, restoreSync: false)
        var project = Dieter_V1_Project()
        project.id = "chat-navigation-\(UUID().uuidString)"
        project.name = "Navigation fixture"
        let chats = ["a", "b"].map { suffix in
            var chat = Dieter_V1_Card()
            // Local fixture IDs make selection entirely offline: no daemon,
            // connection preparation, or transcript cache is consulted.
            chat.id = "local_chat_navigation_\(suffix)"
            chat.projectID = project.id
            chat.scope = "chat"
            chat.title = "Conversation \(suffix.uppercased())"
            chat.runtime = "idle"
            return chat
        }
        store.projectDirectory[project.id] = project
        store.chats = chats
        store.state.chats = chats
        await store.openConversation(cardID: chats[0].id, chat: true)
        let content = store.conversationContext.content
        content.currentEndpointID = { _ in "navigation-fixture" }
        let host = NSHostingView(rootView: ChatsView().environment(store).defaultAppStorage(defaults))
        let window = chatNavigationWindow(host: host, width: 1_200)
        defer {
            content.hide()
            store.closeConversation()
            window.contentView = nil
            window.close()
        }

        let mounted = await settleChatNavigation(host) { chatBrowserScroll(in: host) != nil }
        #expect(mounted)
        let browser = try #require(chatBrowserScroll(in: host))
        let originalFrame = browser.convert(browser.bounds, to: host)

        content.showEmpty(conversationID: chats[0].id)
        let opened = await settleChatNavigation(host) {
            content.isPresented(for: chats[0].id)
                && chatCompanionSplit(in: host)?.arrangedSubviews.count == 2
        }
        #expect(opened)
        assertChatBrowser(browser, matches: originalFrame, in: host)

        // Exercise both detail configurations before measuring a warm switch,
        // keeping their first native layout outside the measured interval.
        await store.openConversation(cardID: chats[1].id, chat: true)
        #expect(await settleChatNavigation(host) { !content.isPresented(for: chats[1].id) })
        await store.openConversation(cardID: chats[0].id, chat: true)
        #expect(await settleChatNavigation(host) { content.isPresented(for: chats[0].id) })

        BoardRenderingDiagnostics.start()
        await store.openConversation(cardID: chats[1].id, chat: true)
        let switched = await settleChatNavigation(host) {
            store.selectedChatID == chats[1].id && !content.isPresented(for: chats[1].id)
        }
        #expect(switched)
        let changed = BoardRenderingDiagnostics.stop()
        #expect(changed["chatListBody"] == 0)
        #expect(changed["chatRowBody"] == 0)
        assertChatBrowser(browser, matches: originalFrame, in: host)

        // Returning to A restores its workspace panel, without hiding the list
        // again or requiring the user to close the panel to navigate away.
        await store.openConversation(cardID: chats[0].id, chat: true)
        let restored = await settleChatNavigation(host) { content.isPresented(for: chats[0].id) }
        #expect(restored)
        assertChatBrowser(browser, matches: originalFrame, in: host)

        content.hide()
        _ = await settleChatNavigation(host) {
            chatCompanionSplit(in: host)?.arrangedSubviews.count == 1
        }
        assertChatBrowser(browser, matches: originalFrame, in: host)
    }

    @Test func retainedDirectoryKeepsItsNativeScrollViewAndHidesInputWhileAway() async throws {
        let state = ChatNavigationLayoutState()
        state.presented = true
        let host = NSHostingView(rootView: RetainedChatDirectoryFixture(state: state))
        let window = chatNavigationWindow(host: host, width: 900)
        defer { window.contentView = nil; window.close() }
        #expect(await settleChatNavigation(host) { navigationButton(in: host) != nil })
        let button = try #require(navigationButton(in: host))
        let scroll = try #require(chatNavigationViews(host).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        let origin = scroll.contentView.bounds.origin
        for _ in 0..<3 {
            state.presented = false
            #expect(await settleChatNavigation(host) { button.isHiddenOrHasHiddenAncestor })
            state.presented = true
            #expect(await settleChatNavigation(host) { !button.isHiddenOrHasHiddenAncestor })
            #expect(navigationButton(in: host) === button)
            #expect(chatNavigationViews(host).contains { $0 === scroll })
            #expect(scroll.contentView.bounds.origin == origin)
        }
    }

    @Test(arguments: [CGFloat(760), 1_000, 1_400])
    func nestedCompanionSplitNeverPushesNavigationOutsideTheWindow(width: CGFloat) async throws {
        let suite = "ChatNavigationTests.layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(320, forKey: "dieter.chatBrowserPaneWidth")
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ChatNavigationLayoutState()
        let host = NSHostingView(rootView: ChatNavigationLayoutFixture(state: state).defaultAppStorage(defaults))
        let window = chatNavigationWindow(host: host, width: width)
        defer { window.contentView = nil; window.close() }

        let mounted = await settleChatNavigation(host) { navigationButton(in: host) != nil }
        #expect(mounted)
        let button = try #require(navigationButton(in: host))
        let original = button.convert(button.bounds, to: host)
        for (presented, oversized) in [(false, false), (true, false), (true, true), (false, true), (false, false)] {
            state.presented = presented
            state.oversized = oversized
            let settled = await settleChatNavigation(host) {
                guard let split = chatCompanionSplit(in: host) else {
                    return false
                }
                return split.arrangedSubviews.count == (presented ? 2 : 1)
                    && navigationButton(in: host) === button
                    && abs(button.convert(button.bounds, to: host).minX - original.minX) < 1
            }
            #expect(settled)
            let frame = button.convert(button.bounds, to: host)
            #expect(frame.minX >= 0 && frame.maxX <= host.bounds.maxX)
            #expect(abs(frame.minX - original.minX) < 1)
            #expect(!button.isHiddenOrHasHiddenAncestor && button.isEnabled)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            // hitTest accepts the receiver's superview coordinates, unlike
            // the frame assertions above. NSHostingView is flipped.
            let hit = host.hitTest(host.convert(point, to: host.superview))
            #expect(
                hit === button || hit?.isDescendant(of: button) == true,
                "Navigation covered: companion=\(presented), oversized=\(oversized), hit=\(String(describing: hit))")
            let count = state.switches
            button.performClick(nil)
            #expect(state.switches == count + 1)
        }
    }

    @Test func standaloneConversationAndWorkspaceNavigationRendersInsideTheNativeTitlebar() async throws {
        let suite = "ChatNavigationTests.titlebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(
            rootView: ChatTitlebarLayoutFixture()
                .toolbarVisibility(.visible, for: .windowToolbar)
                .defaultAppStorage(defaults))
        let window = chatNavigationWindow(host: host, width: 1_200, fullSizeTitlebar: true)
        defer { window.contentView = nil; window.close() }

        let mounted = await settleChatNavigation(host) {
            chatTitlebarButton("chat-titlebar-conversation-button", in: window) != nil
                && chatTitlebarButton("chat-titlebar-workspace-button", in: window) != nil
        }
        #expect(mounted)
        let conversationButton = try #require(
            chatTitlebarButton("chat-titlebar-conversation-button", in: window))
        let workspaceButton = try #require(
            chatTitlebarButton("chat-titlebar-workspace-button", in: window))
        let topInset = host.safeAreaInsets.top
        let conversationFrame = conversationButton.convert(conversationButton.bounds, to: host)
        let workspaceFrame = workspaceButton.convert(workspaceButton.bounds, to: host)
        #expect(topInset > 0)
        #expect(
            conversationFrame.minY >= 0 && conversationFrame.minY < topInset,
            "Conversation action is clipped outside the titlebar: frame=\(conversationFrame), topInset=\(topInset)")
        #expect(
            workspaceFrame.minY >= 0 && workspaceFrame.minY < topInset,
            "Workspace action is clipped outside the titlebar: frame=\(workspaceFrame), topInset=\(topInset)")
        #expect(!conversationButton.isHiddenOrHasHiddenAncestor)
        #expect(!workspaceButton.isHiddenOrHasHiddenAncestor)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
    }
}

@MainActor @Observable private final class ChatNavigationLayoutState {
    var presented = false
    var oversized = false
    var switches = 0
}

private struct RetainedChatDirectoryFixture: View {
    let state: ChatNavigationLayoutState
    var body: some View {
        RetainedWorkspacePane(active: state.presented) {
            ScrollView {
                VStack {
                    ChatNavigationButton { state.switches += 1 }.frame(width: 160, height: 32)
                    ForEach(0..<100) { Text("Chat \($0)").frame(height: 30) }
                }
            }
        }
    }
}

private struct ChatNavigationLayoutFixture: View {
    let state: ChatNavigationLayoutState
    var body: some View {
        ChatPaneSplit {
            VStack {
                ChatNavigationButton { state.switches += 1 }
                    .frame(width: 160, height: 32)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } detail: {
            ConversationContentSplit(presented: state.presented) {
                Text("Conversation").frame(maxWidth: .infinity, maxHeight: .infinity)
            } content: {
                Text("Code or Markdown").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Code and Markdown can report very wide intrinsic content. This
            // must never move the independent navigation column off-screen.
            .frame(minWidth: state.oversized ? 2_000 : 0)
        }
    }
}

private struct ChatTitlebarLayoutFixture: View {
    var body: some View {
        Color.clear
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        ChatTitlebarButton(identifier: "chat-titlebar-conversation-button")
                            .frame(width: 160, height: 30)
                        ChatTitlebarButton(identifier: "chat-titlebar-workspace-button")
                            .frame(width: 160, height: 30)
                    }
                }
            }
    }
}

private struct ChatTitlebarDetailFixture: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear
            Divider()
            Color.clear
        }
    }
}

private struct ChatNavigationButton: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> ChatNavigationNativeButton {
        let button = ChatNavigationNativeButton(title: "Switch conversation", target: nil, action: nil)
        button.target = button
        button.action = #selector(ChatNavigationNativeButton.invoke)
        button.handler = action
        return button
    }
    func updateNSView(_ button: ChatNavigationNativeButton, context: Context) { button.handler = action }
}

private final class ChatNavigationNativeButton: NSButton {
    var handler: (() -> Void)?
    @objc func invoke() { handler?() }
}

private struct ChatTitlebarButton: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Conversation action", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {}
}

@MainActor private func chatNavigationWindow<Content: View>(
    host: NSHostingView<Content>, width: CGFloat, fullSizeTitlebar: Bool = false
) -> NSWindow {
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: width, height: 680),
        styleMask: fullSizeTitlebar ? [.titled, .resizable, .fullSizeContentView] : [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    if fullSizeTitlebar {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "ChatNavigationTests.titlebar")
        window.toolbarStyle = .unified
    }
    window.contentView = host
    return window
}

@MainActor private func chatNavigationViews(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { chatNavigationViews($0) }
}

@MainActor private func navigationButton(in root: NSView) -> ChatNavigationNativeButton? {
    chatNavigationViews(root).compactMap { $0 as? ChatNavigationNativeButton }.first
}

@MainActor private func chatCompanionSplit(in root: NSView) -> NSSplitView? {
    chatNavigationViews(root).compactMap { $0 as? NSSplitView }.first {
        $0.accessibilityIdentifier() != "chats.resize-divider"
    }
}

@MainActor private func chatTitlebarButton(_ identifier: String, in window: NSWindow) -> NSButton? {
    guard let frameView = window.contentView?.superview else { return nil }
    return chatNavigationViews(frameView).compactMap { $0 as? NSButton }.first {
        $0.identifier?.rawValue == identifier
    }
}

@MainActor private func chatBrowserScroll(in host: NSView) -> NSScrollView? {
    chatNavigationViews(host).compactMap { $0 as? NSScrollView }.first { scroll in
        let frame = scroll.convert(scroll.bounds, to: host)
        return abs(frame.minX) < 2 && frame.width >= ChatPaneSizing.minimumWidth - 1
            && frame.width <= ChatPaneSizing.maximumWidth + 1 && frame.height > 200
    }
}

@MainActor private func assertChatBrowser(_ browser: NSScrollView, matches original: CGRect, in host: NSView) {
    let frame = browser.convert(browser.bounds, to: host)
    #expect(chatBrowserScroll(in: host) === browser)
    #expect(!browser.isHiddenOrHasHiddenAncestor)
    #expect(abs(frame.minX - original.minX) < 1 && abs(frame.width - original.width) < 1)
    #expect(frame.minX >= 0 && frame.maxX <= host.bounds.maxX)
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let hit = host.hitTest(host.convert(point, to: host.superview))
    #expect(hit === browser || hit?.isDescendant(of: browser) == true)
}

@MainActor private func settleChatNavigation(_ host: NSView, until predicate: () -> Bool) async -> Bool {
    var stableSamples = 0
    for _ in 0..<100 {
        try? await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
        stableSamples = predicate() ? stableSamples + 1 : 0
        if stableSamples >= 3 { return true }
    }
    return false
}
