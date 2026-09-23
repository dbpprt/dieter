import AppKit
import SwiftUI

private struct BoardRenderingActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var boardRenderingActive: Bool {
        get { self[BoardRenderingActiveKey.self] }
        set { self[BoardRenderingActiveKey.self] = newValue }
    }
}

enum BoardConversationSizing {
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 1_320
    static let defaultWidth: CGFloat = 460
    static let minimumBoardWidth: CGFloat = 220
    static let minimumBoardWidthWithWorkspace: CGFloat = 220
    static let minimumConversationWidthWithWorkspace: CGFloat = 360
    static let maximumConversationWidthWithWorkspace: CGFloat = 1_320
    static let conversationWorkspaceFraction: CGFloat = 0.58
    static let widthPreference = "DieterBoardConversationWidth"
    static let workspaceWidthPreference = "DieterBoardConversationWorkspaceWidth"

    static func regularWidth(_ saved: CGFloat) -> CGFloat {
        guard saved.isFinite, saved > 0 else { return defaultWidth }
        return min(max(saved, minimumWidth), maximumWidth)
    }

    static func maximumRegularWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return maximumWidth }
        return min(maximumWidth, max(minimumWidth, availableWidth - minimumBoardWidth))
    }

    static func keepsBoardWithWorkspace(availableWidth: CGFloat) -> Bool {
        availableWidth.isFinite
            && availableWidth >= minimumBoardWidthWithWorkspace + minimumConversationWidthWithWorkspace
    }

    static func conversationWidthWithWorkspace(availableWidth: CGFloat, regularWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        return min(
            max(regularWidth, minimumConversationWidthWithWorkspace, availableWidth * conversationWorkspaceFraction),
            maximumConversationWidthWithWorkspace,
            availableWidth - minimumBoardWidthWithWorkspace)
    }

    static func restoredWorkspaceWidth(
        _ saved: CGFloat, availableWidth: CGFloat, regularWidth: CGFloat
    ) -> CGFloat {
        guard saved.isFinite, saved > 0 else {
            return conversationWidthWithWorkspace(availableWidth: availableWidth, regularWidth: regularWidth)
        }
        return min(
            max(saved, minimumConversationWidthWithWorkspace),
            maximumConversationWidthWithWorkspace,
            max(0, availableWidth - minimumBoardWidthWithWorkspace))
    }
}

/// A native conversation pane sits beside the board with a thin resize divider.
/// Both hosting views survive resize and adaptive layout changes, retaining the draft and transcript viewport.
struct BoardConversationOverlay: NSViewControllerRepresentable {
    let board: AnyView
    let conversation: AnyView
    let presented: Bool
    var companionPresented = false
    var boardPresented = true
    var defaults: UserDefaults = DieterAppearance.applicationDefaults()
    var active = true

    func makeNSViewController(context: Context) -> BoardConversationContainerController {
        BoardConversationContainerController(defaults: defaults)
    }

    static func dismantleNSViewController(_ controller: BoardConversationContainerController, coordinator: ()) {
        // Conversation views can own tasks and editor state. Only the board's
        // mounted rows need to survive destination changes.
        controller.inspector.conversationHost.rootView = AnyView(EmptyView())
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController: BoardConversationContainerController, context: Context
    ) -> CGSize? {
        // Collapsing a split item changes its fitting size. The overlay must
        // continue filling the board, rather than shrink to the old chat width.
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    func updateNSViewController(_ controller: BoardConversationContainerController, context: Context) {
        BoardRenderingDiagnostics.record(.overlayUpdated)
        controller.view.isHidden = !active
        controller.boardHost.rootView = AnyView(board.environment(\.boardRenderingActive, active))
        guard active else {
            controller.inspector.conversationHost.rootView = AnyView(EmptyView())
            return
        }
        controller.inspector.conversationHost.rootView = conversation
        controller.setPresentation(
            presented: presented,
            companionPresented: companionPresented,
            boardPresented: boardPresented
        )
    }
}

@MainActor
final class BoardConversationContainerController: NSViewController {
    let inspector: BoardConversationSplitController
    var boardHost: NSHostingView<AnyView> { inspector.boardHost }

