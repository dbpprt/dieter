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

    static func label(hasPendingTool: Bool) -> String {
        hasPendingTool ? "Working…" : "Thinking…"
    }
}

struct ConversationView: View {
    @Environment(ConversationContext.self) private var context
    var compact = false
    @State private var tab = "Conversation"
    @State private var fileImporterPresented = false

    private var standalone: Bool {
        (context.selectedCard ?? context.selectedDetail?.card)?.scope == "chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationChrome(compact: compact, standalone: standalone, tab: $tab)

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
                    CommentsView()
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
                    ConversationTimeline()
                        .id(context.selectedCardID ?? context.selectedChatID ?? "")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab == "Conversation" {
                ConversationComposer(fileImporterPresented: $fileImporterPresented)
            }
        }
        .background(DieterTheme.background)
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
        #if DIETER_UI_SMOKE
            .onReceive(NotificationCenter.default.publisher(for: WorkspaceUISmokeRunner.selectTabNotification)) {
                note in
                if let name = note.object as? String { tab = name }
            }
        #endif
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true)
        { result in
            if case let .success(urls) = result {
                context.addAttachments(urls)
            } else if case let .failure(error) = result {
                context.show(error)
            }
        }
        // AttachmentPasteMonitor is the single owner of ⌘V. Registering an
        // onPasteCommand here too can append the same clipboard image twice.
        .attachmentPasteCatcher { pasteboard in
            context.attachPasteboard(pasteboard)
        }
    }
}
