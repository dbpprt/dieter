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
        let restored = await syncPersistence.load()
        syncDiskState = restored
        let activePrefix = activeGateway.credentialID + "#"
        let deploymentProjections = restored.projections
            .filter { $0.key.hasPrefix(activePrefix) }
            .sorted { $0.key < $1.key }
        let restoreSelection = selectedProjectID.isEmpty
        let selectionGeneration = boardSelectionGeneration
        lastSyncedAt =
            restored.projections[endpoint.id]?.refreshedAt
            ?? deploymentProjections.compactMap(\.value.refreshedAt).max()
        var decodedProjections: [(endpointID: String, snapshot: Dieter_V1_GlobalSnapshot)] = []
        for (endpointID, projection) in deploymentProjections {
            if let snapshot = await snapshotDecoder.snapshot(
                endpointID: endpointID, data: projection.snapshot)
            {
                decodedProjections.append((endpointID, snapshot))
            }
        }
        let shouldChooseInitialSelection =
            restoreSelection && selectedProjectID.isEmpty && boardSelectionGeneration == selectionGeneration
        for projection in decodedProjections {
            applyGlobalSnapshot(projection.snapshot, endpointID: projection.endpointID)
        }
        // Each cached machine is decoded before publishing so the first one to
        // restore cannot permanently claim an otherwise empty launch selection.
        // Respect an explicit navigation that happened while decoding.
        if shouldChooseInitialSelection {
            selectedProjectID = preferredInitialProjectID()
            selectedBoardID = ""
            updateSelectedState()
        }
        rebuildOutboxOverlays()
    }

    func activateSyncProjection(
        for endpoint: DieterEndpoint, decodedSnapshot: Dieter_V1_GlobalSnapshot?, decodedData: Data?
    ) {
        syncProjection = syncDiskState.projections[endpoint.id] ?? .empty
        // Metadata refresh may replace this endpoint while decoding is suspended.
        // Never pair that newer cursor with a snapshot decoded from older bytes.
        let matchingSnapshot = syncProjection.snapshot == decodedData ? decodedSnapshot : nil
        syncSnapshot = matchingSnapshot
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
        // Keep the in-memory machine directory and the durable checkpoint in
        // agreement. A route switch reads the former, not the persistence file.
        while true {
            try Task.checkCancellation()
            let activeID = endpoint.id
            let snapshot = syncSnapshot
            let projection = syncProjection
            if let snapshot {
                let data = try await Task.detached(priority: .utility) {
                    try snapshot.serializedData()
                }.value
                try Task.checkCancellation()
                guard endpoint.id == activeID else { return }
                guard syncSnapshot == snapshot, syncProjection.cursor == projection.cursor,
                    syncProjection.snapshot == projection.snapshot,
                    syncProjection.refreshedAt == projection.refreshedAt
                else { continue }
                var retained = projection
                retained.snapshot = data
                syncProjection = retained
                syncDiskState.projections[activeID] = retained
            }
            let checkpoint = persistenceCheckpoint()
            syncStateDirty = false
            do {
                try await syncPersistence.saveCheckpoint(checkpoint)
            } catch {
                syncStateDirty = true
                throw error
            }
            guard endpoint.id == activeID else { return }
            // Live frames can arrive during disk I/O. Do not let a switch
            // discard a transcript newer than the snapshot just retained.
            if syncSnapshot == snapshot, syncProjection.cursor == projection.cursor,
                syncProjection.refreshedAt == projection.refreshedAt
            {
                return
            }
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
        syncSubscriptionGeneration &+= 1
        let subscription = syncSubscriptionGeneration
        pendingSyncSnapshot = nil
        syncRecoveryEscalationTask?.cancel()
        syncRecoveryEscalationTask = nil
        guard let rpc else { return }
        globalSyncing = true
        syncAttemptStartedAt = Date()
        syncLastActivity = ContinuousClock.now
        syncTransportTimeout = .seconds(45)
        let endpointID = endpoint.id
        syncTask = Task { [weak self] in
            defer {
                // A finished task must not suppress activation recovery, and an
                // older subscription must never clear its replacement's task.
                if let self, self.syncSubscriptionGeneration == subscription {
                    self.syncTask = nil
                }
            }
            var consecutiveFailures = 0
            while !Task.isCancelled, let self,
                self.rpc === rpc,
                self.endpoint.id == endpointID
            {
                self.pendingSyncSnapshot = nil
                let request = self.syncRequestForCurrentCursor()
                let attemptStartedAt = Date()
                var failure: Error?
                do {
                    try await rpc.watchSync(request) { [weak self] frame in
                        await self?.applySyncFrame(
                            frame, endpointID: endpointID, client: rpc, subscription: subscription)
                    }
                    guard !Task.isCancelled else { return }
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error
                }
                guard self.rpc === rpc, self.endpoint.id == endpointID else { return }
                if let failure,
                    !DieterRPCFailure.canRetryRead(failure)
                {
                    if DieterRPCFailure.isAuthenticationFailure(failure) {
                        self.connectionStopped(failure, client: rpc, source: "watch-sync-auth")
                    } else {
                        self.show(failure)
                    }
                    return
                }
                let receivedFrame = self.lastSyncFrameAt.map { $0 >= attemptStartedAt } ?? false
                consecutiveFailures = receivedFrame ? 1 : consecutiveFailures + 1
                let delay = DieterStreamRecoveryPolicy.delay(consecutiveFailures: consecutiveFailures)
                self.globalSyncing = true
                self.scheduleSyncRecoveryEscalation(endpointID: endpointID, client: rpc)
                connectionLogger.info(
                    "WatchSync ended on \(endpointID, privacy: .public); resubscribing after \(delay, privacy: .public)s without replacing the data plane"
                )
                try? await DieterTaskSleep.seconds(delay)
            }
        }
    }

    private func scheduleSyncRecoveryEscalation(endpointID: String, client: DieterRPC) {
        guard syncRecoveryEscalationTask == nil else { return }
        syncRecoveryEscalationTask = Task { [weak self] in
            try? await DieterTaskSleep.seconds(DieterStreamRecoveryPolicy.resubscriptionTimeout)
            guard !Task.isCancelled, let self,
                self.rpc === client,
                self.endpoint.id == endpointID,
                self.globalSyncing
            else { return }
            self.syncRecoveryEscalationTask = nil
            self.connectionStopped(
                DieterStoreConnectionError.syncTimedOut,
                client: client,
                source: "watch-sync-resubscription-timeout"
            )
        }
    }

    private func syncRequestForCurrentCursor() -> Dieter_V1_SyncRequest {
        var request = Dieter_V1_SyncRequest()
        request.conversationLimit = syncConversationMessageLimit
        request.recentConversationLimit = syncRecentConversationLimit
        request.heartbeatMs = 5_000
        request.protocolVersion = Int32(DieterContract.number)
        if syncSnapshot != nil,
            let raw = syncProjection.cursor, let cursor = try? Dieter_V1_SyncCursor(serializedBytes: raw)
        {
            request.after = cursor
        }
        return request
    }

    func applySyncFrame(
        _ incomingFrame: Dieter_V1_SyncFrame, endpointID: String, client: DieterRPC? = nil, subscription: UInt64? = nil
    )
        async
    {
        guard endpoint.id == endpointID, client == nil || rpc === client,
            subscription == nil || subscription == syncSubscriptionGeneration
        else { return }
        var frame = incomingFrame
        let generation = connectionGeneration
        os_signpost(.begin, log: syncPerformanceLog, name: "Apply sync frame")
        defer { os_signpost(.end, log: syncPerformanceLog, name: "Apply sync frame") }
        let receivedAt = Date()
        syncRecoveryEscalationTask?.cancel()
        syncRecoveryEscalationTask = nil
        lastSyncFrameAt = receivedAt
        syncLastActivity = ContinuousClock.now
        if frame.transportOnly || frame.cursor.projectionVersion >= 5 { syncTransportTimeout = .seconds(15) }
        if frame.transportOnly || frame.heartbeat {
            if frame.projectionPending,
                syncSnapshot == nil
                    || syncLastAppliedActivity.map({ $0.duration(to: ContinuousClock.now) >= .seconds(10) }) != false
            {
                globalSyncing = true
            }
            return
        }
        if frame.projectionPending {
            syncProjection.cursor = nil
            globalSyncing = true
            if frame.hasSnapshot {
                pendingSyncSnapshot = frame.snapshot
            } else if frame.hasDelta, let base = pendingSyncSnapshot ?? syncSnapshot {
                pendingSyncSnapshot = GlobalProjectionReducer.applying(frame.delta, to: base)
            }
            return
        }
        if let pending = pendingSyncSnapshot {
            let complete =
                frame.hasSnapshot
                ? frame.snapshot
                : frame.hasDelta ? GlobalProjectionReducer.applying(frame.delta, to: pending) : pending
            frame.clearDelta()
            frame.snapshot = complete
            pendingSyncSnapshot = nil
        }
        syncLastAppliedActivity = ContinuousClock.now
        lastSyncedAt = receivedAt
        globalSyncing = frame.projectionPending
        if frame.projectionPending { syncProjection.cursor = nil }
        if let recoveryStartedAt = connectionRecoveryStartedAt {
            let duration = max(0, receivedAt.timeIntervalSince(recoveryStartedAt))
            connectionLogger.notice(
                "Connection recovery from \(self.connectionRecoverySource, privacy: .public) delivered its first sync frame after \(duration, privacy: .public)s"
            )
            connectionRecoveryStartedAt = nil
            connectionRecoverySource = ""
        }
        if !frame.projectionPending { syncProjection.refreshedAt = receivedAt }
        refreshIslandActivityDateBoundaryIfNeeded(now: receivedAt)
        var projectionChanged = false
        var conversationDirectoryChanged = false
        if frame.hasSnapshot {
            var snapshot = frame.snapshot
            snapshot.conversations = snapshot.conversations.map { incoming in
                TranscriptFreshness.merging(
                    incoming,
                    with: syncSnapshot?.conversations.first {
                        $0.detail.card.id == incoming.detail.card.id
                    })
            }
            let incomingIDs = Set(snapshot.conversations.map { $0.detail.card.id })
            let retained = (syncSnapshot?.conversations ?? []).filter {
                !incomingIDs.contains($0.detail.card.id)
            }
            // Global snapshots carry only a bounded recent set. Omission is
            // not deletion of a transcript the user explicitly opened.
            snapshot.conversations = Array((retained + snapshot.conversations).suffix(cachedConversationLimit))
            markConversationsRefreshed(
                snapshot.conversations.filter { incomingIDs.contains($0.detail.card.id) },
                endpointID: endpointID, at: receivedAt)
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
        if frame.hasCursor && !frame.heartbeat && !frame.projectionPending {
            syncProjection.cursor = try? frame.cursor.serializedData()
        }
        if projectionChanged { syncStateDirty = true }
        if conversationDirectoryChanged {
            await reconcileOutboxWithProjection()
        }
        guard endpoint.id == endpointID, generation == connectionGeneration,
            subscription == nil || subscription == syncSubscriptionGeneration
        else { return }
        if !frame.projectionPending
            && SyncCursorPersistencePolicy.shouldPersist(
                projectionChanged: projectionChanged,
                lastPersistedAt: lastSyncPersistenceAt[endpointID],
                now: receivedAt
            )
        {
            await scheduleSyncPersistence()
            lastSyncPersistenceAt[endpointID] = receivedAt
        }
    }

    func applyGlobalSnapshot(_ snapshot: Dieter_V1_GlobalSnapshot, endpointID: String) {
        publishedConversationIDs[endpointID] = Set((snapshot.state.cards + snapshot.state.chats).map(\.id))
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
        replica.replaceMetadata(
            global,
            endpoint: endpoints.first { $0.id == endpointID } ?? DieterEndpoint(name: endpointID, host: "", port: 0),
            endpointID: endpointID)
        updateSelectedState(base: global)
        if projectReplicaEndpointIDs[selectedProjectID] == endpointID {
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
        let latest = TranscriptFreshness.merging(projected, with: conversation)
        if conversation != latest { conversation = latest }
        if selectedDetail != projected.detail { selectedDetail = projected.detail }
        conversationLoading = false
        conversationSyncing = false
        conversationError = nil
        conversationLastRefreshedAt = conversationRefreshDate(
            cardID: selectedID, endpointID: endpointID)
    }

    func updateSelectedState(base: Dieter_V1_State? = nil) {
        if selectedProjectID.isEmpty || projectDirectory[selectedProjectID] == nil {
            selectedProjectID = preferredInitialProjectID()
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

    private func preferredInitialProjectID() -> String {
        let visible = projects.filter { !$0.archived }
        let visibleIDs = visible.map(\.id)
        return sidebarProjectNavigation.orderedIDs(from: visibleIDs).first
            ?? projects.first?.id
            ?? ""
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
            let retained = TranscriptFreshness.merging(
                conversation, with: snapshot.conversations.first { $0.detail.card.id == cardID })
            snapshot.conversations.removeAll { $0.detail.card.id == cardID }
            snapshot.conversations.append(retained)
            if snapshot.conversations.count > cachedConversationLimit {
                snapshot.conversations.removeFirst(snapshot.conversations.count - cachedConversationLimit)
            }
            syncSnapshot = snapshot
            retainedIDs = Set(snapshot.conversations.map { $0.detail.card.id })
        } else {
            while true {
                let projection = syncDiskState.projections[endpointID] ?? .empty
                let result = await Task.detached(priority: .utility) {
                    DieterSyncProjectionCache.cachingConversation(
                        conversation, in: projection, limit: cachedConversationLimit)
                }.value
                guard !Task.isCancelled else { return }
                if endpointID == endpoint.id {
                    await cacheConversation(conversation, endpointID: endpointID, refreshedAt: refreshedAt)
                    return
                }
                let current = syncDiskState.projections[endpointID] ?? .empty
                // A directory read or another conversation may have committed
                // during decoding. Rebase rather than overwriting that work.
                guard current.snapshot == projection.snapshot, current.cursor == projection.cursor else { continue }
                syncDiskState.projections[endpointID] = result.projection
                retainedIDs = result.retainedCardIDs
                break
            }
        }
        syncStateDirty = true
        markConversationsRefreshed([conversation], endpointID: endpointID, at: refreshedAt)

        syncDiskState.conversationRefreshedAt[endpointID] =
            syncDiskState.conversationRefreshedAt[endpointID]?.filter { retainedIDs.contains($0.key) }
        await scheduleSyncPersistence()
    }

    func rebuildOutboxOverlays() {
        pendingCardIDs = Set(
            outbox.entries.filter { $0.kind != .sendMessage }.flatMap { DieterOutboxPolicy.conversationIDs(for: $0) })
        pendingMessageIDs = Set(outbox.entries.filter { $0.kind == .sendMessage }.map(\.optimisticID))
        acceptedOutboxIDs = Set(
            outbox.entries.filter { $0.serverID != nil }.flatMap { [$0.optimisticID, $0.serverID!] })
        failedOutboxIDs = Set(
            outbox.entries.filter { $0.state == .failed }.flatMap { DieterOutboxPolicy.conversationIDs(for: $0) })
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
                // Sync can publish the created conversation before the unary
                // reply or journal acknowledgement. Compose that authoritative
                // row immediately; awaiting durable reconciliation must not
                // briefly reinsert its optimistic counterpart beside it.
                let visibleCards =
                    entry.kind == .createChat
                    ? projectedChats : state.cards + (navigationCards[request.projectID] ?? [])
                let serverID =
                    entry.serverID
                    ?? DieterOutboxPolicy.synchronizedConversationID(
                        for: entry,
                        visibleConversationIDs: publishedConversationIDs[entry.endpointID] ?? []
                    )
                if let serverID {
                    let authoritative = visibleCards.first { $0.id == serverID }
                    if entry.kind == .createChat {
                        projectedChats = DieterOutboxPolicy.retargetedCards(
                            projectedChats, from: entry.optimisticID, to: serverID, authoritative: authoritative)
                    } else {
                        state.cards = DieterOutboxPolicy.retargetedCards(
                            state.cards, from: entry.optimisticID, to: serverID, authoritative: authoritative)
                        navigationCards[request.projectID] = DieterOutboxPolicy.retargetedCards(
                            navigationCards[request.projectID] ?? [], from: entry.optimisticID, to: serverID,
                            authoritative: authoritative)
                    }
                }
                var card = Dieter_V1_Card()
                card.id = serverID ?? entry.optimisticID
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
                entries: outbox.entries
            )
        }
        if chats != projectedChats { chats = projectedChats }
    }

    func reconcileOutboxWithProjection() async {
        guard let snapshot = syncSnapshot else { return }
        let endpointID = endpoint.id
        let cards = snapshot.state.cards + snapshot.state.chats
        let cardIDs = Set(cards.map(\.id))
        do {
            let accepted = try await outbox.update { entries -> [(String, String, Bool)] in
                var accepted: [(String, String, Bool)] = []
                for index in entries.indices {
                    let entry = entries[index]
                    guard entry.endpointID == endpointID,
                        let serverID = DieterOutboxPolicy.synchronizedConversationID(
                            for: entry, visibleConversationIDs: cardIDs),
                        let card = cards.first(where: { $0.id == serverID }),
                        DieterOutboxPolicy.creationIsComplete(entry, card: card)
                    else { continue }
                    entries[index].serverID = serverID
                    try DieterOutboxPolicy.retargetDependencies(
                        in: &entries, from: entry.optimisticID, to: serverID)
                    accepted.append((entry.optimisticID, serverID, entry.kind == .createChat))
                }
                entries.removeAll { entry in
                    guard entry.endpointID == endpointID, let serverID = entry.serverID else { return false }
                    return entry.kind == .sendMessage
                        || cards.contains {
                            $0.id == serverID && DieterOutboxPolicy.creationIsComplete(entry, card: $0)
                        }
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
                    DieterOutboxPolicy.conversationIDs(for: entries[index]).contains(id)
                    && entries[index].state != .queued
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
                        DieterOutboxPolicy.conversationIDs(for: $0).contains(id) && $0.serverID == nil
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
        guard optimisticID != serverID else { return selected }
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
                connectionLogger.info(
                    "State refresh failed transiently on \(self.endpoint.id, privacy: .public); retaining the WatchSync projection"
                )
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
        for board in next.boards { replica.upsert(board, selectedProjectID: selectedProjectID) }
        for card in next.cards + next.chats { replica.upsert(card) }
        for project in next.projects {
            projectDirectory[project.id] = MachineDirectoryReducer.mergeProject(projectDirectory[project.id], project)
            projectReplicaEndpointIDs[project.id] = endpoint.id
        }
        if !next.project.id.isEmpty {
            state.cards = navigationCards[next.project.id] ?? next.cards
            state.boards = navigationBoards[next.project.id] ?? next.boards
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