    init(defaults: UserDefaults) {
        inspector = BoardConversationSplitController(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = NSView()
        addChild(inspector)
        inspector.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inspector.view)
        NSLayoutConstraint.activate([
            inspector.view.leftAnchor.constraint(equalTo: view.leftAnchor),
            inspector.view.rightAnchor.constraint(equalTo: view.rightAnchor),
            inspector.view.topAnchor.constraint(equalTo: view.topAnchor),
            inspector.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setPresentation(
        presented: Bool,
        companionPresented: Bool = false,
        boardPresented: Bool = true
    ) {
        loadViewIfNeeded()
        inspector.setPresentation(
            presented: presented,
            companionPresented: companionPresented,
            boardPresented: boardPresented
        )
    }
}

@MainActor
final class BoardConversationSplitController: NSSplitViewController {
    let boardHost = NSHostingView(rootView: AnyView(EmptyView()))
    let boardBackground = NSBackgroundExtensionView()
    let conversationHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let boardController = NSViewController()
    private let conversationController = NSViewController()
    private let defaults: UserDefaults
    private var regularWidth: CGFloat
    private var workspaceWidth: CGFloat
    private var restoreWidthOnLayout = true
    private var regularWidthRestoreScheduled = false
    private var dividerDragActive = false
    private(set) var presented = false
    private(set) var companionPresented = false
    private(set) var boardPresented = true
    private(set) var boardCollapsedForWorkspace = false

    // Mirror only the split so its first, width-controlled item sits on the right.
    var conversationItem: NSSplitViewItem { splitViewItems[0] }
    var boardItem: NSSplitViewItem { splitViewItems[1] }

    // Persist and compare the entire pane throughout resize and restore.
    var conversationFrame: CGRect {
        guard splitView.arrangedSubviews.count == 2 else { return .zero }
        return splitView.arrangedSubviews[0].frame
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        regularWidth = BoardConversationSizing.regularWidth(
            CGFloat(defaults.double(forKey: BoardConversationSizing.widthPreference)))
        workspaceWidth = CGFloat(defaults.double(forKey: BoardConversationSizing.workspaceWidthPreference))
        super.init(nibName: nil, bundle: nil)
        let split = BoardConversationSplitView()
        split.isVertical = true
        split.userInterfaceLayoutDirection = .rightToLeft
        split.dividerStyle = .thin
        split.setAccessibilityIdentifier("board.conversation-split")
        split.onDividerDragBegan = { [weak self] in self?.dividerDragBegan() }
        split.onDividerDragEnded = { [weak self] in self?.dividerDragEnded() }
        splitView = split

        boardHost.sizingOptions = []
        conversationHost.sizingOptions = []
        let contentDirection = NSApplication.shared.userInterfaceLayoutDirection
        boardHost.userInterfaceLayoutDirection = contentDirection
        boardBackground.userInterfaceLayoutDirection = contentDirection
        conversationHost.userInterfaceLayoutDirection = contentDirection
        // The board owns its top header. Only the sidebar contains window
        // controls, so reserving the window's titlebar safe area here leaves
        // an empty band above the Kanban and misaligns it with the chat tabs.
        boardBackground.automaticallyPlacesContentView = false
        boardBackground.contentView = boardHost
        boardHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            boardHost.leadingAnchor.constraint(equalTo: boardBackground.leadingAnchor),
            boardHost.trailingAnchor.constraint(equalTo: boardBackground.trailingAnchor),
            boardHost.topAnchor.constraint(equalTo: boardBackground.topAnchor),
            boardHost.bottomAnchor.constraint(equalTo: boardBackground.bottomAnchor),
        ])
        boardController.view = boardBackground
        conversationController.view = conversationHost

        let board = NSSplitViewItem(viewController: boardController)
        board.automaticallyAdjustsSafeAreaInsets = true
        board.minimumThickness = 0
        // The selected conversation owns presentation state. Native divider
        // drags only resize the pane and never change that selection.
        board.canCollapse = false
        board.canCollapseFromWindowResize = false
        board.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        board.holdingPriority = NSLayoutConstraint.Priority(200)
        // Sidebar items add a rounded glass outline. A regular item keeps the
        // conversation flush with the board while retaining native resizing.
        let conversation = NSSplitViewItem(viewController: conversationController)
        conversation.minimumThickness = BoardConversationSizing.minimumWidth
        conversation.maximumThickness = BoardConversationSizing.maximumWidth
        conversation.canCollapse = false
        conversation.canCollapseFromWindowResize = false
        conversation.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        conversation.holdingPriority = NSLayoutConstraint.Priority(480)
        conversation.isCollapsed = true
        addSplitViewItem(conversation)
        addSplitViewItem(board)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keep the real content above the reflection surface so normal AppKit
        // hit testing reaches the Kanban controls, not the decorative replica.
        if boardBackground.subviews.last !== boardHost {
            boardBackground.addSubview(boardHost, positioned: .above, relativeTo: nil)
        }
        updateAdaptivePresentation()
        scheduleRegularWidthRestore()
    }

    override func viewWillDisappear() {
        rememberCurrentWidth()
        super.viewWillDisappear()
    }

    private func scheduleRegularWidthRestore() {
        guard presented, restoreWidthOnLayout, !boardItem.isCollapsed,
            splitView.bounds.width >= BoardConversationSizing.minimumWidth,
            !regularWidthRestoreScheduled
        else { return }
        regularWidthRestoreScheduled = true
        // setPosition performs an immediate AppKit layout. Calling it from
        // viewDidLayout re-enters the hosting view while SwiftUI is flushing
        // its graph, which produces AttributeGraph cycles and sustained CPU.
        // Move the one-shot restore to the next main-run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.regularWidthRestoreScheduled = false
            guard self.presented, self.restoreWidthOnLayout, !self.boardItem.isCollapsed,
                self.splitView.bounds.width >= BoardConversationSizing.minimumWidth
            else { return }
            self.restoreWidthOnLayout = false
            let width = self.targetConversationWidth()
            if abs(self.conversationFrame.width - width) > 0.5 {
                self.splitView.setPosition(width, ofDividerAt: 0)
                self.view.layoutSubtreeIfNeeded()
            }
        }
    }

