import DieterAPI
import DieterShared
import SwiftUI

/// The conversation panel's header: a status dot, the title, the runtime
/// capsule and glass actions; a breadcrumb; then one segmented track of the
/// conversation's surfaces and workspace tabs.
enum ConversationPanelHeaderMetrics {
    static let titleRowHeight: CGFloat = 44
    static let breadcrumbHeight: CGFloat = 16
    static let trackRowHeight: CGFloat = 48
    /// The full header: title, breadcrumb, and the tab track.
    static let fullHeight: CGFloat = titleRowHeight + breadcrumbHeight + trackRowHeight
    /// One row: the title beside a split workspace, or the workspace's track.
    static let rowHeight: CGFloat = 44
    static let circleSize: CGFloat = 28
}

/// Which part of the header a column shows.
enum ConversationPanelHeaderRole {
    /// The conversation alone: title, breadcrumb, and every tab.
    case unified
    /// The conversation beside a split workspace: the title row only.
    case chatBesideWorkspace
    /// The split workspace: its tabs and controls.
    case workspaceBesideChat
    /// A workspace tab shown alone in place of the conversation.
    case singleWorkspace
}

struct ConversationPanelHeader: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    let role: ConversationPanelHeaderRole
    var kanbanPresented = false
    var toggleKanban: (() -> Void)?

    private var standalone: Bool { context.model.state.chat }

    var body: some View {
        switch role {
        case .unified, .singleWorkspace:
            VStack(alignment: .leading, spacing: 0) {
                ConversationTitleRow(
                    standalone: standalone, kanbanPresented: kanbanPresented, toggleKanban: toggleKanban,
                    showsSplitControls: true, model: model
                )
                .frame(height: ConversationPanelHeaderMetrics.titleRowHeight)
                ConversationBreadcrumb(standalone: standalone)
                    .frame(height: ConversationPanelHeaderMetrics.breadcrumbHeight, alignment: .top)
                ConversationTabTrack(model: model, includesConversation: true)
                    .frame(height: ConversationPanelHeaderMetrics.trackRowHeight)
            }
        case .chatBesideWorkspace:
            ConversationTitleRow(
                standalone: standalone, kanbanPresented: kanbanPresented, toggleKanban: toggleKanban,
                showsSplitControls: false, model: model
            )
            .frame(height: ConversationPanelHeaderMetrics.rowHeight)
        case .workspaceBesideChat:
            HStack(spacing: 8) {
                ConversationTabTrack(model: model, includesConversation: false)
                ConversationSplitToggle(model: model)
                ConversationCloseButton()
            }
            .frame(height: ConversationPanelHeaderMetrics.rowHeight)
        }
    }
}

/// Status dot, title, runtime capsule, and the panel's glass actions.
struct ConversationTitleRow: View {
    @Environment(ConversationContext.self) private var context
    let standalone: Bool
    let kanbanPresented: Bool
    let toggleKanban: (() -> Void)?
    let showsSplitControls: Bool
    @Bindable var model: ConversationContentModel

    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }
    /// The runtime to show, as the core presents the conversation.
    private var status: String { context.model.state.runtime }

    var body: some View {
        HStack(spacing: 8) {
            DieterStatusDot(color: runtimeColor(status))
            Text(card?.title.isEmpty == false ? card!.title : "Conversation")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DieterTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(card?.title ?? "")
            StatusPill(runtime: status, showsDot: false)
                .accessibilityIdentifier("conversation.status")
                .smokeTarget("conversation.status")
            Spacer(minLength: 6)
            if context.conversationSyncing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing…")
                        .font(.system(size: 11))
                        .foregroundStyle(DieterTheme.tertiary)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Refreshing conversation")
                .accessibilityIdentifier("conversation.refreshing")
                .help("Checking for updates. Displayed activity may be out of date.")
            }
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if let toggleKanban {
                        ConversationKanbanToggle(presented: kanbanPresented, toggle: toggleKanban)
                    }
                    ConversationActionsMenu(standalone: standalone)
                    if showsSplitControls {
                        ConversationCloseButton()
                    }
                }
            }
        }
    }
}

