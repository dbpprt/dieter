import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

enum ComposerReturnPolicy {
    static func sendsMessage(shiftPressed: Bool) -> Bool { !shiftPressed }
}

enum ConversationRefreshText {
    static func label(lastRefreshedAt: Date?, syncing: Bool, now: Date = Date()) -> String {
        guard let lastRefreshedAt else { return syncing ? "Refreshing…" : "Not refreshed yet" }
        let seconds = max(0, now.timeIntervalSince(lastRefreshedAt))
        let freshness: String
        switch seconds {
        case ..<60:
            freshness = "just now"
        case ..<3_600:
            freshness = "\(Int(seconds / 60))m ago"
        case ..<86_400:
            freshness = "\(Int(seconds / 3_600))h ago"
        default:
            freshness = lastRefreshedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Last refreshed \(freshness)" + (syncing ? " · Refreshing…" : "")
    }
}

enum ConversationActivityPresentation {
    private static let activeStatuses = Set(["starting", "running", "working", "streaming", "cancelling"])

    static func isActive(conversationStatus: String, cardRuntime: String) -> Bool {
        activeStatuses.contains(conversationStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            || activeStatuses.contains(cardRuntime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func turnStart(messages: [Dieter_V1_UiMessage], runtimeUpdatedAt: String) -> Date? {
        if let user = messages.last(where: { $0.role == "user" }),
            let metadata = try? JSONSerialization.jsonObject(with: user.metadataJson) as? [String: Any],
            let value = metadata["createdAt"] as? String,
            let date = DieterTimestamp.date(from: value)
        {
            return date
        }
        return DieterTimestamp.date(from: runtimeUpdatedAt)
    }

    static func liveLabel(pendingTools: [Dieter_V1_PendingTool], plans: [Dieter_V1_TaskPlan]) -> String {
        if let tool = pendingTools.first, !tool.toolName.isEmpty { return "Running \(tool.toolName)…" }
        if let task = plans.last?.phases.flatMap(\.tasks).first(where: { $0.status == "in_progress" }),
            !task.activeForm.isEmpty
        {
            return task.activeForm
        }
        return label(hasPendingTool: !pendingTools.isEmpty)
    }

    static func label(hasPendingTool: Bool) -> String {
        hasPendingTool ? "Working…" : "Thinking…"
    }
}

struct ConversationView: View {
    @Environment(ConversationContext.self) private var context
    var compact = false
    var maximized = false
    var onToggleMaximize: (() -> Void)? = nil
    @State private var tab = "Conversation"
    @State private var fileImportRequest: ConversationFileImportRequest?

    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }

    private var standalone: Bool {
        (context.selectedCard ?? context.selectedDetail?.card)?.scope == "chat"
    }

    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }
    private var startingCard: Bool { card.map { $0.runtime == "starting" } ?? false }
    private var canStartCard: Bool {
        guard let card else { return false }
        return BoardCardStartPolicy.canStart(
            card,
            board: context.selectedDetail?.board,
            hasDraftAttachments: !(context.conversation?.conversation.draftAttachments.isEmpty ?? true)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationChrome(
                compact: compact, standalone: standalone, tab: $tab,
                maximized: maximized, onToggleMaximize: onToggleMaximize)

            Group {
                if context.conversationLoading {
                    LoadFeedback(title: "Loading conversation…")
                } else if let error = context.conversationError, context.conversation == nil {
                    LoadFeedback(
                        title: "Conversation", error: error,
                        retry: {
                            guard let id = context.selectedCardID ?? context.selectedChatID else { return }
                            Task { await context.openConversation(cardID: id, chat: standalone) }
                        })
                } else if tab == "Subagents" {
                    SubagentsView()
                } else if tab == "Comments" {
                    CommentsView(composerBackground: compact ? .clear : DieterTheme.sidebar)
                } else if tab == "Changes" {
                    let card = context.selectedCard ?? context.selectedDetail?.card
                    if ConversationWorkspaceMode.projectMode(
                        card?.workspaceMode.isEmpty == false
                            ? card?.workspaceMode ?? "" : card?.workspace.mode ?? "project") == .project
                    {
                        ProjectDirectoryChangesRedirect()
                    } else {
                        WorkspaceChangesView(model: context.worktreeChanges)
                    }
                } else {
                    ConversationTimeline(background: compact ? .clear : DieterTheme.background)
                        .id(context.selectedCardID ?? context.selectedChatID ?? "")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab == "Conversation" {
                if let card, canStartCard || startingCard {
                    ConversationStartCardBanner(card: card, starting: startingCard)
                }
                ConversationComposer(background: compact ? .clear : DieterTheme.sidebar) {
                    guard !conversationID.isEmpty else { return }
                    fileImportRequest = ConversationFileImportRequest(conversationID: conversationID)
                }
            }
        }
        .background(compact ? Color.clear : DieterTheme.background)
        .overlay(alignment: .bottom) {
            if let toast = context.workspaceToast {
                WorkspaceToastView(toast: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: context.workspaceToast)
        .onChange(of: context.selectedCardID) { _, _ in tab = "Conversation" }
        .onChange(of: context.selectedChatID) { _, _ in tab = "Conversation" }
        .onChange(of: conversationID) { _, _ in fileImportRequest = nil }
        .onChange(of: tab) { _, _ in fileImportRequest = nil }
        .onDisappear { fileImportRequest = nil }
        #if DIETER_UI_SMOKE
            .onReceive(
                NotificationCenter.default.publisher(for: WorkspaceUISmokeRunner.selectTabNotification)
            ) {
                note in
                if let name = note.object as? String { tab = name }
            }
        #endif
        .background {
            if let request = fileImportRequest {
                ConversationFileImporter(
                    isCurrent: {
                        fileImportRequest?.id == request.id && conversationID == request.conversationID
                    },
                    onCompletion: { result in
                        guard fileImportRequest?.id == request.id,
                            conversationID == request.conversationID
                        else { return }
                        fileImportRequest = nil
                        switch result {
                        case .success(let urls): context.addAttachments(urls)
                        case .failure(let error): context.show(error)
                        }
                    }
                )
                .id(request.id)
            }
        }
        // AttachmentPasteMonitor is the single owner of ⌘V. Registering an
        // onPasteCommand here too can append the same clipboard image twice.
        .attachmentPasteCatcher { pasteboard in
            context.attachPasteboard(pasteboard)
        }
    }
}

private struct ConversationFileImportRequest: Identifiable {
    let id = UUID()
    let conversationID: String
}

/// Each presentation owns its delay and completion, so leaving a conversation
/// cannot open a picker later or deliver its result to another draft.
private struct ConversationFileImporter: View {
    var isCurrent: () -> Bool
    var onCompletion: (Result<[URL], Error>) -> Void
    @State private var presented = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fileImporter(
                isPresented: $presented, allowedContentTypes: [.item], allowsMultipleSelection: true,
                onCompletion: onCompletion
            )
            .task {
                do {
                    // Let the attachment source popover finish dismissing.
                    try await DieterTaskSleep.milliseconds(250)
                    guard !Task.isCancelled, isCurrent() else { return }
                    presented = true
                } catch {}
            }
            .onDisappear { presented = false }
    }
}
