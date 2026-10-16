import SwiftUI
import UniformTypeIdentifiers

enum ComposerReturnPolicy {
    static func sendsMessage(shiftPressed: Bool) -> Bool { !shiftPressed }
}

enum ConversationSurfaceStyle: Equatable {
    case canvas
    case inherited
}

struct ConversationView: View {
    @Environment(ConversationContext.self) private var context
    var compact = false
    var surfaceStyle: ConversationSurfaceStyle = .canvas
    var kanbanPresented = false
    var toggleKanban: (() -> Void)?
    @State private var links = ConversationLinkHandlers()

    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }

    /// A standalone chat, as the core reads the conversation.
    private var standalone: Bool { context.model.chrome.chat }

    @ViewBuilder var body: some View {
        @Bindable var content = context.content
        let id = conversationID
        let endpointID = content.currentEndpointID(id)
        // Read presentation fields directly in this observation scope. The
        // representable must update in the same transaction that changes
        // `isOpen`, otherwise its native workspace item remains visible.
        let workspacePresented =
            content.splitMode && content.isOpen && content.conversationID == id
            && content.endpointID == (endpointID ?? "")
        let singleWorkspace =
            !content.splitMode && content.isOpen && content.conversationID == id
            && content.endpointID == (endpointID ?? "")
            && content.conversationTab == "Conversation" && content.selectedTabID != nil
        let handlers = links.handlers(conversationID: id, endpointID: endpointID, content: context.content)
        Group {
            if compact || standalone {
                ConversationPaneOwnedSplit(presented: workspacePresented, singleWorkspace: singleWorkspace) {
                    ConversationPaneSurfaceBar(
                        model: context.content,
                        workspacePresented: workspacePresented,
                        kanbanPresented: kanbanPresented,
                        toggleKanban: toggleKanban ?? {},
                        showsKanban: toggleKanban != nil && (!workspacePresented || !kanbanPresented)
                    )
                    .environment(context)
                } chat: {
                    ConversationChatColumn(workspacePresented: workspacePresented, surfaceStyle: surfaceStyle)
                } workspaceBar: {
                    ConversationPaneWorkspaceBar(
                        model: context.content, kanbanPresented: kanbanPresented,
                        toggleKanban: toggleKanban ?? {},
                        showsKanban: toggleKanban != nil
                    )
                    .environment(context)
                } content: {
                    ConversationContentPane(model: context.content)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConversationContentSplit(presented: workspacePresented, singleWorkspace: singleWorkspace) {
                    VStack(spacing: 0) {
                        ConversationPanelHeader(
                            model: context.content, role: workspacePresented ? .chatBesideWorkspace : .unified
                        )
                        .padding(.horizontal, ConversationPaneTitlebar<EmptyView>.horizontalInset)
                        ConversationChatColumn(workspacePresented: workspacePresented, surfaceStyle: surfaceStyle)
                    }
                } content: {
                    ConversationContentPane(model: context.content)
                }
            }
        }
        // The same values while the conversation and its machine stay the
        // same: every message's text view reads them.
        .environment(\.conversationLinkExternalResolver, stable: handlers.resolveExternal)
        .environment(\.conversationLinkHandler, stable: handlers.open)
        .onChange(of: conversationID) { _, id in
            if context.content.conversationID != id { context.content.suspend() } else { context.content.resume() }
        }
        .onAppear {
            if context.content.isPresented(for: conversationID) { context.content.resume() }
        }
        .onDisappear { context.content.suspend() }
    }
}

