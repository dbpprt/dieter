import AppKit
import SwiftUI

enum BoardConversationSizing {
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 720
    static let defaultWidth: CGFloat = 460
    static let widthPreference = "DieterBoardConversationWidth"

    static func regularWidth(_ saved: CGFloat) -> CGFloat {
        guard saved.isFinite, saved > 0 else { return defaultWidth }
        return min(max(saved, minimumWidth), maximumWidth)
    }
}

/// The board keeps its full width underneath a native, resizable conversation.
/// Both hosting views survive resize/maximize/restore, retaining the draft,
/// first responder, and transcript viewport.
struct BoardConversationOverlay: NSViewControllerRepresentable {
    let board: AnyView
    let conversation: AnyView
    let presented: Bool
    let maximized: Bool
    var defaults: UserDefaults = DieterAppearance.applicationDefaults()

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
        controller.setPresentation(presented: presented, maximized: maximized)
    }
}

@MainActor
final class BoardConversationContainerController: NSViewController {
    let boardHost = NSHostingView(rootView: AnyView(EmptyView()))
    let inspector: BoardConversationSplitController
    private var presented = false

    init(defaults: UserDefaults) {
        inspector = BoardConversationSplitController(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let container = BoardConversationContainerView()
        container.boardHost = boardHost
        container.overlaySplit = inspector.splitView as? BoardConversationSplitView
        view = container
        boardHost.sizingOptions = []
        boardHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(boardHost)
        pinToContainer(boardHost)
        addChild(inspector)
    }

    private func pinToContainer(_ child: NSView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setPresentation(presented: Bool, maximized: Bool) {
        loadViewIfNeeded()
        if self.presented != presented {
            self.presented = presented
            if presented {
                inspector.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(inspector.view, positioned: .above, relativeTo: boardHost)
                pinToContainer(inspector.view)
                inspector.prepareForPresentation()
            } else {
                inspector.rememberRegularWidth()
                // Detach without recreating the host. Hidden content must not
                // retain mouse tracking, accessibility, or popover anchors.
                inspector.view.removeFromSuperview()
            }
        }
        inspector.setMaximized(maximized)
    }
}

@MainActor
final class BoardConversationSplitController: NSSplitViewController {
    let conversationHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let leadingController = NSViewController()
    private let conversationController = NSViewController()
    private let defaults: UserDefaults
    private var regularWidth: CGFloat
    private var restoreWidthOnLayout = true
    private(set) var maximized = false

    var conversationFrame: CGRect { conversationController.view.frame }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        regularWidth = BoardConversationSizing.regularWidth(
            CGFloat(defaults.double(forKey: BoardConversationSizing.widthPreference)))
        super.init(nibName: nil, bundle: nil)
        let split = BoardConversationSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.setAccessibilityIdentifier("board.conversation-split")
        split.onDividerDragEnded = { [weak self] in self?.rememberRegularWidth() }
        splitView = split

        leadingController.view = NSView()
        conversationHost.sizingOptions = []
        conversationController.view = conversationHost

        let leading = NSSplitViewItem(viewController: leadingController)
        leading.minimumThickness = 0
        leading.canCollapse = false
        leading.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        leading.holdingPriority = NSLayoutConstraint.Priority(200)
        let conversation = NSSplitViewItem(inspectorWithViewController: conversationController)
        conversation.minimumThickness = BoardConversationSizing.minimumWidth
        conversation.maximumThickness = BoardConversationSizing.maximumWidth
        conversation.canCollapse = false
        conversation.canCollapseFromWindowResize = false
        conversation.holdingPriority = NSLayoutConstraint.Priority(480)
        addSplitViewItem(leading)
        addSplitViewItem(conversation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard restoreWidthOnLayout, !maximized, splitView.bounds.width >= BoardConversationSizing.minimumWidth else {
            return
        }
        restoreWidthOnLayout = false
        let width = min(regularWidth, splitView.bounds.width)
        splitView.setPosition(splitView.bounds.maxX - width, ofDividerAt: 0)
    }

    func prepareForPresentation() {
        restoreWidthOnLayout = true
        view.needsLayout = true
    }

    func setMaximized(_ value: Bool) {
        guard maximized != value else { return }
        if value { rememberRegularWidth() }
        maximized = value
        (splitView as? BoardConversationSplitView)?.maximized = value
        if value {
            splitViewItems[1].maximumThickness = 1_000_000
            splitViewItems[0].isCollapsed = true
            restoreWidthOnLayout = false
        } else {
            splitViewItems[0].isCollapsed = false
            splitViewItems[1].maximumThickness = BoardConversationSizing.maximumWidth
            restoreWidthOnLayout = true
        }
        view.needsLayout = true
    }

    func rememberRegularWidth() {
        guard !maximized, !restoreWidthOnLayout, conversationHost.window != nil else { return }
        regularWidth = BoardConversationSizing.regularWidth(conversationFrame.width)
        defaults.set(Double(regularWidth), forKey: BoardConversationSizing.widthPreference)
    }

    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let native = super.splitView(
            splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return maximized ? native : native.union(drawnRect.insetBy(dx: -4, dy: 0))
    }
}

/// NSSplitViewController may wrap its split view. Bypass that wrapper for the
/// uncovered board, while keeping divider and conversation input native.
final class BoardConversationContainerView: NSView {
    weak var boardHost: NSView?
    weak var overlaySplit: BoardConversationSplitView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let split = overlaySplit, split.window != nil, !split.maximized,
            let leading = split.arrangedSubviews.first
        {
            let local = split.convert(point, from: superview)
            if leading.frame.contains(local), !split.dividerTrackingRect.contains(local) {
                return boardHost?.hitTest(convert(point, from: superview))
            }
        }
        return super.hitTest(point)
    }
}

/// The empty leading pane exposes the Kanban underneath. Only the native divider
/// and the conversation consume input; AppKit owns divider tracking and cursors.
final class BoardConversationSplitView: NSSplitView {
    var onDividerDragEnded: (() -> Void)?
    var maximized = false

    var dividerTrackingRect: CGRect {
        guard !maximized, arrangedSubviews.count == 2 else { return .zero }
        return CGRect(
            x: arrangedSubviews[0].frame.maxX - 4, y: bounds.minY,
            width: dividerThickness + 8, height: bounds.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if dividerTrackingRect.contains(local) { return self }
        if !maximized, let leading = arrangedSubviews.first, leading.frame.contains(local) { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let trackingDivider = dividerTrackingRect.contains(convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if trackingDivider { onDividerDragEnded?() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !maximized { addCursorRect(dividerTrackingRect, cursor: .resizeLeftRight) }
    }
}
