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

@Test func boardConversationMaximizeThresholdRequiresMoreThanThreeQuartersOfTheAvailableView() {
    #expect(!BoardConversationSizing.shouldMaximize(conversationWidth: 900, availableWidth: 1200))
    #expect(BoardConversationSizing.shouldMaximize(conversationWidth: 900.1, availableWidth: 1200))
    #expect(!BoardConversationSizing.shouldMaximize(conversationWidth: 899.9, availableWidth: 1200))
    #expect(!BoardConversationSizing.shouldMaximize(conversationWidth: .infinity, availableWidth: 1200))
    #expect(!BoardConversationSizing.shouldMaximize(conversationWidth: 600, availableWidth: 0))
    #expect(!BoardConversationSizing.shouldMaximize(conversationWidth: 600, availableWidth: .nan))
    #expect(BoardConversationSizing.dragMaximumWidth(availableWidth: 2000) > 1500)
    #expect(BoardConversationSizing.dragMaximumWidth(availableWidth: 1200) > 900)
}

@Test(arguments: [CGFloat(1024), 1200]) @MainActor
func boardConversationUsesABorderlessNativePaneAndRestoresItsDraftAndWidth(preferredWidth: CGFloat) async {
    let suite = "BoardConversationOverlayTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(480, forKey: BoardConversationSizing.widthPreference)
    let controller = BoardConversationContainerController(defaults: defaults)
    let boardContent = NSTextView()
    boardContent.string = "Interactive Kanban content"
    controller.boardHost.rootView = AnyView(BoardConversationTestEditor(editor: boardContent))
    let editor = NSTextView()
    editor.string = "Unsaved conversation draft"
    controller.inspector.conversationHost.rootView = AnyView(BoardConversationTestEditor(editor: editor))
    let contentSize = boardConversationTestWindowSize(preferredWidth: preferredWidth)
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: contentSize),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.contentViewController = controller
    window.setContentSize(contentSize)
    window.orderBack(nil)
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
    #expect(abs(controller.inspector.conversationFrame.width - 480) < 2)
    expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(controller.inspector)
    #expect(controller.inspector.conversationItem.behavior == .default)
    #expect(!controller.inspector.splitView(split, canCollapseSubview: controller.inspector.boardBackground))
    #expect(!controller.inspector.splitView(split, canCollapseSubview: host))
    #expect(controller.inspector.splitViewItems.allSatisfy { !$0.canCollapseFromWindowResize })
    #expect(window.contentView?.bounds.width == contentSize.width)

    split.setPosition(560, ofDividerAt: 0)
    await settle()
    controller.inspector.rememberRegularWidth()
    #expect(abs(controller.inspector.conversationFrame.width - 560) < 2)
    expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(controller.inspector)
    #expect(abs(defaults.double(forKey: BoardConversationSizing.widthPreference) - 560) < 2)
    let point = controller.boardHost.convert(NSPoint(x: 30, y: 200), to: controller.view.superview)
    let boardHit = controller.view.hitTest(point)
    #expect(boardHit?.isDescendant(of: controller.boardHost) == true || boardHit === controller.boardHost)
    #expect(editor.window === window)

    controller.setPresentation(presented: true, maximized: true)
    await settle()
    #expect(abs(controller.inspector.conversationFrame.width - contentSize.width) < 2)
    #expect(controller.inspector.boardItem.isCollapsed)
    #expect(controller.inspector.conversationHost === host)
    #expect(abs(defaults.double(forKey: BoardConversationSizing.widthPreference) - 560) < 2)

    controller.setPresentation(presented: true, maximized: false)
    await settle()
    #expect(abs(controller.inspector.conversationFrame.width - 560) < 2)
    #expect(controller.inspector.conversationHost === host)
    #expect(editor.string == "Unsaved conversation draft")
    expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(controller.inspector)
    window.makeFirstResponder(editor)
    controller.setPresentation(presented: false, maximized: false)
    await settle()
    #expect(controller.inspector.conversationItem.isCollapsed)
    #expect(host.window == nil || host.isHiddenOrHasHiddenAncestor)
    #expect(window.firstResponder !== editor)
    #expect(abs(controller.boardHost.frame.width - contentSize.width) < 2)
    #expect(controller.boardHost.window === window)
    #expect(controller.inspector.boardBackground.safeAreaInsets.right == 0)
    #expect((split as? BoardConversationSplitView)?.dividerTrackingRect.isEmpty == true)
    controller.setPresentation(presented: true, maximized: false)
    await settle()
    #expect(abs(controller.inspector.conversationFrame.width - 560) < 2)
    #expect(controller.inspector.conversationHost === host)
    #expect(editor.string == "Unsaved conversation draft")
}

