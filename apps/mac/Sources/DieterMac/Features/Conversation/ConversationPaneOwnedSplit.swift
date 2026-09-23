import AppKit
import SwiftUI

/// A board conversation extends its real split through the full-size titlebar.
/// Each split item owns its titlebar strip, so tabs, separators, and pointer
/// tracking move in the same AppKit layout pass as the pane itself.
struct ConversationPaneOwnedSplit<ChatBar: View, Chat: View, WorkspaceBar: View, Content: View>:
    NSViewControllerRepresentable
{
    let presented: Bool
    var singleWorkspace = false
    @ViewBuilder let chatBar: () -> ChatBar
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let workspaceBar: () -> WorkspaceBar
    @ViewBuilder let content: () -> Content

    func makeNSViewController(context: Context) -> ConversationPaneOwnedSplitController {
        ConversationPaneOwnedSplitController()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController: ConversationPaneOwnedSplitController,
        context: Context
    ) -> CGSize? {
        // NSSplitViewController has no useful intrinsic size while its second
        // item starts collapsed. Accept the parent proposal explicitly so the
        // conversation-only state fills the outer board pane on first mount.
        guard let width = proposal.width, let height = proposal.height,
            width.isFinite, height.isFinite
        else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSViewController(_ controller: ConversationPaneOwnedSplitController, context: Context) {
        controller.chatColumn.titlebarHost.rootView = AnyView(chatBar())
        controller.chatColumn.contentHost.rootView = AnyView(chat())
        controller.workspaceColumn.titlebarHost.rootView = AnyView(workspaceBar())
        controller.workspaceColumn.contentHost.rootView = AnyView(content())
        controller.setPresentation(split: presented, singleWorkspace: singleWorkspace)
    }
}

@MainActor
final class ConversationPaneOwnedSplitController: NSSplitViewController {
    let chatColumn = ConversationPaneOwnedColumnController(identifier: "conversation.pane.chat")
    let workspaceColumn = ConversationPaneOwnedColumnController(identifier: "conversation.pane.workspace")
    private var presented = false
    private var singleWorkspace = false
    private var restorePosition = false
    private var restoreScheduled = false

    var chatItem: NSSplitViewItem { splitViewItems[0] }
    var workspaceItem: NSSplitViewItem { splitViewItems[1] }

    init() {
        super.init(nibName: nil, bundle: nil)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.setAccessibilityIdentifier("conversation.workspace-split")
        splitView = split

        let chatItem = NSSplitViewItem(viewController: chatColumn)
        chatItem.automaticallyAdjustsSafeAreaInsets = false
        chatItem.minimumThickness = 1
        chatItem.canCollapse = false
        chatItem.canCollapseFromWindowResize = false
        chatItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        chatItem.holdingPriority = NSLayoutConstraint.Priority(480)

        let workspaceItem = NSSplitViewItem(viewController: workspaceColumn)
        workspaceItem.automaticallyAdjustsSafeAreaInsets = false
        workspaceItem.minimumThickness = 0
        workspaceItem.canCollapse = false
        workspaceItem.canCollapseFromWindowResize = false
        workspaceItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        workspaceItem.holdingPriority = NSLayoutConstraint.Priority(360)
        workspaceItem.isCollapsed = true

        addSplitViewItem(chatItem)
        addSplitViewItem(workspaceItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLayout() {
        super.viewDidLayout()
        schedulePositionRestore()
    }

    func setPresented(_ presented: Bool) {
        setPresentation(split: presented, singleWorkspace: false)
    }

    func setPresentation(split presented: Bool, singleWorkspace: Bool) {
        guard self.presented != presented || self.singleWorkspace != singleWorkspace else { return }
        self.presented = presented
        self.singleWorkspace = singleWorkspace
        // Explicitly establish both retained items. Like the Markdown native
        // split, collapsing the outgoing item first avoids AppKit preserving
        // the previous two-pane allocation when returning to one pane.
        if !presented { workspaceItem.isCollapsed = !singleWorkspace }
        chatItem.isCollapsed = !presented && singleWorkspace
        workspaceItem.isCollapsed = !presented && !singleWorkspace
        restorePosition = presented
        view.needsLayout = true
        schedulePositionRestore()
    }

    private func schedulePositionRestore() {
        guard presented, restorePosition, splitView.bounds.width > 0, !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreScheduled = false
            guard self.presented, self.restorePosition, self.splitView.bounds.width > 0 else { return }
            self.restorePosition = false
            let available = max(0, self.splitView.bounds.width - self.splitView.dividerThickness)
            self.splitView.setPosition(
                available * ConversationContentSizing.conversationFraction,
                ofDividerAt: 0
            )
        }
    }
}

@MainActor
final class ConversationPaneOwnedColumnController: NSViewController {
    let titlebarHost = ConversationTitlebarHostingView(rootView: AnyView(EmptyView()))
    let contentHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let accessibilityIdentifier: String

    init(identifier: String) {
        accessibilityIdentifier = identifier
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier(accessibilityIdentifier)
        titlebarHost.sizingOptions = []
        contentHost.sizingOptions = []
        titlebarHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titlebarHost)
        container.addSubview(contentHost)
        NSLayoutConstraint.activate([
            titlebarHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titlebarHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            titlebarHost.topAnchor.constraint(equalTo: container.topAnchor),
            titlebarHost.heightAnchor.constraint(equalToConstant: 40),
            contentHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: titlebarHost.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }
}

/// The pane's titlebar is actual split content, not a safe-area-aware SwiftUI
/// overlay. Inheriting the window titlebar inset moves a 40pt rail partly
/// outside its 40pt native host and clips its pointer target.
@MainActor
final class ConversationTitlebarHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var safeAreaRect: NSRect { bounds }
}

struct ConversationPaneSurfaceBar: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    let workspacePresented: Bool
    let kanbanPresented: Bool
    let toggleKanban: () -> Void
    var showsKanban = true

    private var standalone: Bool {
        (context.selectedCard ?? context.selectedDetail?.card)?.scope == "chat"
    }

    var body: some View {
        ConversationPaneTitlebar {
            if workspacePresented {
                HStack(spacing: 6) {
                    ConversationTitleStatusMenu(standalone: standalone, actionHeight: 40)
                    if showsKanban {
                        ConversationSurfaceToggles(
                            model: model,
                            workspacePresented: true,
                            kanbanPresented: kanbanPresented,
                            toggleKanban: toggleKanban,
                            showsConversation: false,
                            height: 40
                        )
                    }
                }
            } else {
                HStack(spacing: 6) {
                    if showsKanban {
                        ConversationSurfaceToggles(
                            model: model,
                            workspacePresented: false,
                            kanbanPresented: kanbanPresented,
                            toggleKanban: toggleKanban,
                            showsConversation: false,
                            height: 40
                        )
                        Divider()
                            .frame(height: 18)
                            .padding(.horizontal, 2)
                    }
                    ConversationWorkspaceTabBar(
                        model: model,
                        nativeToolbar: true,
                        includesConversation: true,
                        showsControls: false
                    )
                    .frame(minWidth: 0, maxWidth: .infinity)
                    ConversationWorkspaceControls(model: model, height: 40)
                        .fixedSize()
                    ConversationCloseButton(height: 40)
                }
                .environment(context)
            }
        }
        .accessibilityIdentifier(
            workspacePresented
                ? "conversation.toolbar.rail.surfaces" : "conversation.toolbar.rail.unified"
        )
    }
}

struct ConversationPaneWorkspaceBar: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    let kanbanPresented: Bool
    let toggleKanban: () -> Void
    var showsKanban = true

    private var standalone: Bool {
        (context.selectedCard ?? context.selectedDetail?.card)?.scope == "chat"
    }

    var body: some View {
        ConversationPaneTitlebar {
            HStack(spacing: 6) {
                if !model.splitMode {
                    ConversationActionsMenu(standalone: standalone, height: 40)
                }
                if !model.splitMode && showsKanban {
                    ConversationSurfaceToggles(
                        model: model, workspacePresented: false,
                        kanbanPresented: kanbanPresented, toggleKanban: toggleKanban,
                        showsConversation: false,
                        height: 40
                    )
                    Divider().frame(height: 18).padding(.horizontal, 2)
                }
                ConversationWorkspaceTabBar(
                    model: model,
                    nativeToolbar: true,
                    includesConversation: !model.splitMode,
                    showsControls: false
                )
                .frame(minWidth: 0, maxWidth: .infinity)
                ConversationWorkspaceControls(model: model, height: 40)
                    .fixedSize()
                ConversationCloseButton(height: 40)
            }
        }
        .accessibilityIdentifier("conversation.toolbar.rail.sidebar")
    }
}

struct ConversationPaneTitlebar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(DieterTheme.surface)
            .overlay(alignment: .bottom) { Divider() }
    }
}
