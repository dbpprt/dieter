import DieterAPI
import DieterCore
import Foundation
import Observation
import SharedCore

/// The selected conversation, as the shared core presents it: its live
/// window with this Mac's pending sends merged in, history paging, and read
/// state. The core owns the stream, retries, and the transcript cache.
@MainActor @Observable
final class ConversationModel {
    @ObservationIgnored var presentSnapshot: (Dieter_V1_ConversationSnapshot) -> Dieter_V1_ConversationSnapshot = { $0 }
    var selectedCardID: String?
    var selectedChatID: String?
    var conversation: Dieter_V1_ConversationSnapshot? {
        didSet {
            let invalidate =
                conversation?.conversation.taskPlans != oldValue?.conversation.taskPlans
                || conversation?.conversation.subagents != oldValue?.conversation.subagents
                || conversation?.conversation.queue != oldValue?.conversation.queue
            if invalidate || conversation?.conversation.messages != oldValue?.conversation.messages {
                refreshConversationPresentationState(invalidate: invalidate)
            }
        }
    }
    var olderConversationMessages: [Dieter_V1_UiMessage] = [] {
        didSet { if olderConversationMessages != oldValue { refreshConversationPresentationState() } }
    }
    var conversationMessages: [Dieter_V1_UiMessage] = []
    var conversationPresentationRevision = 0
    var conversationHistoryStart = 0
    var conversationHistoryTotal = 0
    var conversationHistoryHasMore = false
    var conversationHistoryLoading = false
    var browsingEarlierHistory = false {
        didSet { if browsingEarlierHistory != oldValue { refreshConversationPresentationState(invalidate: true) } }
    }
    var selectedDetail: Dieter_V1_CardDetail?
    var conversationSelectionGeneration: UInt64 = 0
    var conversationError: String?
    var conversationLoading = false
    var conversationSyncing = false
    var conversationLastRefreshedAt: Date?
    /// A message this Mac sent has not been answered yet.
    var awaitingReply = false
    /// A failed turn's retry was sent and has not run yet.
    var retrying = false
    /// The core's reading of the last turn's failure.
    var turnFailure: ClientTurnFailure?
    /// What the conversation shows besides its transcript: work, live
    /// activity, and what can be done next, as the core presents it.
    var state = ClientConversationState()
    @ObservationIgnored var core: CoreClient?
    /// Synthetic earlier history UI fixtures render ahead of the core's.
    @ObservationIgnored var fixtureHistory: [Dieter_V1_UiMessage] = []
    @ObservationIgnored var onAccepted: @MainActor (Dieter_V1_ConversationSnapshot, Bool) -> Void = { _, _ in }
    @ObservationIgnored var onContentPresentation: @MainActor (Dieter_V1_ContentPresentation, String) -> Void = {
        _, _ in
    }
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private(set) var observedCardID: String?
    @ObservationIgnored private var slice: ClientConversationSlice?
    @ObservationIgnored private var updates: UInt64 = 0
    @ObservationIgnored private var presentedContentIDs: Set<String> = []
    @ObservationIgnored private var presentedContentOrder: [String] = []

    /// Observes `cardID` through the core, which opens it on the machine that
    /// runs it; nil stops observing. Cached messages show at once.
    func observe(_ cardID: String?) {
        guard cardID != observedCardID else { return }
        subscription?.close()
        subscription = nil
        slice = nil
        fixtureHistory = []
        state = ClientConversationState()
        turnFailure = nil
        observedCardID = cardID
        guard let cardID, let core else { return }
        subscription = SliceSubscription(
            client: core, slice: .conversation, scope: cardID,
            onReset: { [weak self] in self?.slice = nil }
        ) { [weak self] update in
            self?.fold(update, cardID: cardID)
        }
    }