/// The transcript with its composer. Its own view, so what only it shows
/// (loading, errors, the selected surface, toasts) never re-evaluates the
/// split around it.
private struct ConversationChatColumn: View {
    @Environment(ConversationContext.self) private var context
    let workspacePresented: Bool
    let surfaceStyle: ConversationSurfaceStyle
    @State private var fileImportRequest: ConversationFileImportRequest?

    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }

    /// A standalone chat, as the core reads the conversation.
    private var standalone: Bool { context.model.chrome.chat }

    var body: some View {
        @Bindable var content = context.content
        let tab = content.conversationTab
        VStack(spacing: 0) {
            Group {
                if context.conversationLoading {
                    ConversationLoadingView(standalone: standalone)
                } else if let error = context.conversationError, context.conversation == nil {
                    LoadFeedback(
                        title: "Conversation", error: error,
                        retry: {
                            guard let id = context.selectedCardID ?? context.selectedChatID else { return }
                            Task { await context.openConversation(cardID: id, chat: standalone) }
                        })
                } else if !workspacePresented, tab == "Subagents" {
                    SubagentsView(background: .clear)
                } else if !workspacePresented, tab == "Changes" {
                    let card = context.shownCard
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
                if workspacePresented || tab == "Conversation" {
                    // Let the transcript scroll behind the glass while its
                    // bottom anchor stays above the composer's measured height.
                    VStack(spacing: 0) {
                        ConversationStartCardSlot()
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
        .onChange(of: context.selectedCardID) { _, _ in content.conversationTab = "Conversation" }
        .onChange(of: context.selectedChatID) { _, _ in content.conversationTab = "Conversation" }
        .onChange(of: workspacePresented) { wasPresented, presented in
            if wasPresented, !presented { content.conversationTab = "Conversation" }
        }
        .onChange(of: conversationID) { _, _ in fileImportRequest = nil }
        .onChange(of: tab) { _, _ in fileImportRequest = nil }
        .onDisappear { fileImportRequest = nil }
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

/// Offers to run a card's saved task above the composer.
private struct ConversationStartCardSlot: View {
    @Environment(ConversationContext.self) private var context

    var body: some View {
        let chrome = context.model.chrome
        // A Start is in flight, from this device or still in the outbox.
        if chrome.canStart || chrome.starting, let card = context.shownCard {
            ConversationStartCardBanner(card: card, starting: chrome.starting)
        }
    }
}

/// The transcript's link handlers for one conversation on one machine. Every
/// message's text view reads them from the environment, so they are rebuilt
/// only when the conversation or its machine changes; a closure built in a
/// view body is a new value on every evaluation and would update them all.
@MainActor final class ConversationLinkHandlers {
    private struct Key: Equatable {
        let conversationID: String
        let endpointID: String?
    }

    private var key: Key?
    private var open = StableEnvironmentValue<ConversationLinkHandler?>(nil)
    private var resolveExternal = StableEnvironmentValue<ConversationLinkExternalResolver?>(nil)

    func handlers(
        conversationID id: String, endpointID: String?, content: ConversationContentModel
    ) -> (
        open: StableEnvironmentValue<ConversationLinkHandler?>,
        resolveExternal: StableEnvironmentValue<ConversationLinkExternalResolver?>
    ) {
        let next = Key(conversationID: id, endpointID: endpointID)
        if key != next {
            key = next
            let handler: ConversationLinkHandler = { url in
                guard !id.isEmpty, content.currentEndpointID(id) == endpointID else { return false }
                content.requestOpen(url, conversationID: id)
                return true
            }
            let resolver: ConversationLinkExternalResolver = { url in
                guard !id.isEmpty, content.currentEndpointID(id) == endpointID else {
                    return .unavailable("This conversation's machine is no longer selected.")
                }
                return await content.resolveExternalLink(url, id)
            }
            open = StableEnvironmentValue<ConversationLinkHandler?>(handler)
            resolveExternal = StableEnvironmentValue<ConversationLinkExternalResolver?>(resolver)
        }
        return (open, resolveExternal)
    }
}

/// An environment value SwiftUI receives unchanged on every evaluation.
@MainActor final class StableEnvironmentValue<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension View {
    /// Writes `stable`'s value. Passed through generically, a closure keeps its
    /// identity, so views reading it update only when `stable` is replaced.
    @MainActor func environment<Value>(
        _ keyPath: WritableKeyPath<EnvironmentValues, Value>, stable: StableEnvironmentValue<Value>
    ) -> some View {
        environment(keyPath, stable.value)
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