    func setPresentation(
        presented: Bool,
        companionPresented: Bool = false,
        boardPresented: Bool = true
    ) {
        let companionPresented = presented && companionPresented
        let boardPresented = !presented || boardPresented
        guard
            self.presented != presented || self.companionPresented != companionPresented
                || self.boardPresented != boardPresented
        else { return }
        if self.presented, !dividerDragActive {
            rememberCurrentWidth()
        }
        dividerDragActive = false
        if !presented, let responder = conversationHost.window?.firstResponder as? NSView,
            responder === conversationHost || responder.isDescendant(of: conversationHost)
        {
            conversationHost.window?.makeFirstResponder(nil)
        }
        self.presented = presented
        self.companionPresented = companionPresented
        self.boardPresented = boardPresented
        updateAdaptivePresentation()
        // Keep the conversation attached while restoring the board. Removing
        // and reinserting its split item preserves the hosting view pointer,
        // but AppKit detaches it from the window and SwiftUI can rebuild its
        // native text views, losing selection and transcript identity.
        conversationItem.isCollapsed = !presented
        restoreWidthOnLayout = presented && !boardItem.isCollapsed
        view.needsLayout = true
        // State updates can arrive before AppKit schedules another layout
        // pass. Queue the restore now as well as from viewDidLayout so the pane
        // has its stable width before the next SwiftUI frame is presented.
        scheduleRegularWidthRestore()
    }

    private func updateMaximumThickness() {
        let maximum =
            boardItem.isCollapsed
            ? 1_000_000
            : companionPresented
                ? max(
                    BoardConversationSizing.minimumConversationWidthWithWorkspace,
                    splitView.bounds.width - BoardConversationSizing.minimumBoardWidthWithWorkspace)
                : BoardConversationSizing.maximumRegularWidth(availableWidth: splitView.bounds.width)
        if conversationItem.maximumThickness != maximum {
            conversationItem.maximumThickness = maximum
        }
    }