@Test(arguments: [CGFloat(1024), 1200]) @MainActor
func boardConversationSwiftUIStateMaximizesWithinItsParentProposal(preferredWidth: CGFloat) async throws {
    let suite = "BoardConversationBridgeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(540, forKey: BoardConversationSizing.widthPreference)
    let actions = BoardConversationBridgeTestActions()
    let root = NSHostingView(rootView: BoardConversationBridgeTestView(defaults: defaults, actions: actions))
    root.sizingOptions = []
    let contentSize = boardConversationTestWindowSize(preferredWidth: preferredWidth)
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: contentSize),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.contentView = root
    window.setContentSize(contentSize)
    window.orderBack(nil)
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
    let host = inspector.conversationHost
    #expect(abs(inspector.conversationFrame.width - 540) < 2)
    expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(inspector)

    let toggle = try #require(actions.toggle)
    toggle()
    // Allow the normal SwiftUI/AppKit update cycle. Forcing parent layout here
    // would hide a split controller that shrinks its own view when collapsing.
    try? await Task.sleep(for: .milliseconds(200))
    #expect(inspector.maximized)
    #expect(inspector.boardItem.isCollapsed)
    #expect(abs(inspector.splitView.bounds.width - contentSize.width) < 2)
    #expect(abs(inspector.conversationFrame.width - contentSize.width) < 2)
    #expect(inspector.boardItem.isCollapsed)
    #expect(window.contentView?.bounds.width == contentSize.width)
    #expect(inspector.conversationHost === host)

    toggle()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!inspector.maximized)
    #expect(abs(inspector.conversationFrame.width - 540) < 2)
    expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(inspector)
    #expect(inspector.conversationHost === host)

    inspector.dividerDragBegan()
    inspector.splitView.setPosition(contentSize.width * 0.79, ofDividerAt: 0)
    root.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(60))
    inspector.dividerDragEnded()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(inspector.maximized)
    #expect(inspector.boardItem.isCollapsed)
    #expect(abs(inspector.conversationFrame.width - contentSize.width) < 2)
    #expect(inspector.conversationHost === host)
    #expect(abs(defaults.double(forKey: BoardConversationSizing.widthPreference) - 540) < 2)
}

@Test(arguments: [CGFloat(1024), 2000]) @MainActor
func boardConversationDragMaximizesOnlyOnReleaseAndPreservesItsRegularWidth(preferredWidth: CGFloat) async {
    let suite = "BoardConversationDragTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(480, forKey: BoardConversationSizing.widthPreference)
    let controller = BoardConversationContainerController(defaults: defaults)
    controller.boardHost.rootView = AnyView(Color.blue)
    let editor = NSTextView()
    editor.string = "Keep this draft while maximizing"
    controller.inspector.conversationHost.rootView = AnyView(BoardConversationTestEditor(editor: editor))
    let contentSize = boardConversationTestWindowSize(preferredWidth: preferredWidth)
    let maximizeThreshold = contentSize.width * 0.75
    let widerThanThreshold = contentSize.width * 0.77
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: contentSize),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.contentViewController = controller
    window.setContentSize(contentSize)
    window.orderBack(nil)
    defer { window.close() }
    var maximizeRequests = 0
    controller.inspector.onRequestMaximize = {
        maximizeRequests += 1
        controller.setPresentation(presented: true, maximized: true)
    }

    func settle() async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(60))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func resizeConversation(to width: CGFloat) async {
        let split = controller.inspector.splitView
        split.setPosition(width, ofDividerAt: 0)
        await settle()
    }

    controller.setPresentation(presented: true, maximized: false)
    await settle()
    let split = controller.inspector.splitView
    let host = controller.inspector.conversationHost
    #expect(controller.inspector.conversationItem.maximumThickness > maximizeThreshold)
    #expect(maximizeRequests == 0)

    // Programmatic layout and window resizing never request maximization.
    await resizeConversation(to: widerThanThreshold)
    #expect(controller.inspector.conversationFrame.width > maximizeThreshold)
    #expect(maximizeRequests == 0)
    controller.inspector.dividerDragEnded()
    #expect(maximizeRequests == 0)
    window.setContentSize(NSSize(width: contentSize.width * 0.9, height: contentSize.height))
    await settle()
    #expect(maximizeRequests == 0)
    #expect(!controller.inspector.maximized)
    window.setContentSize(contentSize)
    await settle()
    await resizeConversation(to: 480)
    controller.inspector.rememberRegularWidth()

    controller.inspector.dividerDragBegan()
    await resizeConversation(to: split.bounds.width * 0.75)
    #expect(abs(controller.inspector.conversationFrame.width - maximizeThreshold) < 0.1)
    controller.inspector.dividerDragEnded()
    #expect(maximizeRequests == 0)
    #expect(!controller.inspector.maximized)

    await resizeConversation(to: 480)
    controller.inspector.rememberRegularWidth()
    controller.inspector.dividerDragBegan()
    await resizeConversation(to: widerThanThreshold)
    #expect(maximizeRequests == 0)
    #expect(!controller.inspector.maximized)
    controller.inspector.dividerDragEnded()
    await settle()
    #expect(maximizeRequests == 1)
    #expect(controller.inspector.maximized)
    #expect(abs(controller.inspector.conversationFrame.width - contentSize.width) < 2)
    #expect(controller.inspector.conversationHost === host)
    #expect(editor.string == "Keep this draft while maximizing")
    #expect(abs(defaults.double(forKey: BoardConversationSizing.widthPreference) - 480) < 2)
    controller.inspector.dividerDragEnded()
    #expect(maximizeRequests == 1)

    controller.setPresentation(presented: true, maximized: false)
    await settle()
    #expect(abs(controller.inspector.conversationFrame.width - 480) < 2)
    #expect(controller.inspector.conversationHost === host)
    #expect(editor.string == "Keep this draft while maximizing")
}