    private func fold(_ update: ClientUpdate, cardID: String) {
        guard observedCardID == cardID else { return }
        switch update.value {
        case .conversation(let value):
            slice = value
        case .conversationDelta(let delta):
            guard var value = slice else { return }
            value.card = delta.card
            value.conversation = delta.conversation
            value.messages = KeyedList.apply(
                value.messages, upserted: delta.upsertedMessages, removed: delta.removedMessageIds,
                order: delta.orderChanged ? delta.messageOrder : nil, key: \.id)
            value.loading = delta.loading
            value.syncing = delta.syncing
            value.error = delta.error
            value.pending = delta.pending
            value.hasEarlier_p = delta.hasEarlier_p
            value.loadingEarlier = delta.loadingEarlier
            value.browsingEarlier = delta.browsingEarlier
            value.awaitingReply = delta.awaitingReply
            value.retrying = delta.retrying
            value.refreshedAtMillis = delta.refreshedAtMillis
            if delta.hasTurnFailure { value.turnFailure = delta.turnFailure } else { value.clearTurnFailure() }
            value.project = delta.project
            value.board = delta.board
            value.page = delta.page
            if !delta.cardID.isEmpty { value.cardID = delta.cardID }
            value.daemonID = delta.daemonID
            value.earlierCount = delta.earlierCount
            value.state = delta.state
            slice = value
        case .failure(let failure):
            conversationError = failure.message
            conversationLoading = false
            return
        default:
            return
        }
        updates &+= 1
        if let slice { present(slice) }
    }

    private func present(_ slice: ClientConversationSlice) {
        // The core's messages are loaded history followed by the live window.
        let earlier = min(max(0, Int(slice.earlierCount)), slice.messages.count)
        var snapshot = Dieter_V1_ConversationSnapshot()
        snapshot.detail.card = slice.card
        snapshot.detail.project = slice.project
        snapshot.detail.board = slice.board
        snapshot.conversation = slice.conversation
        snapshot.conversation.messages = Array(slice.messages.dropFirst(earlier))
        snapshot.page = slice.page
        let hasContent = slice.hasCard || slice.hasConversation || !slice.messages.isEmpty
        let older = fixtureHistory + slice.messages.prefix(earlier)
        if olderConversationMessages != older { olderConversationMessages = older }
        if hasContent {
            let presented = presentSnapshot(snapshot)
            if conversation != presented { conversation = presented }
            if selectedDetail != snapshot.detail { selectedDetail = snapshot.detail }
        }
        if browsingEarlierHistory != slice.browsingEarlier { browsingEarlierHistory = slice.browsingEarlier }
        if conversationHistoryHasMore != slice.hasEarlier_p { conversationHistoryHasMore = slice.hasEarlier_p }
        if conversationHistoryLoading != slice.loadingEarlier { conversationHistoryLoading = slice.loadingEarlier }
        let total = max(Int(slice.page.total), slice.messages.count)
        if conversationHistoryTotal != total { conversationHistoryTotal = total }
        let start = slice.browsingEarlier ? conversationHistoryStart : max(0, Int(slice.page.start) - earlier)
        if conversationHistoryStart != start { conversationHistoryStart = start }
        let error = slice.error.isEmpty ? nil : slice.error
        if conversationError != error { conversationError = error }
        let loading = slice.loading && !hasContent
        if conversationLoading != loading { conversationLoading = loading }
        if conversationSyncing != slice.syncing { conversationSyncing = slice.syncing }
        let refreshed =
            slice.refreshedAtMillis > 0 ? Date(timeIntervalSince1970: Double(slice.refreshedAtMillis) / 1_000) : nil
        if conversationLastRefreshedAt != refreshed { conversationLastRefreshedAt = refreshed }
        if awaitingReply != slice.awaitingReply { awaitingReply = slice.awaitingReply }
        if retrying != slice.retrying { retrying = slice.retrying }
        let failure = slice.hasTurnFailure ? slice.turnFailure : nil
        if turnFailure != failure { turnFailure = failure }
        if state != slice.state { state = slice.state }
        if hasContent, slice.hasCard { onAccepted(snapshot, slice.card.scope == "chat" && slice.card.boardID.isEmpty) }
        presentContent(from: slice.conversation, daemonID: slice.daemonID)
    }

    func refreshConversationPresentationState(invalidate: Bool = false) {
        let live = conversation?.conversation.messages ?? []
        let liveIDs = Set(live.lazy.map(\.id).filter { !$0.isEmpty })
        var seen = Set<String>()
        let history = olderConversationMessages.filter { $0.id.isEmpty || !liveIDs.contains($0.id) }
        let next = (history + live).filter { $0.id.isEmpty || seen.insert($0.id).inserted }
        let messagesChanged = conversationMessages != next
        if messagesChanged { conversationMessages = next }
        if messagesChanged || invalidate { conversationPresentationRevision &+= 1 }
    }

