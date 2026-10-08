import CryptoKit
import DieterAPI
import DieterShared
import Foundation
import Observation
import SharedCore

/// The selected conversation, as the shared core presents it: its live
/// window with this Mac's pending sends merged in, history paging, and read
/// state. The core owns the stream, retries, and the transcript cache.
@MainActor @Observable
final class ConversationModel {
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
    /// Every loaded message by its timeline key.
    private(set) var messages = ConversationMessages()
    /// The transcript's rows, as the core groups every loaded message.
    private(set) var timeline: [ClientTimelineItem] = [] {
        didSet { if timeline != oldValue, !presenting { conversationPresentationRevision &+= 1 } }
    }
    /// Task plans of messages that are not loaded, shown after the transcript.
    private(set) var unattachedPlanIDs: [String] = []
    var conversationPresentationRevision = 0
    #if DIETER_UI_SMOKE
        /// Agent pickers a UI fixture shows over a catalog the core does not know.
        var agentFixture: ClientAgentControlsState?
    #endif
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
    /// A failed turn's retry was sent and has not run yet.
    var retrying = false
    /// The core's reading of the last turn's failure.
    var turnFailure: ClientTurnFailure?
    /// What the conversation shows besides its transcript: work, live
    /// activity, and what can be done next, as the core presents it.
    var state = ClientConversationState()
    @ObservationIgnored var core: CoreClient?
    /// Synthetic earlier history UI fixtures render ahead of the core's.
    @ObservationIgnored var fixtureHistory: [Dieter_V1_UiMessage] = [] {
        didSet { if fixtureHistory != oldValue, let slice { present(slice) } }
    }
    @ObservationIgnored var onAccepted: @MainActor (Dieter_V1_ConversationSnapshot, Bool) -> Void = { _, _ in }
    @ObservationIgnored var onContentPresentation: @MainActor (Dieter_V1_ContentPresentation, String) -> Void = {
        _, _ in
    }
    #if DIETER_UI_SMOKE
        /// Whether a UI fixture's conversation shows reasoning traces; the
        /// core regroups every real conversation itself.
        @ObservationIgnored var fixtureShowsReasoning = false {
            didSet {
                if fixtureShowsReasoning != oldValue { refreshConversationPresentationState(invalidate: true) }
            }
        }
    #endif
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private(set) var observedCardID: String?
    @ObservationIgnored private var slice: ClientConversationSlice?
    @ObservationIgnored private var updates: UInt64 = 0
    @ObservationIgnored private var presentedContentIDs: Set<String> = []
    @ObservationIgnored private let presentationDefaults: UserDefaults?

