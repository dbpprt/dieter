import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Test func boardConversationWidthPreferencesStayWithinNativeLimits() {
    #expect(BoardConversationSizing.regularWidth(0) == 460)
    #expect(BoardConversationSizing.regularWidth(.nan) == 460)
    #expect(BoardConversationSizing.regularWidth(200) == 320)
    #expect(BoardConversationSizing.regularWidth(540) == 540)
    #expect(BoardConversationSizing.regularWidth(2_000) == 720)
}

@Test @MainActor func boardConversationResizesAboveAnUnchangedBoardAndRestoresItsHost() async {
    let suite = "BoardConversationOverlayTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(480, forKey: BoardConversationSizing.widthPreference)
    let controller = BoardConversationContainerController(defaults: defaults)
    controller.boardHost.rootView = AnyView(Color.blue.frame(minWidth: 1800))
    controller.inspector.conversationHost.rootView = AnyView(Text("Conversation"))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 1200, height: 800))
    defer { window.close() }

    func settle() async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(60))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    controller.setPresentation(presented: true, maximized: false)
    await settle()
    let split = controller.inspector.splitView
    let host = controller.inspector.conversationHost
    #expect(abs(host.frame.width - 480) < 2)
    #expect(controller.boardHost.frame.width == 1200)
    #expect(window.contentView?.bounds.width == 1200)

    split.setPosition(split.bounds.maxX - 560, ofDividerAt: 0)
    await settle()
    controller.inspector.rememberRegularWidth()
    #expect(abs(host.frame.width - 560) < 2)
    #expect(controller.boardHost.frame.width == 1200)
    #expect(abs(defaults.double(forKey: BoardConversationSizing.widthPreference) - 560) < 2)
    let nativeSplit = split as! BoardConversationSplitView
    let passThroughPoint = split.convert(NSPoint(x: 30, y: 200), to: split.superview)
    #expect(split.hitTest(passThroughPoint) == nil)
    let boardHit = controller.view.hitTest(passThroughPoint)
    #expect(boardHit?.isDescendant(of: controller.boardHost) == true || boardHit === controller.boardHost)
    let divider = nativeSplit.dividerTrackingRect
    let dividerPoint = split.convert(NSPoint(x: divider.midX, y: divider.midY), to: split.superview)
    #expect(split.hitTest(dividerPoint) === split)

    controller.setPresentation(presented: true, maximized: true)
    await settle()
    #expect(abs(host.frame.width - 1200) < 2)
    #expect(controller.boardHost.frame.width == 1200)
    #expect(controller.inspector.conversationHost === host)
    #expect(abs(defaults.double(forKey: BoardConversationSizing.widthPreference) - 560) < 2)

    controller.setPresentation(presented: true, maximized: false)
    await settle()
    #expect(abs(host.frame.width - 560) < 2)
    #expect(controller.inspector.conversationHost === host)
    controller.setPresentation(presented: false, maximized: false)
    #expect(host.window == nil)
    #expect(controller.boardHost.window === window)
    controller.setPresentation(presented: true, maximized: false)
    await settle()
    #expect(abs(host.frame.width - 560) < 2)
    #expect(controller.inspector.conversationHost === host)
}

@Test @MainActor func boardConversationSwiftUIStateMaximizesWithinItsParentProposal() async throws {
    let suite = "BoardConversationBridgeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(540, forKey: BoardConversationSizing.widthPreference)
    let actions = BoardConversationBridgeTestActions()
    let root = NSHostingView(rootView: BoardConversationBridgeTestView(defaults: defaults, actions: actions))
    root.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.setContentSize(NSSize(width: 1200, height: 800))
    defer { window.close() }
    root.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(150))

    var pending: [NSView] = [root]
    var found: BoardConversationSplitController?
    while let view = pending.popLast() {
        if let split = view as? NSSplitView,
            let controller = split.delegate as? BoardConversationSplitController
        {
            found = controller
            break
        }
        pending.append(contentsOf: view.subviews)
    }
    let inspector = try #require(found)
    let container = try #require(inspector.parent as? BoardConversationContainerController)
    let host = inspector.conversationHost
    #expect(abs(host.frame.width - 540) < 2)
    #expect(container.boardHost.frame.width == 1200)

    let toggle = try #require(actions.toggle)
    toggle()
    // Allow the normal SwiftUI/AppKit update cycle. Forcing parent layout here
    // would hide a split controller that shrinks its own view when collapsing.
    try? await Task.sleep(for: .milliseconds(200))
    #expect(inspector.maximized)
    #expect(inspector.splitViewItems[0].isCollapsed)
    #expect(abs(inspector.splitView.bounds.width - 1200) < 2)
    #expect(abs(host.frame.width - 1200) < 2)
    #expect(container.boardHost.frame.width == 1200)
    #expect(window.contentView?.bounds.width == 1200)
    #expect(inspector.conversationHost === host)

    toggle()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!inspector.maximized)
    #expect(abs(host.frame.width - 540) < 2)
    #expect(container.boardHost.frame.width == 1200)
    #expect(inspector.conversationHost === host)
}

@MainActor
private final class BoardConversationBridgeTestActions {
    var toggle: (() -> Void)?
}

private struct BoardConversationBridgeTestView: View {
    let defaults: UserDefaults
    let actions: BoardConversationBridgeTestActions
    @State private var maximized = false

    var body: some View {
        let toggle = { maximized.toggle() }
        BoardConversationOverlay(
            board: AnyView(Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity)),
            conversation: AnyView(Button("Toggle conversation", action: toggle)),
            presented: true,
            maximized: maximized,
            defaults: defaults
        )
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(
            BoardConversationBridgeTestActionCapture(actions: actions, toggle: toggle).frame(width: 0, height: 0))
    }
}

private struct BoardConversationBridgeTestActionCapture: NSViewRepresentable {
    let actions: BoardConversationBridgeTestActions
    let toggle: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        actions.toggle = toggle
    }
}
