import AppKit
import Observation
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func contentSplitPreservesNativeTranscriptAcrossOpenResizeAndClose() async throws {
    let state = ContentSplitFixtureState()
    let host = NSHostingView(rootView: ContentSplitFixture(state: state))
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let mounted = await waitForContentSplit { nativeTranscript(host) != nil }
    #expect(mounted)
    let transcript = try #require(nativeTranscript(host))
    let originalWidth = transcript.frame.width
    let selection = NSRange(location: 6, length: 19)
    transcript.setSelectedRange(selection)

    state.presented = true
    let opened = await waitForContentSplit {
        guard let split = nativeSplit(host), split.arrangedSubviews.count == 2 else { return false }
        let available = split.bounds.width - split.dividerThickness
        return split.arrangedSubviews[0].frame.width >= 360 && split.arrangedSubviews[1].frame.width >= 320
            && split.arrangedSubviews[0].frame.width > split.arrangedSubviews[1].frame.width
            && abs(
                split.arrangedSubviews[0].frame.width
                    - available * ConversationContentSizing.conversationFraction) < 2
    }
    #expect(opened)
    #expect(nativeTranscript(host) === transcript)
    #expect(transcript.selectedRange() == selection)

    let split = try #require(nativeSplit(host))
    let targetWidth: CGFloat = 400
    split.setPosition(targetWidth, ofDividerAt: 0)
    let resized = await waitForContentSplit { abs(split.arrangedSubviews[0].frame.width - targetWidth) < 2 }
    #expect(resized)
    #expect(nativeTranscript(host) === transcript)
    #expect(transcript.selectedRange() == selection)

    state.content = "Another content renderer"
    try? await Task.sleep(for: .milliseconds(150))
    #expect(
        abs(split.arrangedSubviews[0].frame.width - targetWidth) < 2,
        "Changing the presented content must preserve the user's divider position")
    #expect(nativeTranscript(host) === transcript)
    #expect(transcript.selectedRange() == selection)

    state.presented = false
    let closed = await waitForContentSplit {
        nativeSplit(host)?.arrangedSubviews.count == 1 && abs(transcript.frame.width - originalWidth) < 2
    }
    #expect(closed)
    #expect(nativeTranscript(host) === transcript)
    #expect(transcript.selectedRange() == selection)
}

@Test @MainActor func paneOwnedTitlebarsResizeInTheSameNativeLayoutPassAsTheirColumns() async throws {
    let controller = ConversationPaneOwnedSplitController()
    controller.chatColumn.titlebarHost.rootView = AnyView(Text("Conversation controls"))
    controller.chatColumn.contentHost.rootView = AnyView(Text("Conversation"))
    controller.workspaceColumn.titlebarHost.rootView = AnyView(Text("Workspace controls"))
    controller.workspaceColumn.contentHost.rootView = AnyView(Text("Workspace"))
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: 1_200, height: 760),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = NSToolbar(identifier: "ConversationContentSplitTests.pane-titlebars")
    window.toolbarStyle = .unified
    window.contentViewController = controller
    window.orderBack(nil)
    defer { window.close() }

    controller.setPresented(true)
    let mounted = await waitForContentSplit {
        window.contentView?.layoutSubtreeIfNeeded()
        return !controller.workspaceItem.isCollapsed
            && controller.chatColumn.titlebarHost.frame.height > 0
            && controller.workspaceColumn.titlebarHost.frame.height > 0
    }
    #expect(mounted)

    let split = controller.splitView
    split.setPosition(525, ofDividerAt: 0)
    split.layoutSubtreeIfNeeded()
    controller.view.layoutSubtreeIfNeeded()

    let chatColumn = controller.chatColumn.view.convert(
        controller.chatColumn.view.bounds, to: controller.view)
    let chatTitlebar = controller.chatColumn.titlebarHost.convert(
        controller.chatColumn.titlebarHost.bounds, to: controller.view)
    let workspaceColumn = controller.workspaceColumn.view.convert(
        controller.workspaceColumn.view.bounds, to: controller.view)
    let workspaceTitlebar = controller.workspaceColumn.titlebarHost.convert(
        controller.workspaceColumn.titlebarHost.bounds, to: controller.view)

    #expect(abs(chatColumn.width - split.arrangedSubviews[0].frame.width) < 1)
    #expect(abs(chatTitlebar.minX - chatColumn.minX) < 1)
    #expect(abs(chatTitlebar.maxX - chatColumn.maxX) < 1)
    #expect(abs(chatTitlebar.height - 40) < 1)
    #expect(controller.chatColumn.titlebarHost.safeAreaInsets.top == 0)
    #expect(controller.chatColumn.titlebarHost.safeAreaRect == controller.chatColumn.titlebarHost.bounds)
    #expect(abs(workspaceTitlebar.minX - workspaceColumn.minX) < 1)
    #expect(abs(workspaceTitlebar.maxX - workspaceColumn.maxX) < 1)
    #expect(abs(workspaceTitlebar.height - 40) < 1)
    #expect(controller.workspaceColumn.titlebarHost.safeAreaInsets.top == 0)
    #expect(abs(chatColumn.maxX + split.dividerThickness - workspaceColumn.minX) < 1)

    let chatHost = controller.chatColumn.contentHost
    let workspaceHost = controller.workspaceColumn.contentHost
    controller.setPresented(false)
    let collapsed = await waitForContentSplit {
        controller.workspaceItem.isCollapsed
            && controller.workspaceColumn.view.frame.width < 1
    }
    #expect(collapsed)
    controller.setPresented(true)
    let restored = await waitForContentSplit { !controller.workspaceItem.isCollapsed }
    #expect(restored)
    #expect(controller.chatColumn.contentHost === chatHost)
    #expect(controller.workspaceColumn.contentHost === workspaceHost)
}

