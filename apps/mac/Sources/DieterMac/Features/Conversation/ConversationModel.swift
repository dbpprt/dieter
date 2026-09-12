import DieterAPI
import Foundation
import Observation

/// Owns one conversation read/watch/history lifecycle. Navigation and cache
/// persistence are effects supplied by the app composition boundary.
@MainActor @Observable
final class ConversationModel {
    @ObservationIgnored var presentSnapshot: (Dieter_V1_ConversationSnapshot) -> Dieter_V1_ConversationSnapshot = { $0 }
    var selectedCardID: String?
    var selectedChatID: String?
    var conversation: Dieter_V1_ConversationSnapshot? {
        didSet { if conversation != oldValue { refreshConversationPresentationState() } }
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
        didSet { if browsingEarlierHistory != oldValue { refreshConversationPresentationState() } }
    }
    var selectedDetail: Dieter_V1_CardDetail?
    var conversationSelectionGeneration: UInt64 = 0
    var conversationError: String?
    var conversationLoading = false
    var conversationSyncing = false
    var conversationLastRefreshedAt: Date?
    @ObservationIgnored let conversationRead = OwnedRead<Dieter_V1_ConversationSnapshot>()
    @ObservationIgnored var conversationTask: Task<Void, Never>?
    @ObservationIgnored var conversationHistoryRequestID: UUID?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var rpc: (any ConversationRPC)?
    @ObservationIgnored private var endpointID = ""
    @ObservationIgnored var onAccepted: @MainActor (Dieter_V1_ConversationSnapshot, Bool) -> Void = { _, _ in }
    @ObservationIgnored var onSnapshot: @MainActor (Dieter_V1_ConversationSnapshot, String, Date) async -> Void = {
        _, _, _ in
    }
    @ObservationIgnored var onTransportFailure: @MainActor (Error, any ConversationRPC) -> Void = { _, _ in }
    @ObservationIgnored var onContentPresentation: @MainActor (Dieter_V1_ContentPresentation, String) -> Void = {
        _, _ in
    }
    @ObservationIgnored private var presentedContentIDs: Set<String> = []
    @ObservationIgnored private var presentedContentOrder: [String] = []

    func bind(client: (any ConversationRPC)?, endpointID: String) {
        guard rpc !== client || self.endpointID != endpointID else { return }
        conversationRead.cancel(); conversationTask?.cancel(); conversationTask = nil
        retryTask?.cancel(); retryTask = nil
        conversationHistoryRequestID = nil; conversationHistoryLoading = false
        rpc = client; self.endpointID = endpointID
    }

    func refreshConversationPresentationState() {
        let live = browsingEarlierHistory ? [] : conversation?.conversation.messages ?? []
        let liveIDs = Set(live.lazy.map(\.id).filter { !$0.isEmpty })
        var seen = Set<String>()
        let history = olderConversationMessages.filter { $0.id.isEmpty || !liveIDs.contains($0.id) }
        let next = (history + live).filter { $0.id.isEmpty || seen.insert($0.id).inserted }
        if conversationMessages != next { conversationMessages = next }
        conversationPresentationRevision &+= 1
    }

    nonisolated static func isExpectedCancellation(_ error: Error) -> Bool { DieterRPCFailure.isCancellation(error) }