/// `project › board › c_1234` for a card, `project › Chat` for a chat.
struct ConversationBreadcrumb: View {
    @Environment(ConversationContext.self) private var context
    let standalone: Bool

    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }

    private var parts: [String] {
        guard let detail = context.selectedDetail else { return [] }
        var parts = [detail.project.name]
        parts.append(standalone ? "Chat" : detail.board.name)
        if let id = card?.id, !id.isEmpty, !standalone { parts.append(String(id.prefix(8))) }
        return parts.filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .semibold))
                }
                Text(part)
                    .font(index == 2 ? DieterFont.mono : .system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let card {
                let badge = WorkspaceBadge.of(card)
                let branch = card.workspace.branch.isEmpty ? card.workspaceBranch : card.workspace.branch
                if badge.conflicted || !branch.isEmpty {
                    Text("·")
                    DieterBranchLabel(text: badge.conflicted ? badge.fullTitle : branch)
                        .foregroundStyle(badge.conflicted ? DieterTheme.failed : DieterTheme.tertiary)
                        .help(badge.accessibilityLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(DieterTheme.tertiary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.breadcrumb")
    }
}

/// Conversation · Changes · Subagents and the workspace tabs, in one glass track,
/// followed by the add-tab menu.
struct ConversationTabTrack: View {
    @Bindable var model: ConversationContentModel
    let includesConversation: Bool

    var body: some View {
        HStack(spacing: 6) {
            ConversationWorkspaceTabBar(
                model: model,
                includesConversation: includesConversation,
                showsControls: false
            )
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .dieterCapsuleChrome(interactive: false)
            ConversationAddTabMenu(model: model)
            if includesConversation { ConversationSplitToggle(model: model, size: DieterMetrics.capsuleHeight) }
        }
    }
}

/// Shows or hides the Kanban beside the conversation.
struct ConversationKanbanToggle: View {
    let presented: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "rectangle.3.group")
                .symbolVariant(presented ? .fill : .none)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(
            DieterBarButtonStyle(shape: .circle, size: ConversationPanelHeaderMetrics.circleSize)
        )
        .help(presented ? "Hide Kanban" : "Show Kanban")
        .accessibilityLabel("Kanban")
        .accessibilityAddTraits(presented ? [.isSelected] : [])
        .accessibilityIdentifier("conversation-tab-kanban")
        .smokeTarget("conversation-tab-kanban")
    }
}

/// Splits the conversation and its workspace, or returns to one pane.
struct ConversationSplitToggle: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    var size: CGFloat = ConversationPanelHeaderMetrics.circleSize

    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }

    private var workspacePresented: Bool {
        model.splitMode && model.isPresented(for: conversationID)
    }

    var body: some View {
        Button {
            if workspacePresented {
                model.showSinglePane()
            } else {
                model.showEmpty(conversationID: conversationID)
            }
        } label: {
            Image(systemName: workspacePresented ? "rectangle.split.1x2" : "sidebar.right")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(DieterBarButtonStyle(shape: .circle, size: size))
        .help(workspacePresented ? "Single pane" : "Split conversation and workspace")
        .accessibilityLabel(workspacePresented ? "Single pane" : "Split conversation and workspace")
        .accessibilityIdentifier("conversation.content.close").smokeTarget("conversation.content.close")
    }
}

/// Opens a file, terminal, browser, processes, or review tab.
struct ConversationAddTabMenu: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel

    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }

    var body: some View {
        Menu {
            ForEach(model.addablePanelKinds(for: conversationID)) { kind in
                Button(kind.title, systemImage: kind.symbol) {
                    model.requestPanel(kind, conversationID: conversationID)
                }
                .accessibilityIdentifier("conversation.content.add.\(kind.rawValue)")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DieterTheme.text)
                .frame(width: DieterMetrics.capsuleHeight, height: DieterMetrics.capsuleHeight)
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .dieterCircleChrome()
        .help("Open a workspace tab")
        .accessibilityLabel("Open a workspace tab")
        .accessibilityIdentifier("conversation.content.add").smokeTarget("conversation.content.add")
    }
}
