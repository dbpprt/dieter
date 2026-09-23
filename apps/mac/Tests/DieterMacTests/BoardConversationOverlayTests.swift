import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Test func boardConversationWidthPreferencesStayWithinNativeLimits() {
    #expect(BoardConversationSizing.regularWidth(0) == 460)
    #expect(BoardConversationSizing.regularWidth(.nan) == 460)
    #expect(BoardConversationSizing.regularWidth(200) == 320)
    #expect(BoardConversationSizing.regularWidth(540) == 540)
    #expect(BoardConversationSizing.regularWidth(2_000) == 1_320)
}

@Test func boardConversationRegularResizeStaysBounded() {
    #expect(BoardConversationSizing.maximumWidth == 1_320)
    #expect(BoardConversationSizing.regularWidth(900) == 900)
    #expect(BoardConversationSizing.maximumRegularWidth(availableWidth: 1_400) == 1_180)
    #expect(BoardConversationSizing.maximumRegularWidth(availableWidth: 800) == 580)
}

@Test func wideBoardsKeepKanbanBesideConversationWorkspace() {
    #expect(!BoardConversationSizing.keepsBoardWithWorkspace(availableWidth: 579))
    #expect(BoardConversationSizing.keepsBoardWithWorkspace(availableWidth: 580))
    #expect(
        BoardConversationSizing.conversationWidthWithWorkspace(
            availableWidth: 1_400, regularWidth: 460) == 812)
    #expect(
        BoardConversationSizing.conversationWidthWithWorkspace(
            availableWidth: 1_300, regularWidth: 460) == 754)
}

@Test func savedWorkspaceWidthTakesPriorityOverTheDefaultFraction() {
    #expect(
        BoardConversationSizing.restoredWorkspaceWidth(
            640, availableWidth: 1_200, regularWidth: 460) == 640)
    #expect(
        BoardConversationSizing.restoredWorkspaceWidth(
            0, availableWidth: 1_200, regularWidth: 460)
            == BoardConversationSizing.conversationWidthWithWorkspace(
                availableWidth: 1_200, regularWidth: 460))
    #expect(
        BoardConversationSizing.restoredWorkspaceWidth(
            900, availableWidth: 1_000, regularWidth: 460) == 780)
}

@Test @MainActor func workspaceDividerWidthSurvivesBoardRemount() async {
    let suite = "BoardConversationOverlayTests.persisted-workspace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let size = boardConversationTestWindowSize(preferredWidth: 1_200)

    func mount() -> (BoardConversationContainerController, NSWindow) {
        let controller = BoardConversationContainerController(defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderBack(nil)
        return (controller, window)
    }

    let (first, firstWindow) = mount()
    first.setPresentation(presented: true, companionPresented: true)
    firstWindow.contentView?.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(100))
    let width = min(CGFloat(640), first.inspector.splitView.bounds.width - 230)
    first.inspector.dividerDragBegan()
    first.inspector.splitView.setPosition(width, ofDividerAt: 0)
    firstWindow.contentView?.layoutSubtreeIfNeeded()
    first.inspector.dividerDragEnded()
    #expect(abs(defaults.double(forKey: BoardConversationSizing.workspaceWidthPreference) - width) < 2)
    firstWindow.close()

    let (restored, restoredWindow) = mount()
    defer { restoredWindow.close() }
    restored.setPresentation(presented: true, companionPresented: true)
    restoredWindow.contentView?.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(100))
    restoredWindow.contentView?.layoutSubtreeIfNeeded()
    #expect(abs(restored.inspector.conversationFrame.width - width) < 2)
}

@Test @MainActor func nativeBoardSplitAdaptsBetweenThreeColumnsAndFocusedWorkspace() async {
    let suite = "BoardConversationOverlayTests.workspace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(460, forKey: BoardConversationSizing.widthPreference)
    let controller = BoardConversationContainerController(defaults: defaults)
    let conversationHost = controller.inspector.conversationHost
    let contentSize = boardConversationTestWindowSize(preferredWidth: 1_400)
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
        try? await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    controller.setPresentation(presented: true, companionPresented: true)
    await settle()
    let keepsWideBoard = BoardConversationSizing.keepsBoardWithWorkspace(availableWidth: contentSize.width)
    #expect(controller.inspector.boardItem.isCollapsed == !keepsWideBoard)
    #expect(
        abs(
            controller.inspector.conversationFrame.width
                - BoardConversationSizing.conversationWidthWithWorkspace(
                    availableWidth: contentSize.width, regularWidth: 460)) < 2)
    #expect(controller.inspector.conversationHost === conversationHost)

    let narrowWidth = min(980, contentSize.width)
    window.setContentSize(NSSize(width: narrowWidth, height: contentSize.height))
    await settle()
    #expect(!controller.inspector.boardItem.isCollapsed)
    #expect(
        abs(
            controller.inspector.conversationFrame.width
                - BoardConversationSizing.conversationWidthWithWorkspace(
                    availableWidth: narrowWidth, regularWidth: 460)) < 2)
    #expect(controller.inspector.conversationHost === conversationHost)

    window.setContentSize(contentSize)
    await settle()
    #expect(controller.inspector.boardItem.isCollapsed == !keepsWideBoard)
    #expect(
        abs(
            controller.inspector.conversationFrame.width
                - BoardConversationSizing.conversationWidthWithWorkspace(
                    availableWidth: contentSize.width, regularWidth: 460)) < 2)
    #expect(controller.inspector.conversationHost === conversationHost)
}

