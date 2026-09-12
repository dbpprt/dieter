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

enum ConversationSurfaceStyle: Equatable {
    case canvas
    case inherited
}

struct ConversationView: View {
    @Environment(ConversationContext.self) private var context
    var compact = false
    var maximized = false
    var onToggleMaximize: (() -> Void)? = nil
    var surfaceStyle: ConversationSurfaceStyle = .canvas
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
        ConversationContentSplit(presented: context.content.isPresented(for: conversationID)) {
            conversationBody
        } content: {
            ConversationContentPane(model: context.content)
        }
        .environment(
            \.conversationLinkHandler,
            { url in
                let id = conversationID
                guard !id.isEmpty else { return false }
                context.content.requestOpen(url, conversationID: id)
                return true
            }
        )
        .onChange(of: conversationID) { _, _ in context.content.suspend() }
        .onDisappear { context.content.suspend() }
    }

    private var conversationBody: some View {
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
                    SubagentsView(background: .clear)
                } else if tab == "Comments" {
                    CommentsView(composerBackground: .clear)
                } else if tab == "Changes" {
                    let card = context.selectedCard ?? context.selectedDetail?.card
                    if ConversationWorkspaceMode.projectMode(
                        card?.workspaceMode.isEmpty == false
                            ? card?.workspaceMode ?? "" : card?.workspace.mode ?? "project") == .project
                    {
                        ProjectDirectoryChangesRedirect()
                    } else {
                        WorkspaceChangesView(model: context.worktreeChanges, background: .clear)
                    }
                } else {
                    ConversationTimeline(background: .clear)
                        .id(context.selectedCardID ?? context.selectedChatID ?? "")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if tab == "Conversation" {
                    // Let the transcript scroll behind the glass while its
                    // bottom anchor stays above the composer's measured height.
                    VStack(spacing: 0) {
                        if let card, canStartCard || startingCard {
                            ConversationStartCardBanner(card: card, starting: startingCard)
                        }
                        ConversationComposer(background: .clear) {
                            guard !conversationID.isEmpty else { return }
                            fileImportRequest = ConversationFileImportRequest(conversationID: conversationID)
                        }
                    }
                }
            }
        }
        .background(surfaceStyle == .canvas ? DieterTheme.surface : Color.clear)
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