    private func updateAdaptivePresentation() {
        guard splitView.bounds.width > 0 else { return }
        let collapseBoard = presented && !boardPresented
        boardCollapsedForWorkspace = collapseBoard
        (splitView as? BoardConversationSplitView)?.boardCollapsed = collapseBoard
        boardItem.automaticallyAdjustsSafeAreaInsets = !collapseBoard
        // Keep the native split shrinkable across the adaptive breakpoint.
        // The restore target reserves useful widths on wide windows; hard item
        // minima would instead prevent the window from ever reaching the
        // narrow layout where the board should collapse.
        boardItem.minimumThickness = 0
        conversationItem.minimumThickness = BoardConversationSizing.minimumWidth
        // Lift the regular drag cap before collapsing the board. Otherwise
        // AppKit leaves a sliver of the collapsed item to satisfy the old
        // maximum and does not revisit that allocation after the cap changes.
        if collapseBoard { conversationItem.maximumThickness = 1_000_000 }
        if boardItem.isCollapsed != collapseBoard {
            boardItem.isCollapsed = collapseBoard
            restoreWidthOnLayout = presented && !collapseBoard
        }
        if !collapseBoard { updateMaximumThickness() }
    }

    private func targetConversationWidth() -> CGFloat {
        if companionPresented {
            return BoardConversationSizing.restoredWorkspaceWidth(
                workspaceWidth, availableWidth: splitView.bounds.width, regularWidth: regularWidth)
        }
        return min(regularWidth, BoardConversationSizing.maximumRegularWidth(availableWidth: splitView.bounds.width))
    }

    func dividerDragBegan() {
        guard presented, !restoreWidthOnLayout, conversationHost.window != nil
        else { return }
        dividerDragActive = true
    }

    func dividerDragEnded() {
        guard dividerDragActive else { return }
        dividerDragActive = false
        splitView.layoutSubtreeIfNeeded()
        rememberCurrentWidth()
    }

    func rememberRegularWidth() {
        guard presented, boardPresented, !boardItem.isCollapsed,
            !companionPresented, !restoreWidthOnLayout,
            conversationHost.window != nil
        else { return }
        regularWidth = BoardConversationSizing.regularWidth(conversationFrame.width)
        defaults.set(Double(regularWidth), forKey: BoardConversationSizing.widthPreference)
    }

    func rememberCurrentWidth() {
        guard presented, boardPresented, !boardItem.isCollapsed,
            !restoreWidthOnLayout, conversationHost.window != nil
        else { return }
        if companionPresented {
            workspaceWidth = conversationFrame.width
            defaults.set(Double(workspaceWidth), forKey: BoardConversationSizing.workspaceWidthPreference)
        } else {
            rememberRegularWidth()
        }
    }
}

/// Divider tracking stays native. Completed gestures only persist the bounded
/// regular width; they never change presentation mode or hide the board.
final class BoardConversationSplitView: NSSplitView {
    var onDividerDragBegan: (() -> Void)?
    var onDividerDragEnded: (() -> Void)?
    var boardCollapsed = false

    var dividerTrackingRect: CGRect {
        guard !boardCollapsed, arrangedSubviews.count == 2,
            !isSubviewCollapsed(arrangedSubviews[0])
        else { return .zero }
        // Track the leading edge of the physically right conversation pane.
        return CGRect(
            x: arrangedSubviews[0].frame.minX, y: bounds.minY,
            width: dividerThickness, height: bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        let beganOnDivider =
            dividerTrackingRect.insetBy(dx: -3, dy: 0).contains(
                convert(event.locationInWindow, from: nil)) && !boardCollapsed
        if beganOnDivider { onDividerDragBegan?() }
        super.mouseDown(with: event)
        if beganOnDivider { onDividerDragEnded?() }
    }
}