@MainActor private func boardConversationTestWindowSize(preferredWidth: CGFloat) -> NSSize {
    // AppKit constrains ordered windows to their display, including offscreen
    // test windows. CI's display can be only 1024 points wide. Keep the requested
    // fixture on that display, while still asserting it never shrinks when the
    // inspector collapses or maximizes.
    let display = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
    return NSSize(width: min(preferredWidth, display.width), height: min(800, display.height))
}

private struct BoardConversationTestEditor: NSViewRepresentable {
    let editor: NSTextView
    func makeNSView(context: Context) -> NSTextView { editor }
    func updateNSView(_ nsView: NSTextView, context: Context) {}
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
            defaults: defaults,
            onRequestMaximize: { maximized = true }
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

@MainActor
private func expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(
    _ inspector: BoardConversationSplitController
) {
    let split = inspector.splitView
    let background = inspector.boardBackground
    let backgroundFrame = background.convert(background.bounds, to: split)
    let safeFrame = background.convert(background.safeAreaLayoutGuide.frame, to: split)
    let boardFrame = inspector.boardHost.convert(inspector.boardHost.bounds, to: split)
    let sidebarFrame = inspector.conversationFrame
    let chatFrame = inspector.conversationHost.convert(inspector.conversationHost.bounds, to: split)
    #expect(inspector.boardItem.automaticallyAdjustsSafeAreaInsets)
    #expect(background.contentView === inspector.boardHost)
    #expect(split.userInterfaceLayoutDirection == .rightToLeft)
    #expect(inspector.boardHost.userInterfaceLayoutDirection == NSApp.userInterfaceLayoutDirection)
    #expect(inspector.conversationHost.userInterfaceLayoutDirection == NSApp.userInterfaceLayoutDirection)
    #expect(!background.automaticallyPlacesContentView)
    // A regular conversation pane has no floating sidebar outline or overlap.
    // The Kanban host occupies its complete safe area and keeps normal input.
    #expect(abs(backgroundFrame.maxX - boardFrame.maxX) < 2)
    #expect(abs(boardFrame.minX - safeFrame.minX) < 2)
    #expect(abs(boardFrame.width - safeFrame.width) < 2)
    #expect(abs(boardFrame.maxX - sidebarFrame.minX) < 2)
    #expect(boardFrame.maxX <= chatFrame.minX)
    #expect(chatFrame.maxX <= sidebarFrame.maxX)
    #expect(abs(boardFrame.width + sidebarFrame.width - split.bounds.width) < 2)
    #expect(background.safeAreaInsets.right == 0)
    if let nativeSplit = split as? BoardConversationSplitView {
        #expect(abs(nativeSplit.dividerTrackingRect.minX - sidebarFrame.minX) < 1)
        #expect(abs(nativeSplit.dividerTrackingRect.minX - backgroundFrame.maxX) < 2)
    }
}
