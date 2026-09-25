import AppKit
import SwiftUI

/// Native resizing and collapse without an additional system sidebar material.
/// The workspace owns one backdrop beneath both columns, including the titlebar.
struct WorkspaceSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    @Binding var visibility: NavigationSplitViewVisibility
    @Binding var sidebarWidth: Double
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    func makeNSViewController(context: Context) -> WorkspaceSplitController { WorkspaceSplitController() }

    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
        controller.sidebarHost.rootView = AnyView(sidebar().environment(\.self, context.environment))
        controller.detailHost.rootView = AnyView(detail().environment(\.self, context.environment))
        controller.onWidthChange = { sidebarWidth = Double($0) }
        controller.onVisibilityChange = { visibility = $0 ? .all : .detailOnly }
        controller.configure(width: CGFloat(sidebarWidth), visible: visibility != .detailOnly)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController: WorkspaceSplitController, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

@MainActor final class WorkspaceSplitController: NSSplitViewController {
    let sidebarHost = NSHostingView(rootView: AnyView(EmptyView()))
    let detailHost = NSHostingView(rootView: AnyView(EmptyView()))
    var onWidthChange: ((CGFloat) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private var preferredWidth = SidebarSizing.defaultWidth
    private var appliedWidth: CGFloat?
    private var layoutScheduled = false
    private var configuring = false

    override init(nibName: NSNib.Name? = nil, bundle: Bundle? = nil) {
        super.init(nibName: nibName, bundle: bundle)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.setAccessibilityIdentifier("workspace.navigation-split")
        splitView = split
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        let sidebarController = NSViewController()
        sidebarController.view = sidebarHost
        let detailController = NSViewController()
        detailController.view = detailHost
        let sidebar = NSSplitViewItem(viewController: sidebarController)
        sidebar.automaticallyAdjustsSafeAreaInsets = false
        sidebar.minimumThickness = SidebarSizing.minimumWidth
        sidebar.maximumThickness = SidebarSizing.maximumWidth
        sidebar.canCollapse = true
        sidebar.canCollapseFromWindowResize = false
        sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // AppKit divider dragging has priority 490; keep width retention below it.
        sidebar.holdingPriority = NSLayoutConstraint.Priority(480)
        let detail = NSSplitViewItem(viewController: detailController)
        detail.automaticallyAdjustsSafeAreaInsets = false
        detail.minimumThickness = 320
        detail.holdingPriority = NSLayoutConstraint.Priority(250)
        addSplitViewItem(sidebar)
        addSplitViewItem(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(width: CGFloat, visible: Bool) {
        let width = SidebarSizing.clamped(width)
        if abs(width - preferredWidth) > 0.5 { appliedWidth = nil }
        preferredWidth = width
        configuring = true
        if splitViewItems[0].isCollapsed == visible {
            splitViewItems[0].isCollapsed = !visible
            appliedWidth = nil
        }
        configuring = false
        scheduleLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleLayout()
    }

    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            guard !self.splitViewItems[0].isCollapsed, self.view.window != nil else { return }
            if self.appliedWidth == nil {
                // The representable initially lays out at its minimum size.
                // Do not persist that temporary width before the window sizes it.
                guard self.splitView.bounds.width >= self.preferredWidth + 320 + self.splitView.dividerThickness else {
                    return
                }
                self.configuring = true
                self.splitView.setPosition(self.preferredWidth, ofDividerAt: 0)
                self.splitView.layoutSubtreeIfNeeded()
                self.configuring = false
            }
            let width = self.sidebarHost.frame.width
            guard width >= SidebarSizing.minimumWidth, width <= SidebarSizing.maximumWidth else { return }
            self.appliedWidth = width
            if abs(width - self.preferredWidth) > 0.5 {
                self.preferredWidth = width
                self.onWidthChange?(width)
            }
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if !configuring { scheduleLayout() }
    }

    override func toggleSidebar(_ sender: Any?) {
        let visible = splitViewItems[0].isCollapsed
        configure(width: preferredWidth, visible: visible)
        onVisibilityChange?(visible)
    }
}