    func fetchConversation(
        cardID: String,
        chat: Bool,
        rpc: any ConversationRPC,
        cancellationRetries: Int = 0
    ) async {
        let selectionGeneration = conversationSelectionGeneration
        do {
            let snapshot = try await conversationRead.value(key: "\(ObjectIdentifier(rpc)):\(cardID)") {
                try await rpc.conversation(cardID: cardID, limit: conversationPageSize, before: nil)
            }
            guard self.rpc === rpc else { return }
            guard selectionGeneration == conversationSelectionGeneration, (selectedCardID ?? selectedChatID) == cardID
            else { return }
            await acceptConversation(snapshot, chat: chat)
            guard self.rpc === rpc, selectionGeneration == conversationSelectionGeneration,
                (selectedCardID ?? selectedChatID) == cardID
            else { return }
            let after = snapshot.conversation.lastSeq
            conversationTask = Task { [weak self] in
                do {
                    try await rpc.watchConversation(cardID: cardID, after: after) { [weak self] update in
                        await self?.applyConversationUpdate(
                            update, cardID: cardID, client: rpc, selectionGeneration: selectionGeneration)
                    }
                } catch  where Self.isExpectedCancellation(error) {} catch {
                    guard let self, self.rpc === rpc, selectionGeneration == self.conversationSelectionGeneration,
                        (self.selectedCardID ?? self.selectedChatID) == cardID
                    else { return }
                    self.conversationSyncing = false
                    if DieterRPCFailure.isTransient(error) {
                        self.onTransportFailure(error, rpc)
                    } else {
                        self.conversationError = "Conversation updates paused: \(DieterRPCFailure.message(for: error))"
                    }
                }
            }
        } catch {
            switch DieterConversationOpenFailurePolicy.disposition(
                for: error,
                selectionMatches: selectionGeneration == conversationSelectionGeneration && self.rpc === rpc
                    && (selectedCardID ?? selectedChatID) == cardID,
                cancellationRetries: cancellationRetries
            ) {
            case .ignore:
                return
            case .retry:
                retryTask?.cancel()
                retryTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, selectionGeneration == self.conversationSelectionGeneration,
                        (self.selectedCardID ?? self.selectedChatID) == cardID
                    else { return }
                    guard let currentRPC = self.rpc else {
                        self.conversationLoading = false
                        self.conversationSyncing = false
                        return
                    }
                    await self.fetchConversation(
                        cardID: cardID,
                        chat: chat,
                        rpc: currentRPC,
                        cancellationRetries: cancellationRetries + 1
                    )
                }
            case .report:
                conversationError = DieterRPCFailure.message(for: error)
                conversationLoading = false
                conversationSyncing = false
                if DieterRPCFailure.isTransient(error) {
                    onTransportFailure(error, rpc)
                } else {
                    conversationError = "Could not open this conversation: \(DieterRPCFailure.message(for: error))"
                }
            }
        }
    }

    func acceptConversation(
        _ snapshot: Dieter_V1_ConversationSnapshot,
        chat: Bool,
        refreshedAt: Date? = Date(),
        cache: Bool = true
    ) async {
        if conversation != snapshot {
            resetConversationHistory(from: snapshot)
            conversation = presentSnapshot(snapshot)
        }
        if selectedDetail != snapshot.detail { selectedDetail = snapshot.detail }
        conversationLoading = false
        conversationError = nil
        conversationSyncing = false
        conversationLastRefreshedAt = refreshedAt
        onAccepted(snapshot, chat)
        // Cached snapshots can belong to a connection that is still switching.
        // Only authoritative reads and watch updates may present workspace UI.
        if cache { presentContent(from: snapshot.conversation) }
        if cache, let refreshedAt { await onSnapshot(snapshot, endpointID, refreshedAt) }
    }

    @discardableResult
    func loadEarlierMessages() async -> Bool {
        guard !conversationHistoryLoading,
            conversationHistoryHasMore,
            conversationHistoryStart > 0,
            let cardID = selectedCardID ?? selectedChatID,
            let rpc
        else { return false }
        let before = conversationHistoryStart
        let requestID = UUID()
        conversationHistoryRequestID = requestID
        conversationHistoryLoading = true
        defer {
            if conversationHistoryRequestID == requestID {
                conversationHistoryRequestID = nil
                conversationHistoryLoading = false
            }
        }
        do {
            let page = try await rpc.conversation(
                cardID: cardID,
                limit: conversationPageSize,
                before: Int32(before)
            )
            guard self.rpc === rpc, conversationHistoryRequestID == requestID,
                (selectedCardID ?? selectedChatID) == cardID
            else { return false }
            let liveIDs = Set(conversation?.conversation.messages.map(\.id) ?? [])
            var seen = liveIDs
            let merged = (page.conversation.messages + olderConversationMessages).filter { message in
                message.id.isEmpty || seen.insert(message.id).inserted
            }
            let window = TranscriptRetention.window(merged, keepingEarlier: true)
            if window.removed > 0 { browsingEarlierHistory = true }
            olderConversationMessages = window.messages
            conversationHistoryStart = Int(page.page.start)
            conversationHistoryTotal = Int(page.page.total)
            conversationHistoryHasMore = page.page.hasMore_p
            return true
        } catch {
            guard self.rpc === rpc, conversationHistoryRequestID == requestID,
                (selectedCardID ?? selectedChatID) == cardID
            else { return false }
            if DieterRPCFailure.isTransient(error) {
                onTransportFailure(error, rpc)
            } else {
                conversationError = "Could not load earlier messages: \(error.localizedDescription)"
            }
            return false
        }
    }

    /// Advance through a detached retained window without joining it to a
    /// noncontiguous live tail. The same bounded history RPC serves both edges.
    @discardableResult
    func loadLaterMessages() async -> Bool {
        guard browsingEarlierHistory, !conversationHistoryLoading,
            let cardID = selectedCardID ?? selectedChatID, let rpc
        else { return false }
        let end = conversationHistoryStart + olderConversationMessages.count
        let total = max(conversationHistoryTotal, Int(conversation?.page.total ?? 0))
        guard end < total else {
            browsingEarlierHistory = false
            return false
        }
        let requestID = UUID()
        conversationHistoryRequestID = requestID
        conversationHistoryLoading = true
        defer {
            if conversationHistoryRequestID == requestID {
                conversationHistoryRequestID = nil
                conversationHistoryLoading = false
            }
        }
        do {
            let page = try await rpc.conversation(
                cardID: cardID, limit: conversationPageSize,
                before: Int32(min(total, end + Int(conversationPageSize))))
            guard self.rpc === rpc, conversationHistoryRequestID == requestID,
                (selectedCardID ?? selectedChatID) == cardID
            else { return false }
            let pageStart = Int(page.page.start)
            // A concurrently rewritten transcript must never leave an
            // invisible gap between retained and newly fetched messages.
            guard pageStart <= end else {
                conversationError = "Conversation history changed. Jump to latest to refresh it."
                return false
            }
            let pageEnd = pageStart + page.conversation.messages.count
            guard pageEnd > end else { return false }
            let liveStart = conversation.map { Int($0.page.start) } ?? total
            let reconnectsLive = pageEnd >= liveStart
            let liveIDs = reconnectsLive ? Set(conversation?.conversation.messages.map(\.id) ?? []) : []
            var seen = Set<String>()
            let merged = (olderConversationMessages + page.conversation.messages).filter { message in
                (message.id.isEmpty || !liveIDs.contains(message.id))
                    && (message.id.isEmpty || seen.insert(message.id).inserted)
            }
            let window = TranscriptRetention.window(merged, keepingEarlier: false)
            olderConversationMessages = window.messages
            conversationHistoryStart += window.removed
            conversationHistoryHasMore = conversationHistoryStart > 0
            conversationHistoryTotal = max(total, Int(page.page.total))
            if reconnectsLive { browsingEarlierHistory = false }
            return true
        } catch {
            guard self.rpc === rpc, conversationHistoryRequestID == requestID,
                (selectedCardID ?? selectedChatID) == cardID
            else { return false }
            if DieterRPCFailure.isTransient(error) {
                onTransportFailure(error, rpc)
            } else {
                conversationError = "Could not load later messages: \(error.localizedDescription)"
            }
            return false
        }
    }

    func resetConversationHistory(from snapshot: Dieter_V1_ConversationSnapshot? = nil) {
        conversationHistoryRequestID = nil
        browsingEarlierHistory = false
        olderConversationMessages = []
        conversationHistoryStart = Int(snapshot?.page.start ?? 0)
        conversationHistoryTotal = Int(snapshot?.page.total ?? 0)
        conversationHistoryHasMore = snapshot?.page.hasMore_p ?? false
        conversationHistoryLoading = false
    }

    func applyConversationUpdate(
        _ update: Dieter_V1_ConversationUpdate, cardID: String,
        client: (any ConversationRPC)? = nil, selectionGeneration: UInt64? = nil
    ) async {
        if let client, rpc !== client { return }
        if let selectionGeneration, selectionGeneration != conversationSelectionGeneration { return }
        guard (selectedCardID ?? selectedChatID) == cardID else { return }
        apply(update)
        conversationSyncing = false
        if let conversation {
            await onSnapshot(conversation, endpointID, Date())
        }
    }

    // Splits the client's contiguous transcript at the first message the
    // replacement window still contains; nil when the windows are disjoint.
    nonisolated static func retainedHistoryPrefix(
        current: [Dieter_V1_UiMessage],
        replacementIDs: Set<String>
    ) -> [Dieter_V1_UiMessage]? {
        guard let overlap = current.firstIndex(where: { !$0.id.isEmpty && replacementIDs.contains($0.id) }) else {
            return nil
        }
        return current[..<overlap].filter { !$0.id.isEmpty }
    }

    func apply(_ update: Dieter_V1_ConversationUpdate) {
        if update.hasSnapshot {
            // The replacement snapshot only carries the server's bounded
            // window. Messages the client already has that precede the new
            // window slide into local history so the transcript never loses
            // content; with no overlap the retained prefix would leave an
            // unfillable gap, so history resets to the new page instead.
            let replacementIDs = Set(update.snapshot.conversation.messages.lazy.map(\.id).filter { !$0.isEmpty })
            if !browsingEarlierHistory,
                let retained = Self.retainedHistoryPrefix(current: conversationMessages, replacementIDs: replacementIDs)
            {
                olderConversationMessages = retained
            } else if !browsingEarlierHistory {
                olderConversationMessages = []
            }
            trimStreamingHistory()
            conversation = presentSnapshot(update.snapshot)
            selectedDetail = update.snapshot.detail
            if olderConversationMessages.isEmpty {
                conversationHistoryStart = Int(update.snapshot.page.start)
                conversationHistoryHasMore = update.snapshot.page.hasMore_p
            }
            conversationHistoryTotal = max(conversationHistoryTotal, Int(update.snapshot.page.total))
            presentContent(from: update.snapshot.conversation)
            return
        }
        guard var snapshot = conversation else { return }
        var value = snapshot.conversation
        let removedIDs = Set(update.removedMessageIds)
        // Removed ids are almost always the window sliding forward during a
        // streaming turn, not deletions; keep those messages as history so
        // they don't vanish from the visible transcript.
        if !browsingEarlierHistory, !removedIDs.isEmpty {
            let known = Set(olderConversationMessages.lazy.map(\.id))
            let slidOut = value.messages.filter { removedIDs.contains($0.id) && !known.contains($0.id) }
            olderConversationMessages.append(contentsOf: slidOut)
            trimStreamingHistory()
        }
        var messages = value.messages.filter { !removedIDs.contains($0.id) }
        for changed in update.changedMessages {
            if let index = messages.firstIndex(where: { $0.id == changed.id }) {
                messages[index] = changed
            } else {
                messages.append(changed)
            }
        }
        value.messages = messages
        if !update.status.isEmpty { value.status = update.status }
        value.pendingTools = update.pendingTools; value.queue = update.queue
        value.draftAttachments = update.draftAttachments
        value.lastSeq = update.lastSeq; value.updatedAt = update.updatedAt
        value.subagents = update.subagents; value.taskPlans = update.taskPlans
        if update.hasPresentedContent { value.presentedContent = update.presentedContent }
        snapshot.conversation = value
        if update.hasDetail { snapshot.detail = update.detail; selectedDetail = update.detail }
        if update.hasPage {
            snapshot.page = update.page
            if olderConversationMessages.isEmpty {
                conversationHistoryStart = Int(update.page.start)
                conversationHistoryHasMore = update.page.hasMore_p
            }
            conversationHistoryTotal = max(conversationHistoryTotal, Int(update.page.total))
        }
        conversation = presentSnapshot(snapshot)
        presentContent(from: value)
    }

    private func presentContent(from value: Dieter_V1_Conversation) {
        let presentation = value.presentedContent
        guard !endpointID.isEmpty, !presentation.id.isEmpty,
            let selectedID = selectedCardID ?? selectedChatID, value.cardID == selectedID
        else { return }
        let key = [endpointID, selectedID, presentation.id].map { "\($0.utf8.count):\($0)" }.joined()
        guard presentedContentIDs.insert(key).inserted else { return }
        presentedContentOrder.append(key)
        if presentedContentOrder.count > 512 {
            presentedContentIDs.remove(presentedContentOrder.removeFirst())
        }
        onContentPresentation(presentation, selectedID)
    }

    func returnToLatest() {
        resetConversationHistory(from: conversation)
    }

    private func trimStreamingHistory() {
        guard !browsingEarlierHistory, !olderConversationMessages.isEmpty else { return }
        let window = TranscriptRetention.window(olderConversationMessages, keepingEarlier: false)
        guard window.removed > 0 else { return }
        olderConversationMessages = window.messages
        conversationHistoryStart += window.removed
        conversationHistoryHasMore = true
    }

}
