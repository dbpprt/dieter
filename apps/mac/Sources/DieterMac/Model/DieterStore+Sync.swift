import AppKit
import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func restorePersistentSync() async {
        do { try await outbox.restore() } catch {
            errorMessage = "Could not recover pending messages: \(error.localizedDescription)"
            return
        }
        var restored = await syncPersistence.load()
        restored.outbox = []
        syncDiskState = restored
        let activePrefix = activeGateway.credentialID + "#"
        let deploymentProjections = restored.projections
            .filter { $0.key.hasPrefix(activePrefix) }
            .sorted { $0.key < $1.key }
        lastSyncedAt =
            restored.projections[endpoint.id]?.refreshedAt
            ?? deploymentProjections.compactMap(\.value.refreshedAt).max()
        for (endpointID, projection) in deploymentProjections {
            if let snapshot = await snapshotDecoder.snapshot(
                endpointID: endpointID, data: projection.snapshot)
            {
                applyGlobalSnapshot(snapshot, endpointID: endpointID)
            }
        }
        if deploymentProjections.isEmpty,
            let snapshot = await snapshotDecoder.snapshot(
                endpointID: endpoint.id, data: restored.snapshot)
        {
            applyGlobalSnapshot(snapshot, endpointID: endpoint.id)
        }
        rebuildOutboxOverlays()
    }

    func activateSyncProjection(
        for endpoint: DieterEndpoint, decodedSnapshot: Dieter_V1_GlobalSnapshot?, decodedData: Data?
    ) {
        if let persisted = syncDiskState.projections[endpoint.id] {
            syncProjection = persisted
        } else {
            syncProjection = DieterSyncProjection(
                cursor: syncDiskState.cursor, snapshot: syncDiskState.snapshot)
            syncDiskState.projections[endpoint.id] = syncProjection
            syncDiskState.cursor = nil
            syncDiskState.snapshot = nil
        }
        // Metadata refresh may replace this endpoint while decoding is suspended.
        // Never pair that newer cursor with a snapshot decoded from older bytes.
        let matchingSnapshot = syncProjection.snapshot == decodedData ? decodedSnapshot : nil
        syncSnapshot = matchingSnapshot.map { snapshot in
            var next = snapshot
            next.schedules = []
            next.scheduleRuns = []
            return next
        }
        lastSyncedAt = syncProjection.refreshedAt
        if lastSyncPersistenceAt[endpoint.id] == nil {
            lastSyncPersistenceAt[endpoint.id] = syncProjection.refreshedAt
        }
        if let daemonID = endpoint.daemonID {
            let endpointID = endpoint.id
            Task {
                do {
                    try await outbox.update { entries in
                        for index in entries.indices where entries[index].endpointID == daemonID {
                            entries[index].endpointID = endpointID
                        }
                    }
                    rebuildOutboxOverlays()
                    startOutboxWorker()
                } catch { show(error) }
            }
        }
        if let snapshot = syncSnapshot {
            applyGlobalSnapshot(snapshot, endpointID: endpoint.id)
        } else {
            updateSelectedState()
        }
    }

    func persistenceCheckpoint() -> DieterSyncCheckpoint {
        var diskState = syncDiskState
        if !endpoint.id.isEmpty,
            syncSnapshot != nil || syncProjection.cursor != nil || syncProjection.snapshot != nil
        {
            diskState.projections[endpoint.id] = syncProjection
        }
        return DieterSyncCheckpoint(
            diskState: diskState,
            activeEndpointID: endpoint.id,
            activeSnapshot: syncSnapshot
        )
    }

    func scheduleSyncPersistence() async {
        do { try await outbox.restore() } catch {
            show(error)
            return
        }
        let checkpoint = persistenceCheckpoint()
        // Clear before the actor hop so a newer frame that arrives while the
        // writer is accepting this state marks the store dirty again.
        syncStateDirty = false
        await syncPersistence.scheduleCheckpoint(checkpoint)
    }

    func saveSyncPersistence() async throws {
        try await outbox.restore()
        let checkpoint = persistenceCheckpoint()
        syncStateDirty = false
        do {
            try await syncPersistence.saveCheckpoint(checkpoint)
        } catch {
            syncStateDirty = true
            throw error
        }
    }

    func applicationDidResignActive() {
        guard syncStateDirty else { return }
        Task { @MainActor [weak self] in
            try? await self?.saveSyncPersistence()
        }
    }

    func startGlobalSync() {
        syncTask?.cancel()
        guard let rpc else { return }
        globalSyncing = true
        lastSyncFrameAt = Date()
        let endpointID = endpoint.id
        var request = Dieter_V1_SyncRequest()
        request.conversationLimit = syncConversationMessageLimit
        request.recentConversationLimit = syncRecentConversationLimit
        request.heartbeatMs = 15_000
        if syncSnapshot != nil,
            let raw = syncProjection.cursor, let cursor = try? Dieter_V1_SyncCursor(serializedBytes: raw)
        {
            request.after = cursor
        }
        syncTask = Task { [weak self] in
            do {
                try await rpc.watchSync(request) { [weak self] frame in
                    await self?.applySyncFrame(frame, endpointID: endpointID, client: rpc)
                }
                guard !Task.isCancelled else { return }
                self?.connectionStopped(DieterStoreConnectionError.syncEnded, client: rpc)
            } catch  where Self.isExpectedCancellation(error) {} catch {
                self?.connectionStopped(error, client: rpc)
            }
        }
    }

    func applySyncFrame(_ frame: Dieter_V1_SyncFrame, endpointID: String, client: DieterRPC? = nil)
        async
    {
        guard endpoint.id == endpointID, client == nil || rpc === client else { return }
        let generation = connectionGeneration
        os_signpost(.begin, log: syncPerformanceLog, name: "Apply sync frame")
        defer { os_signpost(.end, log: syncPerformanceLog, name: "Apply sync frame") }
        let receivedAt = Date()
        lastSyncFrameAt = receivedAt
        lastSyncedAt = receivedAt
        globalSyncing = false
        syncProjection.refreshedAt = receivedAt
        refreshIslandActivityDateBoundaryIfNeeded(now: receivedAt)
        var projectionChanged = false
        var conversationDirectoryChanged = false
        if frame.hasSnapshot {
            var snapshot = frame.snapshot
            snapshot.schedules = []
            snapshot.scheduleRuns = []
            markConversationsRefreshed(snapshot.conversations, endpointID: endpointID, at: receivedAt)
            if syncSnapshot != snapshot {
                syncSnapshot = snapshot
                applyGlobalSnapshot(snapshot, endpointID: endpointID)
                projectionChanged = true
                conversationDirectoryChanged = true
            }
        } else if frame.hasDelta,
            GlobalProjectionReducer.changesProjection(frame.delta),
            let current = syncSnapshot
        {
            markConversationsRefreshed(frame.delta.conversations, endpointID: endpointID, at: receivedAt)
            let next = GlobalProjectionReducer.applying(frame.delta, to: current)
            if next != current {
                syncSnapshot = next
                if GlobalProjectionReducer.changesWorkspace(frame.delta) {
                    applyGlobalSnapshot(next, endpointID: endpointID)
                } else {
                    applySelectedConversationProjection(next, endpointID: endpointID)
                }
                projectionChanged = true
                conversationDirectoryChanged = GlobalProjectionReducer.changesConversationDirectory(
                    frame.delta)
            }
        }
        if frame.hasCursor {
            syncProjection.cursor = try? frame.cursor.serializedData()
        }
        if projectionChanged { syncStateDirty = true }
        if conversationDirectoryChanged {
            await reconcileOutboxWithProjection()
        }
        guard endpoint.id == endpointID, generation == connectionGeneration else { return }
        if SyncCursorPersistencePolicy.shouldPersist(
            projectionChanged: projectionChanged,
            lastPersistedAt: lastSyncPersistenceAt[endpointID],
            now: receivedAt
        ) {
            await scheduleSyncPersistence()
            lastSyncPersistenceAt[endpointID] = receivedAt
        }
    }

    func applyGlobalSnapshot(_ snapshot: Dieter_V1_GlobalSnapshot, endpointID: String) {
        os_signpost(.begin, log: syncPerformanceLog, name: "Apply global snapshot")
        defer { os_signpost(.end, log: syncPerformanceLog, name: "Apply global snapshot") }
        suppressIslandActivityRefresh = true
        defer {
            suppressIslandActivityRefresh = false
            refreshIslandActivityProjection()
        }
        var global = snapshot.state
        global.chats = reconcilePendingChatPins(global.chats)
        global = replica.reconcile(global)
        movingCardIDs = Set(pendingCardMoves.keys)
        labelUpdatingCardIDs = Set(pendingCardLabelUpdates.keys)
        notifyTransitions(global.cards + global.chats, endpointID: endpointID)
        replica.replaceMetadata(global, endpointID: endpointID)
        updateSelectedState(base: global)
        if projectEndpointIDs[selectedProjectID] == endpointID {
            boardSettings = snapshot.settings
        }
        if let selectedID = selectedCardID ?? selectedChatID,
            snapshot.conversations.contains(where: { $0.detail.card.id == selectedID })
        {
            applySelectedConversationProjection(snapshot, endpointID: endpointID)
        }
        rebuildOutboxOverlays()
    }

    func applySelectedConversationProjection(
        _ snapshot: Dieter_V1_GlobalSnapshot,
        endpointID: String
    ) {
        guard let selectedID = selectedCardID ?? selectedChatID,
            let projected = snapshot.conversations.first(where: { $0.detail.card.id == selectedID })
        else { return }
        if conversation != projected { conversation = projected }
        if selectedDetail != projected.detail { selectedDetail = projected.detail }
        conversationLoading = false
        conversationLastRefreshedAt = conversationRefreshDate(
            cardID: selectedID, endpointID: endpointID)
    }

    func updateSelectedState(base: Dieter_V1_State? = nil) {
        if selectedProjectID.isEmpty || projectDirectory[selectedProjectID] == nil {
            selectedProjectID = projects.first?.id ?? ""
        }
        var selected = base ?? state
        selected.project = projectDirectory[selectedProjectID] ?? Dieter_V1_Project()
        selected.boards = navigationBoards[selectedProjectID] ?? []
        selected.cards = navigationCards[selectedProjectID] ?? []
        selected.chats = chats.filter { $0.projectID == selectedProjectID }
        if state != selected { state = selected }
        if selectedBoardID.isEmpty || !selected.boards.contains(where: { $0.id == selectedBoardID }) {
            selectedBoardID = selected.boards.first?.id ?? ""
        }
    }

    func projectedConversation(cardID: String, endpointID: String) async
        -> Dieter_V1_ConversationSnapshot?
    {
        if endpointID == endpoint.id, let syncSnapshot {
            return syncSnapshot.conversations.first { $0.detail.card.id == cardID }
        }
        let projection = syncDiskState.projections[endpointID]
        return await snapshotDecoder.conversation(
            cardID: cardID, endpointID: endpointID, data: projection?.snapshot)
    }

    func conversationRefreshDate(cardID: String, endpointID: String) -> Date? {
        syncDiskState.conversationRefreshedAt[endpointID]?[cardID]
    }

    func markConversationsRefreshed(
        _ conversations: [Dieter_V1_ConversationSnapshot],
        endpointID: String,
        at date: Date
    ) {
        guard !conversations.isEmpty else { return }
        var refreshed = syncDiskState.conversationRefreshedAt[endpointID] ?? [:]
        for snapshot in conversations where !snapshot.detail.card.id.isEmpty {
            refreshed[snapshot.detail.card.id] = date
        }
        syncDiskState.conversationRefreshedAt[endpointID] = refreshed
        if let selectedID = selectedCardID ?? selectedChatID,
            conversations.contains(where: { $0.detail.card.id == selectedID })
        {
            conversationLastRefreshedAt = date
        }
    }

    /// Retain a bounded durable tail for conversations opened outside the
    /// global stream's recent set. This makes revisiting them local-first too.
    func cacheConversation(
        _ conversation: Dieter_V1_ConversationSnapshot,
        endpointID: String,
        refreshedAt: Date
    ) async {
        let cardID = conversation.detail.card.id
        guard !cardID.isEmpty else { return }
        let retainedIDs: Set<String>
        if endpointID == endpoint.id {
            var snapshot = syncSnapshot ?? Dieter_V1_GlobalSnapshot()
            snapshot.conversations.removeAll { $0.detail.card.id == cardID }
            snapshot.conversations.append(conversation)
            if snapshot.conversations.count > cachedConversationLimit {
                snapshot.conversations.removeFirst(snapshot.conversations.count - cachedConversationLimit)
            }
            syncSnapshot = snapshot
            retainedIDs = Set(snapshot.conversations.map { $0.detail.card.id })
        } else {
            let projection = syncDiskState.projections[endpointID] ?? .empty
            let result = await Task.detached(priority: .utility) {
                DieterSyncProjectionCache.cachingConversation(
                    conversation,
                    in: projection,
                    limit: cachedConversationLimit
                )
            }.value
            syncDiskState.projections[endpointID] = result.projection
            retainedIDs = result.retainedCardIDs
        }
        syncStateDirty = true
        markConversationsRefreshed([conversation], endpointID: endpointID, at: refreshedAt)

        syncDiskState.conversationRefreshedAt[endpointID] =
            syncDiskState.conversationRefreshedAt[endpointID]?.filter { retainedIDs.contains($0.key) }
        await scheduleSyncPersistence()
    }

    func rebuildOutboxOverlays() {
        pendingCardIDs = Set(
            outbox.entries.filter { $0.kind != .sendMessage }.map { $0.serverID ?? $0.optimisticID })
        pendingMessageIDs = Set(outbox.entries.filter { $0.kind == .sendMessage }.map(\.optimisticID))
        acceptedOutboxIDs = Set(
            outbox.entries.filter { $0.serverID != nil }.flatMap { [$0.optimisticID, $0.serverID!] })
        failedOutboxIDs = Set(
            outbox.entries.filter { $0.state == .failed }.map { $0.serverID ?? $0.optimisticID })
        machineOutboxSummaries = MachineOutboxSummary.summaries(for: outbox.entries)
        var projectedChats = chats
        let orphanedIDs = Set(
            outbox.entries.compactMap { entry -> String? in
                guard entry.kind == .createChat,
                    let request = try? Dieter_V1_CreateConversationRequest(serializedBytes: entry.request),
                    projectDirectory[request.projectID] == nil
                else { return nil }
                return entry.serverID ?? entry.optimisticID
            })
        projectedChats.removeAll { orphanedIDs.contains($0.id) }
        for entry in outbox.entries {
            switch entry.kind {
            case .createCard, .createChat:
                guard
                    let request = try? Dieter_V1_CreateConversationRequest(serializedBytes: entry.request),
                    projectDirectory[request.projectID] != nil
                else { continue }
                var card = Dieter_V1_Card()
                card.id = entry.serverID ?? entry.optimisticID
                card.scope = entry.kind == .createChat ? "chat" : "board"
                card.projectID = request.projectID
                card.boardID = entry.kind == .createChat ? "" : request.boardID
                card.lane = request.lane
                card.title = request.title
                card.initialPrompt = request.prompt
                card.provider = request.provider
                card.model = request.model
                card.effort = request.effort
                card.workspaceMode = request.workspaceMode
                card.workspaceBranch = request.workspaceBranch
                card.workspaceBaseBranch = request.workspaceBaseBranch
                card.runtime = entry.state == .failed ? "failed" : "pending"
                card.createdAt = DieterTimestamp.string(from: entry.createdAt)
                card.updatedAt = card.createdAt
                if entry.kind == .createChat {
                    if !projectedChats.contains(where: { $0.id == card.id }) {
                        projectedChats.insert(card, at: 0)
                    }
                } else if card.projectID == selectedProjectID,
                    !state.cards.contains(where: { $0.id == card.id })
                {
                    state.cards.append(card)
                    navigationCards[card.projectID, default: []].append(card)
                }
            case .sendMessage:
                continue
            }
        }
        if let snapshot = conversation {
            conversation = DieterOutboxPolicy.overlayOptimisticMessages(
                snapshot,
                entries: syncDiskState.outbox
            )
        }
        if chats != projectedChats { chats = projectedChats }
    }

    func reconcileOutboxWithProjection() async {
        guard let snapshot = syncSnapshot else { return }
        let endpointID = endpoint.id
        let cardIDs = Set((snapshot.state.cards + snapshot.state.chats).map(\.id))
        do {
            let accepted = try await outbox.update { entries -> [(String, String, Bool)] in
                var accepted: [(String, String, Bool)] = []
                for index in entries.indices {
                    let entry = entries[index]
                    guard entry.endpointID == endpointID,
                        let serverID = DieterOutboxPolicy.synchronizedConversationID(
                            for: entry, visibleConversationIDs: cardIDs)
                    else { continue }
                    entries[index].serverID = serverID
                    try DieterOutboxPolicy.retargetDependencies(
                        in: &entries, from: entry.optimisticID, to: serverID)
                    accepted.append((entry.optimisticID, serverID, entry.kind == .createChat))
                }
                entries.removeAll { entry in
                    guard entry.endpointID == endpointID, let serverID = entry.serverID else { return false }
                    return entry.kind == .sendMessage || cardIDs.contains(serverID)
                }
                return accepted
            }
            guard endpoint.id == endpointID else { return }
            for (localID, serverID, chat) in accepted {
                if retargetOptimisticConversation(from: localID, to: serverID) {
                    scheduleCreatedConversationOpen(cardID: serverID, chat: chat)
                }
            }
            rebuildOutboxOverlays()
        } catch { show(error) }
    }

    func enqueueOutbox(_ entry: DieterOutboxEntry) async throws {
        try await outbox.enqueue(entry)
        rebuildOutboxOverlays()
        startOutboxWorker()
    }

    func enqueueMessage(_ request: Dieter_V1_SendMessageRequest, endpointID: String) async throws {
        try await enqueueOutbox(
            DieterOutboxEntry(
                commandID: request.commandID, clientID: request.clientID, endpointID: endpointID,
                kind: .sendMessage, request: try request.serializedData(), optimisticID: request.messageID,
                attempts: 0, createdAt: Date()
            ))
    }

    func startOutboxWorker() {
        outbox.start(
            reachable: { [weak self] in
                guard let self, self.rpc != nil, self.phase.isConnected else { return [] }
                return [self.endpoint.id]
                    + self.endpoints.filter { $0.online && $0.id != self.endpoint.id }.map(\.id)
            },
            acquire: { [weak self] endpointID in
                guard let self else { throw CancellationError() }
                if endpointID == self.endpoint.id, let rpc = self.rpc {
                    return OutboxTransport(rpc: rpc, release: {})
                }
                guard let machine = self.endpoints.first(where: { $0.id == endpointID }), machine.online
                else {
                    throw CancellationError()
                }
                let lease = try await self.selectDirectoryDataPlane(for: machine)
                self.machineConnectionStatuses[machine.id] = lease.connection
                return OutboxTransport(rpc: lease.rpc, release: { lease.release() })
            },
            committed: { [weak self] entry in
                guard let self else { return }
                var shouldOpen = false
                if let serverID = entry.serverID, entry.kind != .sendMessage {
                    shouldOpen = self.retargetOptimisticConversation(
                        from: entry.optimisticID, to: serverID, endpointID: entry.endpointID)
                }
                await self.reconcileOutboxWithProjection()
                self.rebuildOutboxOverlays()
                if shouldOpen, let serverID = entry.serverID, self.endpoint.id == entry.endpointID {
                    self.scheduleCreatedConversationOpen(cardID: serverID, chat: entry.kind == .createChat)
                }
            },
            failed: { [weak self] entry, error in
                guard let self else { return }
                if entry.kind != .sendMessage {
                    self.setOptimisticConversationStatus(
                        entry, status: entry.state == .failed ? "failed" : "pending")
                }
                self.rebuildOutboxOverlays()
                outboxLogger.error(
                    "Pending command \(entry.commandID, privacy: .public) failed: \(DieterRPCFailure.message(for: error), privacy: .public)"
                )
            }, storageFailed: { [weak self] error in self?.show(error) }, clock: environment.clock)
    }

    func retryOutboxItem(_ id: String) async {
        do {
            try await outbox.update { entries in
                for index in entries.indices
                where
                    (entries[index].optimisticID == id || entries[index].serverID == id)
                    && entries[index].state == .failed
                {
                    entries[index].state = .queued
                    entries[index].attempts = 0
                    entries[index].lastError = nil
                    entries[index].nextAttemptAt = nil
                }
            }
            refreshOutboxAfterRetry()
        } catch { show(error) }
    }

    func retryOutbox(for machine: DieterEndpoint) async {
        do {
            try await outbox.update { entries in
                for index in entries.indices
                where entries[index].endpointID == machine.id && entries[index].serverID == nil {
                    entries[index].state = .queued
                    entries[index].attempts = 0
                    entries[index].lastError = nil
                    entries[index].nextAttemptAt = nil
                }
            }
            refreshOutboxAfterRetry()
            await refreshDaemonPresence()
            if endpoint.id == machine.id, !phase.isConnected { scheduleReconnect(to: machine) }
        } catch { show(error) }
    }

    private func refreshOutboxAfterRetry() {
        for entry in outbox.entries where entry.state == .queued {
            setOptimisticConversationStatus(entry, status: "pending")
        }
        rebuildOutboxOverlays()
        startOutboxWorker()
    }

    func discardOutboxItem(_ id: String) async {
        do {
            let removed = try await outbox.update { entries -> [DieterOutboxEntry] in
                guard
                    let index = entries.firstIndex(where: {
                        ($0.optimisticID == id || $0.serverID == id) && $0.serverID == nil
                    })
                else { return [] }
                let entry = entries.remove(at: index)
                // A discarded creation cannot leave messages waiting on its local ID.
                let dependent = entries.filter { candidate in
                    guard candidate.kind == .sendMessage,
                        let request = try? Dieter_V1_SendMessageRequest(serializedBytes: candidate.request)
                    else { return false }
                    return candidate.endpointID == entry.endpointID && request.cardID == entry.optimisticID
                }
                let ids = Set(dependent.map(\.commandID))
                entries.removeAll { ids.contains($0.commandID) }
                return [entry] + dependent
            }
            removeOptimisticOutboxArtifacts(for: removed)
            rebuildOutboxOverlays()
            startOutboxWorker()
        } catch { show(error) }
    }

    @discardableResult
    func discardOutbox(for machine: DieterEndpoint) async -> Int {
        do {
            let removed = try await outbox.update { entries in
                DieterOutboxPolicy.removeUndelivered(from: &entries, endpointID: machine.id)
            }
            removeOptimisticOutboxArtifacts(for: removed)
            rebuildOutboxOverlays()
            startOutboxWorker()
            return removed.count
        } catch {
            show(error)
            return 0
        }
    }

    func removeOptimisticOutboxArtifacts(for entries: [DieterOutboxEntry]) {
        let conversationIDs = Set(
            entries.lazy
                .filter { $0.kind != .sendMessage }
                .flatMap { [$0.optimisticID, $0.serverID].compactMap { $0 } })
        let messageIDs = Set(
            entries.lazy
                .filter { $0.kind == .sendMessage }
                .map(\.optimisticID))

        if !conversationIDs.isEmpty {
            state.cards.removeAll { conversationIDs.contains($0.id) }
            chats.removeAll { conversationIDs.contains($0.id) }
            for projectID in Array(navigationCards.keys) {
                navigationCards[projectID]?.removeAll { conversationIDs.contains($0.id) }
            }
            if let selected = selectedCardID ?? selectedChatID, conversationIDs.contains(selected) {
                closeConversation()
            }
        }
        if !messageIDs.isEmpty, var snapshot = conversation {
            snapshot.conversation.messages.removeAll { messageIDs.contains($0.id) }
            conversation = snapshot
        }
        if !messageIDs.isEmpty {
            olderConversationMessages.removeAll { messageIDs.contains($0.id) }
        }
    }

    @discardableResult
    func retargetOptimisticConversation(
        from optimisticID: String, to serverID: String, endpointID: String? = nil
    )
        -> Bool
    {
        let selected = (selectedCardID ?? selectedChatID) == optimisticID
        composer.retarget(
            from: WorkspaceTarget(
                endpointID: endpointID ?? endpoint.id, projectID: "", conversationID: optimisticID),
            to: WorkspaceTarget(
                endpointID: endpointID ?? endpoint.id, projectID: "", conversationID: serverID)
        )
        let authoritative =
            state.cards.first(where: { $0.id == serverID })
            ?? state.chats.first(where: { $0.id == serverID })
            ?? chats.first(where: { $0.id == serverID })
            ?? navigationCards.values.lazy.compactMap({ cards in
                cards.first(where: { $0.id == serverID })
            }).first
        if selectedCardID == optimisticID { selectedCardID = serverID }
        if selectedChatID == optimisticID { selectedChatID = serverID }
        state.cards = DieterOutboxPolicy.retargetedCards(
            state.cards,
            from: optimisticID,
            to: serverID,
            authoritative: authoritative
        )
        state.chats = DieterOutboxPolicy.retargetedCards(
            state.chats,
            from: optimisticID,
            to: serverID,
            authoritative: authoritative
        )
        chats = DieterOutboxPolicy.retargetedCards(
            chats,
            from: optimisticID,
            to: serverID,
            authoritative: authoritative
        )
        for projectID in Array(navigationCards.keys) {
            navigationCards[projectID] = DieterOutboxPolicy.retargetedCards(
                navigationCards[projectID] ?? [],
                from: optimisticID,
                to: serverID,
                authoritative: authoritative
            )
        }
        if var snapshot = conversation,
            snapshot.detail.card.id == optimisticID || snapshot.conversation.cardID == optimisticID
        {
            snapshot.detail.card.id = serverID
            snapshot.conversation.cardID = serverID
            conversation = snapshot
        }
        if var detail = selectedDetail, detail.card.id == optimisticID {
            detail.card.id = serverID
            selectedDetail = detail
        }
        return selected
    }

    func setOptimisticConversationStatus(_ entry: DieterOutboxEntry, status: String) {
        guard entry.kind != .sendMessage else { return }
        let id = entry.serverID ?? entry.optimisticID
        state.cards = state.cards.map { card in
            var card = card
            if card.id == id { card.runtime = status }
            return card
        }
        chats = chats.map { card in
            var card = card
            if card.id == id { card.runtime = status }
            return card
        }
        for projectID in Array(navigationCards.keys) {
            navigationCards[projectID] = navigationCards[projectID]?.map { card in
                var card = card
                if card.id == id { card.runtime = status }
                return card
            }
        }
        if var snapshot = conversation, snapshot.conversation.cardID == id {
            snapshot.conversation.status = status
            snapshot.detail.card.runtime = status
            conversation = snapshot
            selectedDetail = snapshot.detail
        }
    }

    /// Creation is durable as soon as the outbox RPC returns. Open the accepted
    /// conversation in a new task so cancellation of the mutation worker cannot
    /// cancel the follow-up read and leave the optimistic conversation stranded.
    func scheduleCreatedConversationOpen(cardID: String, chat: Bool) {
        Task { @MainActor [weak self] in
            guard let self, (self.selectedCardID ?? self.selectedChatID) == cardID else { return }
            await self.openConversation(cardID: cardID, chat: chat)
        }
    }

    func refreshState() async {
        guard let rpc else {
            if let snapshot = syncSnapshot {
                applyGlobalSnapshot(snapshot, endpointID: endpoint.id)
            }
            return
        }
        stateRequestGeneration &+= 1
        let generation = stateRequestGeneration
        let request = stateRequest()
        do {
            let value = try await rpc.state(request)
            guard self.rpc === rpc, generation == stateRequestGeneration,
                selectedProjectID == request.projectID
            else {
                return
            }
            acceptState(value)
        } catch {
            guard self.rpc === rpc, generation == stateRequestGeneration,
                selectedProjectID == request.projectID
            else {
                return
            }
            if DieterRPCFailure.isTransient(error) {
                connectionStopped(error, client: rpc)
            } else {
                show(error)
            }
        }
    }

    func stateRequest() -> Dieter_V1_GetStateRequest {
        var request = Dieter_V1_GetStateRequest()
        request.projectID = selectedProjectID
        return request
    }

    func acceptState(_ received: Dieter_V1_State) {
        var next = received
        next = replica.reconcile(next)
        movingCardIDs = Set(pendingCardMoves.keys)
        labelUpdatingCardIDs = Set(pendingCardLabelUpdates.keys)
        notifyTransitions(next.cards + next.chats, endpointID: endpoint.id)
        if state != next { state = next }
        if !next.project.id.isEmpty {
            navigationBoards[next.project.id] = next.boards
            navigationCards[next.project.id] = next.cards
        }
        for project in next.projects {
            projectDirectory[project.id] = project
            projectEndpointIDs[project.id] = endpoint.id
        }
        if selectedProjectID.isEmpty || !next.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID =
                next.project.id.isEmpty ? (next.projects.first?.id ?? "") : next.project.id
        }
        if selectedBoardID.isEmpty || !next.boards.contains(where: { $0.id == selectedBoardID }) {
            selectedBoardID =
                next.boards.first(where: { $0.projectID == selectedProjectID })?.id ?? next.boards.first?.id
                ?? ""
        }
        rebuildOutboxOverlays()
    }

    func refreshNavigation() async {
        await refreshState()
    }
}
