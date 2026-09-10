import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDirectoryChangesRedirect: View {
    @Environment(ConversationContext.self) private var context

    var body: some View {
        ContentUnavailableView {
            Label("Changes belong to the project", systemImage: "folder.badge.gearshape")
        } description: {
            Text(
                "This conversation uses the shared project directory. Its local changes are shown once for the checkout, independent of any card."
            )
        } actions: {
            Button("Open Project Changes") {
                let projectID =
                    (context.selectedCard ?? context.selectedDetail?.card)?.projectID ?? context.selectedProjectID
                Task { await context.openProjectChanges(projectID) }
            }
            .buttonStyle(DieterPrimaryButtonStyle())
            .accessibilityIdentifier("changes.open-project")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationChrome: View {
    @Environment(ConversationContext.self) private var context
    let compact: Bool
    let standalone: Bool
    @Binding var tab: String
    var maximized = false
    var onToggleMaximize: (() -> Void)? = nil
    @State private var editCardPresented = false
    @State private var workspaceSettingsPresented = false

    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }
    private var status: String { context.conversation?.conversation.status ?? card?.runtime ?? "idle" }
    private var subagentCount: Int { context.conversation?.conversation.subagents.count ?? 0 }

    var body: some View {
        FluidPaneChrome(background: compact ? .clear : DieterTheme.background, spacing: 8) {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card?.title.isEmpty == false ? card!.title : "Conversation")
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = context.selectedDetail {
                                Text("\(detail.project.name) · \(detail.board.name)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        sidebarActions
                    }
                    HStack(spacing: 10) {
                        StatusPill(text: status, color: runtimeColor(status))
                        if let card, !card.workspaceMode.isEmpty {
                            Button {
                                tab = "Changes"
                            } label: {
                                WorkspaceSummaryBadge(card: card)
                            }
                            .buttonStyle(.plain).accessibilityLabel("Open workspace changes")
                        }
                        Spacer(minLength: 0)
                        if context.conversationSyncing {
                            ProgressView().controlSize(.mini).accessibilityLabel("Refreshing conversation")
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card?.title.isEmpty == false ? card!.title : "Conversation")
                            .font(DieterFont.paneTitle).lineLimit(1)
                        HStack(spacing: 4) {
                            if let detail = context.selectedDetail {
                                Text(detail.project.name).lineLimit(1)
                                Text(standalone ? "· Standalone chat" : "/ \(detail.board.name)").lineLimit(1)
                            }
                            if let id = card?.id, !id.isEmpty {
                                Text("· \(id.prefix(8))").font(.system(size: 10).monospaced()).lineLimit(1)
                            }
                            if card != nil {
                                Text("·")
                                Text(
                                    ConversationRefreshText.label(
                                        lastRefreshedAt: context.conversationLastRefreshedAt,
                                        syncing: context.conversationSyncing,
                                        now: .now
                                    )
                                )
                                .lineLimit(1)
                                .accessibilityIdentifier("conversation-last-refreshed")
                                if context.conversationSyncing {
                                    ProgressView().controlSize(.mini)
                                        .accessibilityLabel("Refreshing conversation")
                                }
                            }
                        }
                        .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer(minLength: 10)
                    if let card, !card.workspaceMode.isEmpty {
                        Button {
                            tab = "Changes"
                        } label: {
                            WorkspaceSummaryBadge(card: card)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open workspace changes")
                    }
                    StatusPill(text: status, color: runtimeColor(status))
                    conversationMenu
                }
            }
        } secondary: {
            ConversationTabBar(
                items: standalone
                    ? [
                        ("Conversation", 0), ("Changes", Int(card?.workspace.changedFiles ?? 0)),
                        ("Subagents", subagentCount),
                    ]
                    : [
                        ("Conversation", 0),
                        ("Changes", Int(card?.workspace.changedFiles ?? 0)),
                        ("Comments", Int(context.selectedDetail?.card.commentCount ?? 0)),
                        ("Subagents", subagentCount),
                    ],
                selection: $tab
            )
        }
        .sheet(isPresented: $editCardPresented) {
            if let card {
                EditCardSheet(card: card).environment(context)
            }
        }
        .sheet(isPresented: $workspaceSettingsPresented) {
            if let card { ConversationWorkspaceSettingsSheet(model: context.worktreeChanges, card: card) }
        }
    }
    private var sidebarActions: some View {
        HStack(spacing: 3) {
            conversationMenu
            if let onToggleMaximize {
                Button(action: onToggleMaximize) {
                    Image(
                        systemName: maximized
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                }
                .accessibilityLabel(
                    maximized ? "Restore conversation size" : "Expand conversation over board"
                )
                .accessibilityValue(maximized ? "Expanded" : "Side panel")
                .quickHelp(maximized ? "Restore size" : "Maximize")
                .accessibilityIdentifier("board.conversation-maximize")
                .smokeTarget("board.conversation-maximize")
            }
            Button {
                context.closeConversation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Close conversation")
            .quickHelp("Close")
            .accessibilityIdentifier("board.conversation-close")
            .smokeTarget("board.conversation-close")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    @ViewBuilder private var conversationMenu: some View {
        if let card {
            Menu {
                if context.isFailedOutboxItem(card.id) {
                    Button("Retry queued creation") { Task { await context.retryOutboxItem(card.id) } }
                    Button("Discard queued creation", role: .destructive) {
                        Task { await context.discardOutboxItem(card.id) }
                    }
                    Divider()
                }
                if standalone {
                    Button(card.pinned ? "Unpin chat" : "Pin chat") {
                        Task { await context.pin(card, pinned: !card.pinned) }
                    }
                }
                Button("Fork as new chat", systemImage: "arrow.triangle.branch") {
                    Task { await context.fork(card) }
                }
                if !standalone, BoardCardEditingPolicy.canEditDraft(card) {
                    Button("Edit card…") { editCardPresented = true }
                }
                if card.initialPromptSentAt.isEmpty && card.workspace.revision.isEmpty {
                    Button("Workspace settings…", systemImage: "slider.horizontal.3") {
                        workspaceSettingsPresented = true
                    }
                }
                Button("Open workspace in Files", systemImage: "folder") {
                    Task { await context.openWorkspaceFiles(card: card) }
                }
                Button("New terminal in workspace", systemImage: "terminal") {
                    Task { await context.openWorkspaceTerminal(card: card) }
                }
                if ["running", "starting", "waiting_for_user"].contains(status) {
                    Button("Interrupt agent", role: .destructive) { Task { await context.cancel(card) } }
                }
                Divider()
                Button("Archive \(standalone ? "chat" : "card")", role: .destructive) {
                    Task { await context.archive(card, archived: true) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Conversation actions")
            .quickHelp("More")
        }
    }

}

struct ConversationTabBar: View {
    let items: [(String, Int)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.0) { item in
                Button {
                    selection = item.0
                } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Text(item.0).lineLimit(1)
                            if item.1 > 0 {
                                ConversationTabCountBadge(count: item.1, selected: selection == item.0)
                            }
                        }
                        .font(.system(size: 12, weight: selection == item.0 ? .semibold : .medium))
                        .foregroundStyle(selection == item.0 ? DieterTheme.text : DieterTheme.subtle)
                        Capsule().fill(selection == item.0 ? DieterTheme.primary : .clear).frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.1 > 0 ? "\(item.0), \(item.1)" : item.0)
                    .accessibilityIdentifier("conversation-tab-\(item.0.lowercased())")
                    .smokeTarget("conversation-tab-\(item.0.lowercased())")
            }
            Spacer()
        }
    }
}

struct ConversationTabCountBadge: View {
    let count: Int
    let selected: Bool

    var body: some View {
        Text(count, format: .number)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.tertiary)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(selected ? DieterTheme.selection : DieterTheme.raised, in: Capsule())
            .overlay(Capsule().stroke(selected ? DieterTheme.strongBorder : DieterTheme.border))
            .contentTransition(.numericText())
            .accessibilityHidden(true)
    }
}