@Test @MainActor func kanbanToggleHidesAndRestoresTheBoardWithoutClosingConversation() async {
    let suite = "BoardConversationOverlayTests.kanban-toggle.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(460, forKey: BoardConversationSizing.widthPreference)
    let controller = BoardConversationContainerController(defaults: defaults)
    let conversationHost = controller.inspector.conversationHost
    let contentSize = boardConversationTestWindowSize(preferredWidth: 1_200)
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: contentSize),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(contentSize)
    window.orderBack(nil)
    defer { window.close() }

    func settle() async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    controller.setPresentation(presented: true, boardPresented: true)
    await settle()
    #expect(!controller.inspector.boardItem.isCollapsed)
    #expect(abs(controller.inspector.conversationFrame.width - 460) < 2)

    controller.setPresentation(presented: true, boardPresented: false)
    await settle()
    #expect(controller.inspector.boardItem.isCollapsed)
    #expect(abs(controller.inspector.conversationFrame.width - contentSize.width) < 2)
    #expect(controller.inspector.conversationHost === conversationHost)

    controller.setPresentation(presented: true, boardPresented: true)
    await settle()
    #expect(!controller.inspector.boardItem.isCollapsed)
    #expect(abs(controller.inspector.conversationFrame.width - 460) < 2)
    #expect(controller.inspector.conversationHost === conversationHost)
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

    controller.setPresentation(presented: true)
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

    window.makeFirstResponder(editor)
    controller.setPresentation(presented: false)
    await settle()
    #expect(controller.inspector.conversationItem.isCollapsed)
    #expect(host.window == nil || host.isHiddenOrHasHiddenAncestor)
    #expect(window.firstResponder !== editor)
    #expect(abs(controller.boardHost.frame.width - contentSize.width) < 2)
    #expect(controller.boardHost.window === window)
    #expect(controller.inspector.boardBackground.safeAreaInsets.right == 0)
    #expect((split as? BoardConversationSplitView)?.dividerTrackingRect.isEmpty == true)
    controller.setPresentation(presented: true)
    await settle()
    #expect(abs(controller.inspector.conversationFrame.width - 560) < 2)
    #expect(controller.inspector.conversationHost === host)
    #expect(editor.string == "Unsaved conversation draft")
}

@Test(arguments: [CGFloat(1024), 1200]) @MainActor
func boardConversationSwiftUIWorkspaceStateAdaptsWithinItsParentProposal(preferredWidth: CGFloat) async throws {
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
    let transcript = try #require(boardConversationTranscript(in: host))
    let selection = NSRange(location: 6, length: 19)
    transcript.setSelectedRange(selection)
    #expect(abs(inspector.conversationFrame.width - 540) < 2)
    expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(inspector)

    let toggle = try #require(actions.toggle)
    toggle()
    // Allow the normal SwiftUI/AppKit update cycle. Forcing parent layout here
    // would hide a split controller that shrinks its own view when collapsing.
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!inspector.boardCollapsedForWorkspace)
    #expect(!inspector.boardItem.isCollapsed)
    #expect(abs(inspector.splitView.bounds.width - contentSize.width) < 2)
    #expect(
        abs(
            inspector.conversationFrame.width
                - BoardConversationSizing.conversationWidthWithWorkspace(
                    availableWidth: contentSize.width, regularWidth: 540)) < 2)
    #expect(!inspector.boardItem.isCollapsed)
    #expect(window.contentView?.bounds.width == contentSize.width)
    #expect(inspector.conversationHost === host)
    #expect(boardConversationTranscript(in: host) === transcript)
    #expect(transcript.selectedRange() == selection)

    toggle()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!inspector.boardCollapsedForWorkspace)
    #expect(abs(inspector.conversationFrame.width - 540) < 2)
    expectBoardBackgroundExtendsBehindSidebarWithoutOverlappingContent(inspector)
    #expect(inspector.conversationHost === host)
    #expect(boardConversationTranscript(in: host) === transcript)
    #expect(transcript.selectedRange() == selection)
    #expect(transcript.window === window)

    inspector.dividerDragBegan()
    inspector.splitView.setPosition(contentSize.width * 0.79, ofDividerAt: 0)
    root.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(60))
    inspector.dividerDragEnded()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!inspector.boardCollapsedForWorkspace)
    #expect(!inspector.boardItem.isCollapsed)
    #expect(inspector.conversationFrame.width <= BoardConversationSizing.maximumWidth + 1)
    #expect(inspector.conversationHost === host)
    #expect(boardConversationTranscript(in: host) === transcript)
    #expect(transcript.selectedRange() == selection)
    #expect(defaults.double(forKey: BoardConversationSizing.widthPreference) <= 1_320)
}