    init(presentationDefaults: UserDefaults? = nil) {
        self.presentationDefaults = presentationDefaults
    }
    /// A slice is being presented; otherwise a UI fixture set the conversation.
    @ObservationIgnored private var presenting = false

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
            guard let value = slice else { return }
            slice = value.applying(delta)
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
        presenting = true
        defer { presenting = false }
        let revision = conversationPresentationRevision
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
            if conversation != snapshot { conversation = snapshot }
            if selectedDetail != snapshot.detail { selectedDetail = snapshot.detail }
        }
        if browsingEarlierHistory != slice.browsingEarlier { browsingEarlierHistory = slice.browsingEarlier }
        if conversationHistoryHasMore != slice.hasEarlier_p { conversationHistoryHasMore = slice.hasEarlier_p }
        if conversationHistoryLoading != slice.loadingEarlier { conversationHistoryLoading = slice.loadingEarlier }
        let total = max(Int(slice.page.total), slice.messages.count)
        if conversationHistoryTotal != total { conversationHistoryTotal = total }
        var rows = slice.timeline
        #if DIETER_UI_SMOKE
            // A UI fixture's earlier history has no core rows; lay it out by the core's rules.
            if !fixtureHistory.isEmpty {
                rows = ConversationTimelineFixture.rows(fixtureHistory, showReasoning: slice.state.showReasoning) + rows
            }
        #endif
        if timeline != rows {
            timeline = rows
            // One slice is one presentation change, whether its messages, its rows, or both changed.
            if conversationPresentationRevision == revision { conversationPresentationRevision &+= 1 }
        }
        if unattachedPlanIDs != slice.unattachedPlanIds { unattachedPlanIDs = slice.unattachedPlanIds }
        let error = slice.error.isEmpty ? nil : slice.error
        if conversationError != error { conversationError = error }
        let loading = slice.loading && !hasContent
        if conversationLoading != loading { conversationLoading = loading }
        if conversationSyncing != slice.syncing { conversationSyncing = slice.syncing }
        let refreshed =
            slice.refreshedAtMillis > 0 ? Date(timeIntervalSince1970: Double(slice.refreshedAtMillis) / 1_000) : nil
        if conversationLastRefreshedAt != refreshed { conversationLastRefreshedAt = refreshed }
        if retrying != slice.retrying { retrying = slice.retrying }
        let failure = slice.hasTurnFailure ? slice.turnFailure : nil
        if turnFailure != failure { turnFailure = failure }
        if state != slice.state { state = slice.state }
        if hasContent, slice.hasCard { onAccepted(snapshot, slice.state.chat) }
        presentContent(from: slice.conversation, daemonID: slice.daemonID)
    }

    /// Loaded history followed by the live window, as the core lists them.
    func refreshConversationPresentationState(invalidate: Bool = false) {
        let next = olderConversationMessages + (conversation?.conversation.messages ?? [])
        let messagesChanged = conversationMessages != next
        if messagesChanged {
            conversationMessages = next
            messages = ConversationMessages(next)
        }
        #if DIETER_UI_SMOKE
            // A conversation a UI fixture installed has no core rows or state.
            if !presenting, subscription == nil {
                if messagesChanged || invalidate {
                    let queued = Set((conversation?.conversation.queue ?? []).map(\.id))
                    timeline = ConversationTimelineFixture.rows(
                        next, queued: queued, showReasoning: fixtureShowsReasoning)
                }
                state.showReasoning = fixtureShowsReasoning
                if let card = conversation?.detail.card {
                    state.chat = SharedRules.shared.isChat(scope: card.scope, boardId: card.boardID)
                    state.runtime =
                        conversation?.conversation.status.isEmpty == false
                        ? conversation?.conversation.status ?? "" : card.runtime
                }
            }
        #endif
        if messagesChanged || invalidate { conversationPresentationRevision &+= 1 }
    }

    /// The task plans a row shows, at their latest revision.
    func taskPlans(ids: [String]) -> [Dieter_V1_TaskPlan] {
        conversation?.conversation.taskPlans(ids: ids) ?? []
    }

    /// The delegated agents a row shows, in the row's order.
    func subagents(ids: [String]) -> [Dieter_V1_Subagent] {
        conversation?.conversation.subagents(ids: ids) ?? []
    }

    /// The message a timeline step renders, by the step's key.
    func message(for step: ClientTimelineStep) -> Dieter_V1_UiMessage? { messages.message(for: step) }

    /// The part a timeline step renders: its message's part, with coalesced prose as its text.
    func part(for step: ClientTimelineStep) -> Dieter_V1_MessagePart? { messages.part(for: step) }

    /// The latest reply is in view: the core marks it read once it is loaded
    /// and shown at the latest position.
    func markResponseSeen() async {
        guard let core, let cardID = selectedCardID ?? selectedChatID, cardID == observedCardID else { return }
        _ = try? await core.dispatch { $0.setVisibleConversation = .with { $0.cardID = cardID } }
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
            return try await ConversationPaging.load(
                command, core: core, current: { observedCardID == cardID },
                arrived: { updates != before && conversationMessages.count != count })
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
        conversationHistoryTotal = 0
        conversationHistoryHasMore = false
        conversationHistoryLoading = false
        browsingEarlierHistory = false
    }

    private func presentContent(from value: Dieter_V1_Conversation, daemonID: String) {
        let presentation = value.presentedContent
        guard !daemonID.isEmpty, !presentation.id.isEmpty, let selectedID = selectedCardID ?? selectedChatID,
            value.cardID == selectedID || observedCardID == selectedID
        else { return }
        let key = [daemonID, selectedID, presentation.id].map { "\($0.utf8.count):\($0)" }.joined()
        // This is a local UI effect receipt, not conversation state. Retain it
        // across navigation and app launches; evicting a receipt replays the
        // daemon's retained request the next time its chat is opened.
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let receipt = "conversation.presentedContent.\(digest)"
        if let presentationDefaults {
            guard !presentationDefaults.bool(forKey: receipt) else { return }
            presentationDefaults.set(true, forKey: receipt)
        } else {
            guard presentedContentIDs.insert(key).inserted else { return }
        }
        onContentPresentation(presentation, selectedID)
    }
}