    /// Shows a conversation this Mac holds locally (a creation still in the
    /// outbox, or a fixture) until the core presents the real one.
    func acceptConversation(_ snapshot: Dieter_V1_ConversationSnapshot, chat: Bool) {
        let presented = presentSnapshot(snapshot)
        if conversation != presented { conversation = presented }
        if selectedDetail != snapshot.detail { selectedDetail = snapshot.detail }
        conversationLoading = false
        conversationError = nil
        onAccepted(snapshot, chat)
    }

    /// Marks the visible reply as read; the core sends the receipt.
    func markResponseSeen() async {
        // Directory metadata can announce a reply before its transcript frame
        // arrives; only a reply actually shown counts as seen.
        guard let core, let card = conversation?.detail.card,
            card.id == (selectedCardID ?? selectedChatID),
            card.responseSeq > card.seenResponseSeq,
            (conversation?.conversation.lastSeq ?? 0) >= card.responseSeq,
            conversation?.conversation.messages.contains(where: { $0.id == card.responseMessageID }) == true,
            !browsingEarlierHistory
        else { return }
        _ = try? await core.dispatch { $0.markCardRead = .with { $0.cardID = card.id } }
    }

    @discardableResult
    func loadEarlierMessages() async -> Bool {
        guard !conversationHistoryLoading, conversationHistoryHasMore else { return false }
        return await page { command, cardID in command.loadEarlierMessages = .with { $0.cardID = cardID } }
    }

    @discardableResult
    func loadLaterMessages() async -> Bool {
        guard browsingEarlierHistory, !conversationHistoryLoading else { return false }
        return await page { command, cardID in command.loadLaterMessages = .with { $0.cardID = cardID } }
    }

    func returnToLatest() {
        guard let core, let cardID = observedCardID else { return }
        Task { _ = try? await core.dispatch { $0.returnToLatest = .with { $0.cardID = cardID } } }
    }

    /// Loads a page, then waits for the update that carries it, so the
    /// caller's render window can extend over the new messages.
    private func page(_ build: (inout ClientCommand, String) -> Void) async -> Bool {
        guard let core, let cardID = observedCardID else { return false }
        var command = ClientCommand()
        build(&command, cardID)
        let before = updates
        let count = conversationMessages.count
        do {
            let result = try await core.dispatch(command)
            guard result.pageLoaded.loaded, observedCardID == cardID else { return false }
            let deadline = ContinuousClock.now + .seconds(2)
            while observedCardID == cardID, updates == before || conversationMessages.count == count,
                ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(16))
            }
            return observedCardID == cardID
        } catch {
            guard observedCardID == cardID, !(error is CancellationError) else { return false }
            conversationError = (error as? CoreFailure)?.message ?? error.localizedDescription
            return false
        }
    }

    /// When the current turn started, as the core reads it.
    var turnStartedAt: Date? {
        state.turnStartedAtMillis > 0 ? Date(timeIntervalSince1970: Double(state.turnStartedAtMillis) / 1_000) : nil
    }

    func resetConversationHistory() {
        olderConversationMessages = []
        conversationHistoryStart = 0
        conversationHistoryTotal = 0
        conversationHistoryHasMore = false
        conversationHistoryLoading = false
        browsingEarlierHistory = false
    }

    private func presentContent(from value: Dieter_V1_Conversation, daemonID: String) {
        let presentation = value.presentedContent
        guard !presentation.id.isEmpty, let selectedID = selectedCardID ?? selectedChatID,
            value.cardID == selectedID || observedCardID == selectedID
        else { return }
        let key = [daemonID, selectedID, presentation.id].map { "\($0.utf8.count):\($0)" }.joined()
        guard presentedContentIDs.insert(key).inserted else { return }
        presentedContentOrder.append(key)
        if presentedContentOrder.count > 512 {
            presentedContentIDs.remove(presentedContentOrder.removeFirst())
        }
        onContentPresentation(presentation, selectedID)
    }
}
