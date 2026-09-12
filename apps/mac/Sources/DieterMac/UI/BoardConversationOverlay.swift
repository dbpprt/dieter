import AppKit
import SwiftUI

enum BoardConversationSizing {
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 720
    static let defaultWidth: CGFloat = 460
    static let maximizeFraction: CGFloat = 0.75
    static let widthPreference = "DieterBoardConversationWidth"

    static func regularWidth(_ saved: CGFloat) -> CGFloat {
        guard saved.isFinite, saved > 0 else { return defaultWidth }
        return min(max(saved, minimumWidth), maximumWidth)
    }

    static func dragMaximumWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return maximumWidth }
        // Leave enough native divider travel to cross the maximize threshold on wide displays.
        // The regular-width preference remains bounded independently.
        return max(maximumWidth, availableWidth * maximizeFraction + 64)
    }

    static func shouldMaximize(conversationWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        availableWidth.isFinite && availableWidth > 0 && conversationWidth.isFinite
            && conversationWidth > availableWidth * maximizeFraction
    }
}

/// A native conversation pane sits beside the board with a thin resize divider.
/// Both hosting views survive resize/maximize/restore, retaining the draft and transcript viewport.
struct BoardConversationOverlay: NSViewControllerRepresentable {
    let board: AnyView
    let conversation: AnyView
    let presented: Bool
    let maximized: Bool
    var defaults: UserDefaults = DieterAppearance.applicationDefaults()
    var onRequestMaximize: () -> Void = {}

    func makeNSViewController(context: Context) -> BoardConversationContainerController {
        BoardConversationContainerController(defaults: defaults)
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
        controller.boardHost.rootView = board
        controller.inspector.conversationHost.rootView = conversation
        controller.inspector.onRequestMaximize = onRequestMaximize
        controller.setPresentation(presented: presented, maximized: maximized)
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

    func setPresentation(presented: Bool, maximized: Bool) {
        loadViewIfNeeded()
        inspector.setPresentation(presented: presented, maximized: maximized)
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
    private var restoreWidthOnLayout = true
    private var widthBeforeDividerDrag: CGFloat?
    private var requestedMaximizeFromDrag = false
    var onRequestMaximize: () -> Void = {}
    private(set) var presented = false
    private(set) var maximized = false

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
        // Keep the board's interactive content inside its native safe area.
        boardBackground.automaticallyPlacesContentView = false
        boardBackground.contentView = boardHost
        boardHost.translatesAutoresizingMaskIntoConstraints = false
        // Explicit native safe-area constraints also track divider changes;
        // automatic placement can retain the initial inset while resizing.
        let safeArea = boardBackground.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            boardHost.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            boardHost.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            boardHost.topAnchor.constraint(equalTo: safeArea.topAnchor),
            boardHost.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ])
        boardController.view = boardBackground
        conversationController.view = conversationHost

        let board = NSSplitViewItem(viewController: boardController)
        board.automaticallyAdjustsSafeAreaInsets = true
        board.minimumThickness = 0
        // Close/maximize own presentation state; native divider drags resize
        // panes without independently changing the selected conversation.
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
        updateMaximumThickness()
        guard presented, restoreWidthOnLayout, !maximized,
            splitView.bounds.width >= BoardConversationSizing.minimumWidth
        else { return }
        restoreWidthOnLayout = false
        let width = min(regularWidth, splitView.bounds.width)
        splitView.setPosition(width, ofDividerAt: 0)
    }

    func setPresentation(presented: Bool, maximized: Bool) {
        let maximized = presented && maximized
        guard self.presented != presented || self.maximized != maximized else { return }
        if self.presented, !self.maximized, !requestedMaximizeFromDrag { rememberRegularWidth() }
        requestedMaximizeFromDrag = false
        widthBeforeDividerDrag = nil
        if !presented, let responder = conversationHost.window?.firstResponder as? NSView,
            responder === conversationHost || responder.isDescendant(of: conversationHost)
        {
            conversationHost.window?.makeFirstResponder(nil)
        }
        self.presented = presented
        self.maximized = maximized
        (splitView as? BoardConversationSplitView)?.maximized = maximized
        // Let AppKit give the maximized conversation the entire split width.
        boardItem.automaticallyAdjustsSafeAreaInsets = !maximized
        if maximized {
            conversationItem.maximumThickness = 1_000_000
            boardItem.isCollapsed = true
        } else {
            boardItem.isCollapsed = false
            updateMaximumThickness()
        }
        // Keep the conversation attached while restoring the board. Removing
        // and reinserting its split item preserves the hosting view pointer,
        // but AppKit detaches it from the window and SwiftUI can rebuild its
        // native text views, losing selection and transcript identity.
        conversationItem.isCollapsed = !presented
        restoreWidthOnLayout = presented && !maximized
        view.needsLayout = true
    }

    private func updateMaximumThickness() {
        let maximum =
            maximized
            ? 1_000_000
            : BoardConversationSizing.dragMaximumWidth(
                availableWidth: splitView.bounds.width)
        if conversationItem.maximumThickness != maximum {
            conversationItem.maximumThickness = maximum
        }
    }

    func dividerDragBegan() {
        guard presented, !maximized, !restoreWidthOnLayout, conversationHost.window != nil else { return }
        requestedMaximizeFromDrag = false
        widthBeforeDividerDrag = conversationFrame.width
        rememberRegularWidth()
    }

    func dividerDragEnded() {
        defer { widthBeforeDividerDrag = nil }
        splitView.layoutSubtreeIfNeeded()
        guard let initialWidth = widthBeforeDividerDrag, presented, !maximized,
            abs(conversationFrame.width - initialWidth) > 0.5
        else { return }
        if BoardConversationSizing.shouldMaximize(
            conversationWidth: conversationFrame.width, availableWidth: splitView.bounds.width)
        {
            // Preserve the width from before the gesture. The SwiftUI callback
            // owns presentation state, and its update must not save the overshoot.
            requestedMaximizeFromDrag = true
            onRequestMaximize()
        } else {
            rememberRegularWidth()
        }
    }

    func rememberRegularWidth() {
        guard presented, !maximized, !restoreWidthOnLayout, conversationHost.window != nil else { return }
        regularWidth = BoardConversationSizing.regularWidth(conversationFrame.width)
        defaults.set(Double(regularWidth), forKey: BoardConversationSizing.widthPreference)
    }
}

/// Divider tracking stays native. Only the completed gesture can request
/// maximization; ordinary window/layout changes never change presentation mode.
final class BoardConversationSplitView: NSSplitView {
    var onDividerDragBegan: (() -> Void)?
    var onDividerDragEnded: (() -> Void)?
    var maximized = false

    var dividerTrackingRect: CGRect {
        guard !maximized, arrangedSubviews.count == 2,
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
                convert(event.locationInWindow, from: nil)) && !maximized
        if beganOnDivider { onDividerDragBegan?() }
        super.mouseDown(with: event)
        if beganOnDivider { onDividerDragEnded?() }
    }
}