@Test(arguments: [CGFloat(1024), 2000]) @MainActor
func boardConversationDragStaysBoundedAndNeverHidesTheBoard(preferredWidth: CGFloat) async {
    let suite = "BoardConversationDragTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(480, forKey: BoardConversationSizing.widthPreference)
    let controller = BoardConversationContainerController(defaults: defaults)
    controller.boardHost.rootView = AnyView(Color.blue)
    let editor = NSTextView()
    editor.string = "Keep this draft while resizing"
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
    func resizeConversation(to width: CGFloat) async {
        let split = controller.inspector.splitView
        split.setPosition(width, ofDividerAt: 0)
        await settle()
    }

    controller.setPresentation(presented: true)
    await settle()
    let split = controller.inspector.splitView
    let host = controller.inspector.conversationHost
    #expect(
        abs(
            controller.inspector.conversationItem.maximumThickness
                - BoardConversationSizing.maximumRegularWidth(availableWidth: split.bounds.width)) < 2)

    // Programmatic layout and window resizing never hide the board.
    await resizeConversation(to: split.bounds.width * 0.9)
    #expect(controller.inspector.conversationFrame.width <= BoardConversationSizing.maximumWidth + 1)
    #expect(!controller.inspector.boardItem.isCollapsed)
    controller.inspector.dividerDragEnded()
    window.setContentSize(NSSize(width: contentSize.width * 0.9, height: contentSize.height))
    await settle()
    #expect(!controller.inspector.boardItem.isCollapsed)
    window.setContentSize(contentSize)
    await settle()
    await resizeConversation(to: 480)
    controller.inspector.rememberRegularWidth()

    controller.inspector.dividerDragBegan()
    await resizeConversation(to: split.bounds.width * 0.9)
    controller.inspector.dividerDragEnded()
    await settle()
    #expect(!controller.inspector.boardItem.isCollapsed)
    #expect(controller.inspector.conversationFrame.width <= BoardConversationSizing.maximumWidth + 1)
    #expect(controller.inspector.conversationHost === host)
    #expect(editor.string == "Keep this draft while resizing")
    #expect(defaults.double(forKey: BoardConversationSizing.widthPreference) <= 1_320)
    controller.inspector.dividerDragEnded()
    #expect(!controller.inspector.boardItem.isCollapsed)
}

@MainActor private func boardConversationTestWindowSize(preferredWidth: CGFloat) -> NSSize {
    // AppKit constrains ordered windows to their display, including offscreen
    // test windows. CI's display can be only 1024 points wide. Keep the requested
    // fixture on that display, while still asserting it never shrinks when the
    // inspector adapts its board/workspace layout.
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
    @State private var workspacePresented = false

    var body: some View {
        let toggle = { workspacePresented.toggle() }
        BoardConversationOverlay(
            board: AnyView(Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity)),
            conversation: AnyView(
                ConversationContentSplit(presented: workspacePresented) {
                    VStack {
                        Button("Toggle conversation", action: toggle)
                        ScrollView {
                            SelectableMessageText(
                                source: "First paragraph with a selected phrase.\n\n"
                                    + String(
                                        repeating: "Keep the transcript mounted through native split changes. ",
                                        count: 100),
                                color: .primary
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } content: {
                    Text("Workspace content").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            ),
            presented: true,
            companionPresented: workspacePresented,
            defaults: defaults
        )
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(
            BoardConversationBridgeTestActionCapture(actions: actions, toggle: toggle).frame(width: 0, height: 0))
    }
}

@MainActor private func boardConversationTranscript(in view: NSView) -> MessageTextView? {
    (view as? MessageTextView) ?? view.subviews.lazy.compactMap { boardConversationTranscript(in: $0) }.first
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
    // The Kanban host occupies the whole column. Its header can draw through
    // the titlebar band instead of inheriting a blank window safe-area strip.
    #expect(abs(backgroundFrame.maxX - boardFrame.maxX) < 2)
    #expect(abs(boardFrame.minX - backgroundFrame.minX) < 2)
    #expect(abs(boardFrame.minY - backgroundFrame.minY) < 2)
    #expect(abs(boardFrame.width - backgroundFrame.width) < 2)
    #expect(abs(boardFrame.height - backgroundFrame.height) < 2)
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
