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
            .accessibilityIdentifier("changes.open-project").smokeTarget("changes.open-project")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationChrome: View {
    @Environment(ConversationContext.self) private var context
    @Environment(\.conversationWorkspaceTabsInTitlebar) private var tabsInTitlebar
    let compact: Bool
    let standalone: Bool
    @Binding var tab: String

    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }
    private var status: String { context.conversation?.conversation.status ?? card?.runtime ?? "idle" }
    private var subagentCount: Int { context.conversation?.conversation.subagents.count ?? 0 }
    private var workspacePresented: Bool {
        context.content.splitMode
            && context.content.isPresented(for: context.selectedCardID ?? context.selectedChatID)
    }
    private var showsWorkspaceMetadata: Bool {
        context.selectedDetail != nil || card?.workspaceMode.isEmpty == false || context.conversationSyncing
    }

    var body: some View {
        if tabsInTitlebar && workspacePresented {
            EmptyView()
        } else {
            FluidPaneChrome(
                background: .clear, spacing: 8,
                showsSecondary: !tabsInTitlebar
                    && ConversationChromeLayout.showsConversationTabs(workspacePresented: workspacePresented)
            ) {
                if compact {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ConversationTitleStatusMenu(standalone: standalone)
                            if !tabsInTitlebar { ConversationCloseButton() }
                        }
                        if showsWorkspaceMetadata && !tabsInTitlebar {
                            HStack(spacing: 8) {
                                if let detail = context.selectedDetail {
                                    Text(
                                        "\(detail.project.name) · \(standalone ? "Standalone chat" : detail.board.name)"
                                    )
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let card, !card.workspaceMode.isEmpty {
                                    Button {
                                        showChanges(for: card)
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
                            ConversationModelIdentityLabel()
                        }
                        Spacer(minLength: 10)
                        if let card, !card.workspaceMode.isEmpty {
                            Button {
                                showChanges(for: card)
                            } label: {
                                WorkspaceSummaryBadge(card: card)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open workspace changes")
                        }
                        StatusPill(text: status, color: runtimeColor(status))
                            .accessibilityIdentifier("conversation.status")
                            .smokeTarget("conversation.status")
                        if !tabsInTitlebar { ConversationActionsMenu(standalone: standalone) }
                    }
                }
            } secondary: {
                ConversationTabBar(
                    items: conversationTabs,
                    selection: $tab
                )
            }
        }
    }

    private var conversationTabs: [(String, Int)] {
        if standalone {
            return [
                ("Conversation", 0), ("Changes", Int(card?.workspace.changedFiles ?? 0)),
                ("Subagents", subagentCount),
            ]
        }
        return [
            ("Conversation", 0),
            ("Changes", Int(card?.workspace.changedFiles ?? 0)),
            ("Subagents", subagentCount),
        ]
    }

    private func showChanges(for card: Dieter_V1_Card) {
        tab = "Changes"
        context.content.showEmpty(conversationID: card.id)
    }

}

struct ConversationModelIdentityLabel: View {
    @Environment(ConversationContext.self) private var context

    private var identity: String? {
        let card = context.selectedCard ?? context.selectedDetail?.card
        let provider = card?.provider.isEmpty == false ? card!.provider : context.composerProvider
        if provider == "claude-code",
            let assistant = context.conversation?.conversation.messages.last(where: { $0.role == "assistant" }),
            let metadata = try? JSONSerialization.jsonObject(with: assistant.metadataJson) as? [String: Any],
            let modelID = metadata["modelId"] as? String,
            !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Last reply model · \(modelID)"
        }

        let selected = context.composerModel.isEmpty ? (card?.model ?? "") : context.composerModel
        guard !selected.isEmpty else { return nil }
        if provider == "claude-code" {
            return selected == "opus" || selected == "sonnet" || selected == "haiku"
                ? "Selected alias · \(selected)"
                : "Selected model · \(selected)"
        }
        let name =
            context.harnessCatalog.harnesses.first(where: { $0.id == provider })?
            .models.first(where: { $0.id == selected })?.name ?? selected
        return "Selected model · \(name)"
    }

    var body: some View {
        if let identity {
            Text(identity)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .quickHelp(identity)
                .accessibilityLabel(identity)
                .accessibilityIdentifier("conversation.model-identity")
        }
    }
}

struct ConversationTitleStatusMenu: View {
    @Environment(ConversationContext.self) private var context
    let standalone: Bool
    var actionHeight: CGFloat = 24

    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }
    private var status: String { context.conversation?.conversation.status ?? card?.runtime ?? "idle" }

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text(card?.title.isEmpty == false ? card!.title : "Conversation")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                ConversationModelIdentityLabel()
            }
            .layoutPriority(1)
            StatusPill(text: status, color: runtimeColor(status))
                .accessibilityIdentifier("conversation.status")
                .smokeTarget("conversation.status")
            ConversationActionsMenu(standalone: standalone, height: actionHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationCloseButton: View {
    @Environment(ConversationContext.self) private var context
    var height: CGFloat = 24

    var body: some View {
        Button {
            context.closeConversation()
        } label: {
            ConversationWorkspaceSymbol(
                systemName: "xmark", frameSize: ConversationWorkspaceChromeMetrics.actionSize
            )
            .frame(width: 28, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Close conversation")
        .quickHelp("Close")
        .accessibilityIdentifier("board.conversation-close")
        .smokeTarget("board.conversation-close")
    }
}

struct ConversationActionsMenu: View {
    @Environment(ConversationContext.self) private var context
    let standalone: Bool
    var height: CGFloat = 24
    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }
    private var status: String { context.conversation?.conversation.status ?? card?.runtime ?? "idle" }

    var body: some View {
        menu
    }

    @ViewBuilder private var menu: some View {
        if let card {
            Menu {
                Button("Fork as new chat", systemImage: "arrow.triangle.branch") {
                    Task { await context.fork(card) }
                }
                if ["running", "starting", "waiting_for_user"].contains(status) {
                    Button("Halt agent", role: .destructive) { Task { await context.cancel(card) } }
                }
                Divider()
                Button("Archive \(standalone ? "chat" : "card")", role: .destructive) {
                    Task { await context.archive(card, archived: true) }
                }
            } label: {
                ConversationWorkspaceSymbol(
                    systemName: "ellipsis", frameSize: ConversationWorkspaceChromeMetrics.actionSize
                )
                .frame(width: 28, height: height)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Conversation actions")
            .quickHelp("More")
        }
    }
}

enum ConversationChromeLayout {
    static func showsConversationTabs(workspacePresented: Bool) -> Bool { true }
}

enum ConversationWorkspaceChromeMetrics {
    static let symbolSize: CGFloat = 12
    static let actionSize: CGFloat = 24
    static let titlebarHeight: CGFloat = 40
    static let tabHeight: CGFloat = 36
}

struct ConversationWorkspaceSymbol: View {
    let systemName: String
    var selected = false
    var frameSize: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .symbolVariant(selected ? .fill : .none)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: ConversationWorkspaceChromeMetrics.symbolSize, weight: .medium))
            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
            .frame(width: frameSize, height: frameSize)
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

struct ConversationTitlebarHeader: View {
    let workspacePresented: Bool
    let workspaceEnabled: Bool
    let toggleWorkspace: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Conversation")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DieterTheme.text)
                .lineLimit(1)
                .padding(.leading, 9)
                .accessibilityIdentifier("conversation.titlebar-header")
            Divider()
                .frame(height: 16)
            Button(action: toggleWorkspace) {
                ConversationWorkspaceSymbol(
                    systemName: "sidebar.right", selected: workspacePresented,
                    frameSize: ConversationWorkspaceChromeMetrics.actionSize)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(
                workspacePresented ? DieterTheme.elevated : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .accessibilityLabel(workspacePresented ? "Hide workspace" : "Open workspace")
            .accessibilityValue(workspacePresented ? "Expanded" : "Collapsed")
            .help(workspacePresented ? "Hide workspace" : "Open workspace")
            .accessibilityIdentifier("conversation.content.toggle")
            .smokeTarget("conversation.content.toggle")
            .disabled(!workspaceEnabled)
            Spacer(minLength: 0)
        }
        .frame(
            maxWidth: .infinity, minHeight: ConversationWorkspaceChromeMetrics.titlebarHeight,
            maxHeight: ConversationWorkspaceChromeMetrics.titlebarHeight, alignment: .leading
        )
        .background(DieterTheme.surface)
        .overlay(alignment: .bottom) { Divider() }
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