@Test @MainActor func paneOwnedTitlebarControlsStayLeadingAlignedWhenPaneResizes() async throws {
    let host = NSHostingView(
        rootView: ConversationPaneTitlebar {
            TitlebarAlignmentProbe().frame(width: 120, height: 26)
        })
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: 720, height: 90),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }

    for width: CGFloat in [720, 900] {
        window.setContentSize(NSSize(width: width, height: 90))
        let aligned = await waitForContentSplit {
            host.layoutSubtreeIfNeeded()
            guard let probe = titlebarAlignmentProbe(in: host) else { return false }
            let frame = probe.convert(probe.bounds, to: host)
            return abs(host.bounds.width - width) < 2 && abs(frame.minX - 10) < 2
        }
        #expect(aligned, "Titlebar controls must start 10 points inside their pane at width \(width)")
    }
}

@Test @MainActor func paneOwnedSplitTracksSwiftUIPresentationWithoutLeavingAStaleWorkspace() async {
    let state = PaneOwnedSplitFixtureState()
    let host = NSHostingView(rootView: PaneOwnedSplitFixture(state: state))
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: 900, height: 640),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = NSToolbar(identifier: "ConversationContentSplitTests.presentation")
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }

    state.presented = true
    let opened = await waitForContentSplit {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let split = nativeSplit(host), split.arrangedSubviews.count == 2 else { return false }
        return split.bounds.width > 880 && split.arrangedSubviews[1].frame.width > 300
    }
    #expect(opened)

    state.presented = false
    let closed = await waitForContentSplit {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let split = nativeSplit(host), split.arrangedSubviews.count == 2 else { return false }
        return split.bounds.width > 880 && split.arrangedSubviews[0].frame.width > 880
            && split.isSubviewCollapsed(split.arrangedSubviews[1])
    }
    #expect(closed)
}

@Test @MainActor func paneOwnedConversationOnlyModeFillsItsSwiftUIParentOnFirstMount() async {
    let root = ConversationPaneOwnedSplit(presented: false) {
        Text("Conversation controls")
    } chat: {
        Text("Conversation body")
    } workspaceBar: {
        Text("Workspace controls")
    } content: {
        Text("Workspace body")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea(.container, edges: .top)

    let host = NSHostingView(rootView: root)
    let window = NSWindow(
        contentRect: NSRect(x: -3_000, y: -3_000, width: 720, height: 640),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = NSToolbar(identifier: "ConversationContentSplitTests.first-mount")
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }

    let mounted = await waitForContentSplit {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let split = nativeSplit(host), split.arrangedSubviews.count == 2 else { return false }
        return split.bounds.width > 700
            && split.arrangedSubviews[0].frame.width > 700
            && split.isSubviewCollapsed(split.arrangedSubviews[1])
    }
    #expect(mounted)
}

@MainActor @Observable private final class ContentSplitFixtureState {
    var presented = false
    var content = "Content pane"
}

@MainActor @Observable private final class PaneOwnedSplitFixtureState {
    var presented = false
}

private struct PaneOwnedSplitFixture: View {
    let state: PaneOwnedSplitFixtureState

    var body: some View {
        ConversationPaneOwnedSplit(presented: state.presented) {
            Text("Conversation controls")
        } chat: {
            Text("Conversation body")
        } workspaceBar: {
            Text("Workspace controls")
        } content: {
            Text("Workspace body")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct ContentSplitFixture: View {
    let state: ContentSplitFixtureState
    var body: some View {
        ConversationContentSplit(presented: state.presented) {
            ScrollView {
                SelectableMessageText(
                    source: "First paragraph with a selected phrase.\n\n"
                        + String(repeating: "More selectable text. ", count: 100),
                    color: .primary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } content: {
            Text(state.content).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor private func nativeTranscript(_ view: NSView) -> MessageTextView? {
    (view as? MessageTextView) ?? view.subviews.lazy.compactMap { nativeTranscript($0) }.first
}

@MainActor private func nativeSplit(_ view: NSView) -> NSSplitView? {
    (view as? NSSplitView) ?? view.subviews.lazy.compactMap { nativeSplit($0) }.first
}

private struct TitlebarAlignmentProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier("conversation.titlebar.alignment-probe")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor private func titlebarAlignmentProbe(in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == "conversation.titlebar.alignment-probe" { return view }
    return view.subviews.lazy.compactMap { titlebarAlignmentProbe(in: $0) }.first
}

@MainActor private func waitForContentSplit(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
