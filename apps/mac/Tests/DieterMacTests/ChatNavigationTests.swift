import AppKit
import DieterAPI
import Observation
import SwiftUI
import Testing
@testable import DieterMac

@MainActor @Suite(.serialized)
struct ChatNavigationTests {
    @Test func allChatsKeepsItsBrowserWhenTheSelectedChatPresentsContent() async throws {
        let suite = "ChatNavigationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DieterStore(themeDefaultsOverride: defaults, restoreSync: false)
        let originalWorkspacePanelEnabled = store.conversationWorkspacePanelEnabled
        store.conversationWorkspacePanelEnabled = true
        defer { store.conversationWorkspacePanelEnabled = originalWorkspacePanelEnabled }
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
                && chatNavigationViews(host).contains { ($0 as? NSSplitView)?.arrangedSubviews.count == 2 }
        }
        #expect(opened)
        assertChatBrowser(browser, matches: originalFrame, in: host)

        await store.openConversation(cardID: chats[1].id, chat: true)
        let switched = await settleChatNavigation(host) {
            store.selectedChatID == chats[1].id && !content.isPresented(for: chats[1].id)
        }
        #expect(switched)
        assertChatBrowser(browser, matches: originalFrame, in: host)

        // Returning to A restores its workspace panel, without hiding the list
        // again or requiring the user to close the panel to navigate away.
        await store.openConversation(cardID: chats[0].id, chat: true)
        let restored = await settleChatNavigation(host) { content.isPresented(for: chats[0].id) }
        #expect(restored)
        assertChatBrowser(browser, matches: originalFrame, in: host)

        content.hide()
        _ = await settleChatNavigation(host) {
            !chatNavigationViews(host).contains { ($0 as? NSSplitView)?.arrangedSubviews.count == 2 }
        }
        assertChatBrowser(browser, matches: originalFrame, in: host)
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
                guard let split = chatNavigationViews(host).compactMap({ $0 as? NSSplitView }).first else {
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
}

@MainActor @Observable private final class ChatNavigationLayoutState {
    var presented = false
    var oversized = false
    var switches = 0
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

@MainActor private func chatNavigationWindow<Content: View>(host: NSHostingView<Content>, width: CGFloat) -> NSWindow {
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: width, height: 680),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    return window
}

@MainActor private func chatNavigationViews(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { chatNavigationViews($0) }
}

@MainActor private func navigationButton(in root: NSView) -> ChatNavigationNativeButton? {
    chatNavigationViews(root).compactMap { $0 as? ChatNavigationNativeButton }.first
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
