import AppKit
import DieterAPI
import Foundation
import Observation

/// The conversation surface receives only its feature models and explicit app
/// commands. It cannot access connections, replication internals or other routes.
@MainActor @Observable
final class ConversationContext {
    let model: ConversationModel
    let composer: ComposerModel
    let worktreeChanges: WorktreeChangesModel
    @ObservationIgnored var card: () -> Dieter_V1_Card?
    @ObservationIgnored var catalog: () -> Dieter_V1_HarnessCatalog
    @ObservationIgnored var projectID: () -> String
    @ObservationIgnored var reasoning: () -> Bool
    @ObservationIgnored var pendingMessage: (String) -> Bool
    @ObservationIgnored var acceptedItem: (String) -> Bool
    @ObservationIgnored var failedItem: (String) -> Bool
    @ObservationIgnored var creationError: (String) -> String?

    init(
        model: ConversationModel, composer: ComposerModel, worktreeChanges: WorktreeChangesModel,
        card: @escaping () -> Dieter_V1_Card?, catalog: @escaping () -> Dieter_V1_HarnessCatalog,
        projectID: @escaping () -> String, reasoning: @escaping () -> Bool,
        pendingMessage: @escaping (String) -> Bool, acceptedItem: @escaping (String) -> Bool,
        failedItem: @escaping (String) -> Bool, creationError: @escaping (String) -> String?
    ) {
        self.model = model; self.composer = composer; self.worktreeChanges = worktreeChanges
        self.card = card; self.catalog = catalog; self.projectID = projectID; self.reasoning = reasoning
        self.pendingMessage = pendingMessage; self.acceptedItem = acceptedItem; self.failedItem = failedItem;
        self.creationError = creationError
    }
    var selectedCard: Dieter_V1_Card? { card() }
    var selectedProjectID: String { projectID() }
    var harnessCatalog: Dieter_V1_HarnessCatalog { catalog() }
    var showReasoning: Bool { reasoning() }
    var workspaceToast: WorkspaceToast? { worktreeChanges.workspaceToast }
    func isPendingMessage(_ id: String) -> Bool { pendingMessage(id) }
    func isAcceptedOutboxItem(_ id: String) -> Bool { acceptedItem(id) }
    func isFailedOutboxItem(_ id: String) -> Bool { failedItem(id) }
    func failedCreationError(_ id: String) -> String? { creationError(id) }
    var conversation: Dieter_V1_ConversationSnapshot? { model.conversation }
    var conversationError: String? { model.conversationError }
    var conversationHistoryHasMore: Bool { model.conversationHistoryHasMore }
    var conversationHistoryLoading: Bool { model.conversationHistoryLoading }
    var conversationHistoryTotal: Int { model.conversationHistoryTotal }
    var conversationLastRefreshedAt: Date? { model.conversationLastRefreshedAt }
    var conversationLoading: Bool { model.conversationLoading }
    var conversationMessages: [Dieter_V1_UiMessage] { model.conversationMessages }
    var liveActivityMessages: [Dieter_V1_UiMessage] {
        guard let conversation = conversation?.conversation else { return [] }
        let queuedIDs = Set(conversation.queue.map(\.id))
        // The displayed snapshot can contain local outbox overlays, even while
        // browsing earlier history. Those sends have not started a turn yet.
        return conversation.messages.filter {
            !queuedIDs.contains($0.id) && !isPendingMessage($0.id) && !isFailedOutboxItem($0.id)
        }
    }
    var conversationPresentationRevision: Int { model.conversationPresentationRevision }
    var conversationSyncing: Bool { model.conversationSyncing }
    var selectedCardID: String? { model.selectedCardID }
    var selectedChatID: String? { model.selectedChatID }
    var selectedDetail: Dieter_V1_CardDetail? { model.selectedDetail }
    var composerProviderLocked: Bool {
        let card = selectedCard ?? selectedDetail?.card
        return card?.initialPromptSentAt.isEmpty == false || !conversationMessages.isEmpty
            || ConversationActivityPresentation.isActive(
                conversationStatus: conversation?.conversation.status ?? "", cardRuntime: card?.runtime ?? "")
    }
    func canChangeComposerSelection(_ capability: String) -> Bool {
        ConversationSelectionPolicy.canChange(
            capability, harness: harnessCatalog.harnesses.first { $0.id == composerProvider },
            conversationLocked: composerProviderLocked)
    }
    func selectComposerModel(_ value: Dieter_V1_HarnessModel) {
        composer.draft.selectModel(
            value, harness: harnessCatalog.harnesses.first { $0.id == composerProvider },
            allowsEffortChange: canChangeComposerSelection("effort-selection"))
    }
    var commentText: String {
        get { composer.draft.comment }
        set { composer.draft.comment = newValue }
    }
    var composerText: String {
        get { composer.draft.text }
        set { composer.draft.text = newValue }
    }
    var composerAttachments: [Dieter_V1_MessagePart] {
        get { composer.draft.attachments }
        set { composer.draft.attachments = newValue }
    }
    var composerEffort: String {
        get { composer.draft.effort }
        set { composer.draft.effort = newValue }
    }
    var composerModel: String {
        get { composer.draft.model }
        set { composer.draft.model = newValue }
    }
    var composerProvider: String {
        get { composer.draft.provider }
        set { composer.draft.provider = newValue }
    }
    var composerProviderOptions: [String: String] {
        get { composer.draft.providerOptions }
        set { composer.draft.providerOptions = newValue }
    }
    @ObservationIgnored var onAddAttachments: ([URL]) -> Void = { _ in }
    func addAttachments(_ urls: [URL]) { onAddAttachments(urls) }
    @ObservationIgnored var onAddComment: () async -> Void = {}
    func addComment() async { await onAddComment() }
    @ObservationIgnored var onAddPastedAttachments: ([NSItemProvider]) -> Void = { _ in }
    func addPastedAttachments(_ providers: [NSItemProvider]) { onAddPastedAttachments(providers) }
    @ObservationIgnored var onArchive: (Dieter_V1_Card, Bool) async -> Void = { _, _ in }
    func archive(_ card: Dieter_V1_Card, archived: Bool) async { await onArchive(card, archived) }
    @ObservationIgnored var onAttachPasteboard: (NSPasteboard) -> Bool = { _ in false }
    func attachPasteboard(_ pasteboard: NSPasteboard) -> Bool { onAttachPasteboard(pasteboard) }
    @ObservationIgnored var onStart: (Dieter_V1_Card) async -> Void = { _ in }
    func start(_ card: Dieter_V1_Card) async { await onStart(card) }
    @ObservationIgnored var onCancel: (Dieter_V1_Card) async -> Void = { _ in }
    func cancel(_ card: Dieter_V1_Card) async { await onCancel(card) }
    @ObservationIgnored var onCloseConversation: () -> Void = {}
    func closeConversation() { onCloseConversation() }
    @ObservationIgnored var onDiscardOutboxItem: (String) async -> Void = { _ in }
    func discardOutboxItem(_ id: String) async { await onDiscardOutboxItem(id) }
    @ObservationIgnored var onFork: (Dieter_V1_Card) async -> Void = { _ in }
    func fork(_ card: Dieter_V1_Card) async { await onFork(card) }
    @ObservationIgnored var onLoadEarlierMessages: () async -> Bool = { false }
    func loadEarlierMessages() async -> Bool { await onLoadEarlierMessages() }
    @ObservationIgnored var onOpenConversation: (String, Bool) async -> Void = { _, _ in }
    func openConversation(cardID: String, chat: Bool) async { await onOpenConversation(cardID, chat) }
    @ObservationIgnored var onOpenProjectChanges: (String) async -> Void = { _ in }
    func openProjectChanges(_ id: String) async { await onOpenProjectChanges(id) }
    @ObservationIgnored var onOpenWorkspaceFiles: (Dieter_V1_Card) async -> Void = { _ in }
    func openWorkspaceFiles(card: Dieter_V1_Card) async { await onOpenWorkspaceFiles(card) }
    @ObservationIgnored var onOpenWorkspaceTerminal: (Dieter_V1_Card) async -> Void = { _ in }
    func openWorkspaceTerminal(card: Dieter_V1_Card) async { await onOpenWorkspaceTerminal(card) }
    @ObservationIgnored var onPin: (Dieter_V1_Card, Bool) async -> Void = { _, _ in }
    func pin(_ card: Dieter_V1_Card, pinned: Bool) async { await onPin(card, pinned) }
    @ObservationIgnored var onRetryFailedTurn: (ConversationTurnFailure) async -> Bool = { _ in false }
    func retryFailedTurn(_ failure: ConversationTurnFailure) async -> Bool { await onRetryFailedTurn(failure) }
    @ObservationIgnored var onRetryOutboxItem: (String) async -> Void = { _ in }
    func retryOutboxItem(_ id: String) async { await onRetryOutboxItem(id) }
    @ObservationIgnored var onRemoveQueuedMessage: (Dieter_V1_QueuedMessage, Bool) async -> Bool = { _, _ in false }
    func removeQueuedMessage(_ message: Dieter_V1_QueuedMessage, edit: Bool) async -> Bool {
        await onRemoveQueuedMessage(message, edit)
    }
    @ObservationIgnored var onSendComposer: () async -> Void = {}
    func sendComposer() async { await onSendComposer() }
    @ObservationIgnored var onShow: (Error) -> Void = { _ in }
    func show(_ error: Error) { onShow(error) }
    @ObservationIgnored var onToolOutput: (String, String, String) async throws -> Dieter_V1_ToolOutput? = { _, _, _ in
        nil
    }
    func toolOutput(messageID: String, toolCallID: String, revision: String) async throws -> Dieter_V1_ToolOutput? {
        try await onToolOutput(messageID, toolCallID, revision)
    }
}
