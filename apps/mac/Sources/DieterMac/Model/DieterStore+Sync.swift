import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func restorePersistentSync() async {
        let restored = await syncPersistence.load()
        syncDiskState = restored
        let activePrefix = activeGateway.credentialID + "#"
        let deploymentProjections = restored.projections
            .filter { $0.key.hasPrefix(activePrefix) }
            .sorted { $0.key < $1.key }
        lastSyncedAt = restored.projections[endpoint.id]?.refreshedAt
            ?? deploymentProjections.compactMap(\.value.refreshedAt).max()
        for (endpointID, projection) in deploymentProjections {
            if let raw = projection.snapshot,
               let snapshot = try? Dieter_V1_GlobalSnapshot(serializedBytes: raw) {
                applyGlobalSnapshot(snapshot, endpointID: endpointID)
            }
        }
        if deploymentProjections.isEmpty,
           let raw = restored.snapshot,
           let snapshot = try? Dieter_V1_GlobalSnapshot(serializedBytes: raw) {
            applyGlobalSnapshot(snapshot, endpointID: endpoint.id)
        }
        rebuildOutboxOverlays()
    }

    func activateSyncProjection(for endpoint: DieterEndpoint) {
        if let persisted = syncDiskState.projections[endpoint.id] {
            syncProjection = persisted
        } else {
            syncProjection = DieterSyncProjection(cursor: syncDiskState.cursor, snapshot: syncDiskState.snapshot)
            syncDiskState.projections[endpoint.id] = syncProjection
            syncDiskState.cursor = nil
            syncDiskState.snapshot = nil
        }
        syncSnapshot = syncProjection.snapshot.flatMap {
            try? Dieter_V1_GlobalSnapshot(serializedBytes: $0)
        }.map { snapshot in
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
            for index in syncDiskState.outbox.indices where syncDiskState.outbox[index].endpointID == daemonID {
                syncDiskState.outbox[index].endpointID = endpoint.id
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
           syncSnapshot != nil || syncProjection.cursor != nil || syncProjection.snapshot != nil {
            diskState.projections[endpoint.id] = syncProjection
        }
        return DieterSyncCheckpoint(
            diskState: diskState,
            activeEndpointID: endpoint.id,
            activeSnapshot: syncSnapshot
        )
    }

    func scheduleSyncPersistence() async {
        let checkpoint = persistenceCheckpoint()
        // Clear before the actor hop so a newer frame that arrives while the
        // writer is accepting this state marks the store dirty again.
        syncStateDirty = false
        await syncPersistence.scheduleCheckpoint(checkpoint)
    }

    func saveSyncPersistence() async throws {
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
           let raw = syncProjection.cursor, let cursor = try? Dieter_V1_SyncCursor(serializedBytes: raw) {
            request.after = cursor
        }
        syncTask = Task { [weak self] in
            do {
                try await rpc.watchSync(request) { [weak self] frame in
                    await self?.applySyncFrame(frame, endpointID: endpointID)
                }
                guard !Task.isCancelled else { return }
                self?.connectionStopped(DieterStoreConnectionError.syncEnded, client: rpc)
            } catch where Self.isExpectedCancellation(error) { }
            catch { self?.connectionStopped(error, client: rpc) }
        }
    }

    func applySyncFrame(_ frame: Dieter_V1_SyncFrame, endpointID: String) async {
        guard endpoint.id == endpointID else { return }
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
                  let current = syncSnapshot {
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
                conversationDirectoryChanged = GlobalProjectionReducer.changesConversationDirectory(frame.delta)
            }
        }
        if frame.hasCursor {
            syncProjection.cursor = try? frame.cursor.serializedData()
        }
        if projectionChanged { syncStateDirty = true }
        if conversationDirectoryChanged {
            reconcileOutboxWithProjection()
        }
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
        let boardProjection = OptimisticWorkspaceProjection.reconcileBoards(global.boards, pending: pendingBoards)
        global.boards = boardProjection.boards
        pendingBoards = boardProjection.pending
        let projectProjection = OptimisticWorkspaceProjection.reconcileProjects(global.projects, pending: pendingProjects)
        global.projects = projectProjection.projects
        pendingProjects = projectProjection.pending
        let projection = OptimisticCardProjection.reconcile(
            cards: global.cards,
            moves: pendingCardMoves,
            labels: pendingCardLabelUpdates
        )
        global.cards = projection.cards
        pendingCardMoves = projection.moves
        pendingCardLabelUpdates = projection.labels
        movingCardIDs = Set(projection.moves.keys)
        labelUpdatingCardIDs = Set(projection.labels.keys)
        for card in global.cards + global.chats {
            if let previous = notificationStatuses[card.id], previous != card.runtime,
               ["review", "waiting", "completed", "failed"].contains(card.runtime.lowercased()) {
                notify(title: card.title, body: "Status changed to \(card.runtime)")
            }
            notificationStatuses[card.id] = card.runtime
        }
        let previousProjectIDs = Set(projectEndpointIDs.compactMap { $0.value == endpointID ? $0.key : nil })
        var nextProjectDirectory = projectDirectory
        var nextProjectEndpointIDs = projectEndpointIDs
        var nextNavigationBoards = navigationBoards
        var nextNavigationCards = navigationCards
        for projectID in previousProjectIDs {
            nextProjectDirectory.removeValue(forKey: projectID)
            nextProjectEndpointIDs.removeValue(forKey: projectID)
            nextNavigationBoards.removeValue(forKey: projectID)
            nextNavigationCards.removeValue(forKey: projectID)
        }
        let boardsByProject = Dictionary(grouping: global.boards, by: \.projectID)
        let cardsByProject = Dictionary(grouping: global.cards, by: \.projectID)
        for project in global.projects {
            nextProjectDirectory[project.id] = project
            nextProjectEndpointIDs[project.id] = endpointID
            nextNavigationBoards[project.id] = boardsByProject[project.id] ?? []
            nextNavigationCards[project.id] = cardsByProject[project.id] ?? []
        }
        var nextChats = chats.filter { !previousProjectIDs.contains($0.projectID) }
        nextChats.append(contentsOf: global.chats)
        nextChats = Array(nextChats.reduce(into: [String: Dieter_V1_Card]()) { $0[$1.id] = $1 }.values).sorted {
            let lhsActivity = $0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt
            let rhsActivity = $1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt
            if lhsActivity == rhsActivity { return $0.id < $1.id }
            return lhsActivity > rhsActivity
        }
        if projectDirectory != nextProjectDirectory { projectDirectory = nextProjectDirectory }
        if projectEndpointIDs != nextProjectEndpointIDs { projectEndpointIDs = nextProjectEndpointIDs }
        if navigationBoards != nextNavigationBoards { navigationBoards = nextNavigationBoards }
        if navigationCards != nextNavigationCards { navigationCards = nextNavigationCards }
        if chats != nextChats { chats = nextChats }
        let nextChatProjects = projects
        if chatProjects != nextChatProjects { chatProjects = nextChatProjects }
        updateSelectedState(base: global)
        if projectEndpointIDs[selectedProjectID] == endpointID {
            boardSettings = snapshot.settings
        }
        if let selectedID = selectedCardID ?? selectedChatID,
           snapshot.conversations.contains(where: { $0.detail.card.id == selectedID }) {
            applySelectedConversationProjection(snapshot, endpointID: endpointID)
        }
        rebuildOutboxOverlays()
    }

    func applySelectedConversationProjection(
        _ snapshot: Dieter_V1_GlobalSnapshot,
        endpointID: String
    ) {
        guard let selectedID = selectedCardID ?? selectedChatID,
              let projected = snapshot.conversations.first(where: { $0.detail.card.id == selectedID }) else { return }
        if conversation != projected { conversation = projected }
        if selectedDetail != projected.detail { selectedDetail = projected.detail }
        conversationLoading = false
        conversationLastRefreshedAt = conversationRefreshDate(cardID: selectedID, endpointID: endpointID)
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

    func projectedConversation(cardID: String, endpointID: String) -> Dieter_V1_ConversationSnapshot? {
        if endpointID == endpoint.id, let syncSnapshot {
            return syncSnapshot.conversations.first { $0.detail.card.id == cardID }
        }
        let projection = syncDiskState.projections[endpointID]
        guard let raw = projection?.snapshot,
              let snapshot = try? Dieter_V1_GlobalSnapshot(serializedBytes: raw) else { return nil }
        return snapshot.conversations.first { $0.detail.card.id == cardID }
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
           conversations.contains(where: { $0.detail.card.id == selectedID }) {
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
        pendingCardIDs = Set(syncDiskState.outbox.filter { $0.kind != .sendMessage }.map { $0.serverID ?? $0.optimisticID })
        pendingMessageIDs = Set(syncDiskState.outbox.filter { $0.kind == .sendMessage }.map(\.optimisticID))
        acceptedOutboxIDs = Set(syncDiskState.outbox.filter { $0.serverID != nil }.flatMap { [$0.optimisticID, $0.serverID!] })
        failedOutboxIDs = Set(syncDiskState.outbox.filter { $0.state == .failed }.map { $0.serverID ?? $0.optimisticID })
        machineOutboxSummaries = MachineOutboxSummary.summaries(for: syncDiskState.outbox)
        for entry in syncDiskState.outbox {
            switch entry.kind {
            case .createCard, .createChat:
                guard let request = try? Dieter_V1_CreateConversationRequest(serializedBytes: entry.request) else { continue }
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
                    if !chats.contains(where: { $0.id == card.id }) { chats.insert(card, at: 0) }
                } else if card.projectID == selectedProjectID, !state.cards.contains(where: { $0.id == card.id }) {
                    state.cards.append(card)
                    navigationCards[card.projectID, default: []].append(card)
                }
            case .sendMessage:
                guard let request = try? Dieter_V1_SendMessageRequest(serializedBytes: entry.request),
                      (selectedCardID ?? selectedChatID) == request.cardID,
                      var snapshot = conversation,
                      !snapshot.conversation.messages.contains(where: { $0.id == entry.optimisticID }) else { continue }
                var message = Dieter_V1_UiMessage()
                message.id = entry.optimisticID
                message.role = "user"
                message.parts = request.parts
                snapshot.conversation.messages.append(message)
                conversation = snapshot
            }
        }
    }

    func reconcileOutboxWithProjection() {
        guard let snapshot = syncSnapshot else { return }
        let cardIDs = Set((snapshot.state.cards + snapshot.state.chats).map(\.id))
        var conversationsToOpen: [(id: String, chat: Bool)] = []
        for index in syncDiskState.outbox.indices {
            let entry = syncDiskState.outbox[index]
            guard entry.endpointID == endpoint.id,
                  let serverID = DieterOutboxPolicy.synchronizedConversationID(
                    for: entry,
                    visibleConversationIDs: cardIDs
                  ) else { continue }
            syncDiskState.outbox[index].serverID = serverID
            try? DieterOutboxPolicy.retargetDependencies(
                in: &syncDiskState.outbox,
                from: entry.optimisticID,
                to: serverID
            )
            if retargetOptimisticConversation(from: entry.optimisticID, to: serverID) {
                conversationsToOpen.append((serverID, entry.kind == .createChat))
            }
        }
        syncDiskState.outbox.removeAll { entry in
            guard let serverID = entry.serverID else { return false }
            return entry.kind == .sendMessage || cardIDs.contains(serverID)
        }
        rebuildOutboxOverlays()
        for conversation in conversationsToOpen {
            scheduleCreatedConversationOpen(cardID: conversation.id, chat: conversation.chat)
        }
    }

    func persistAndDrainOutbox() async {
        rebuildOutboxOverlays()
        try? await saveSyncPersistence()
        startOutboxWorker()
    }

    func startOutboxWorker() {
        guard outboxTask?.isCancelled != false else { return }
        outboxTask = Task { [weak self] in
            guard let self else { return }
            defer { self.outboxTask = nil }
            while !Task.isCancelled {
                guard self.rpc != nil, self.phase.isConnected else { return }
                let reachableEndpointIDs = [self.endpoint.id] + self.endpoints
                    .filter { $0.online && $0.id != self.endpoint.id }
                    .map(\.id)
                guard let index = DieterOutboxPolicy.nextIndex(
                    in: self.syncDiskState.outbox,
                    endpointIDs: reachableEndpointIDs
                ) else {
                    guard let delay = DieterOutboxPolicy.nextRetryDelay(
                        in: self.syncDiskState.outbox,
                        endpointIDs: Set(reachableEndpointIDs)
                    ) else { return }
                    try? await DieterTaskSleep.seconds(min(0.5, max(0.05, delay)))
                    continue
                }
                var entry = self.syncDiskState.outbox[index]
                do {
                    let deliveryRPC: DieterRPC
                    var borrowedPlane: DataPlaneConnection?
                    if entry.endpointID == self.endpoint.id, let rpc = self.rpc {
                        deliveryRPC = rpc
                    } else {
                        guard let machine = self.endpoints.first(where: { $0.id == entry.endpointID }), machine.online else {
                            return
                        }
                        let plane = try await self.selectDirectoryDataPlane(for: machine)
                        self.machineConnectionStatuses[machine.id] = plane.connection
                        borrowedPlane = plane
                        deliveryRPC = plane.rpc
                    }
                    defer {
                        borrowedPlane?.task.cancel()
                        borrowedPlane?.rpc.shutdown()
                    }
                    switch entry.kind {
                    case .createCard:
                        let request = try Dieter_V1_CreateConversationRequest(serializedBytes: entry.request)
                        entry.serverID = try await deliveryRPC.createCard(request).id
                    case .createChat:
                        let request = try Dieter_V1_CreateConversationRequest(serializedBytes: entry.request)
                        entry.serverID = try await deliveryRPC.createChat(request).id
                    case .sendMessage:
                        let request = try Dieter_V1_SendMessageRequest(serializedBytes: entry.request)
                        let response = try await deliveryRPC.sendMessage(request)
                        entry.serverID = response.messageID.isEmpty ? entry.optimisticID : response.messageID
                    }
                    entry.lastError = nil
                    entry.state = .queued
                    entry.nextAttemptAt = nil
                    guard let currentIndex = self.syncDiskState.outbox.firstIndex(where: { $0.commandID == entry.commandID }) else {
                        continue
                    }
                    var shouldOpenCreatedConversation = false
                    if entry.kind == .sendMessage {
                        // SendMessage returning means the durable daemon accepted
                        // the command. Conversation content arrives on its own
                        // per-card stream, not the metadata-only global stream.
                        self.syncDiskState.outbox.remove(at: currentIndex)
                    } else {
                        self.syncDiskState.outbox[currentIndex] = entry
                        if let serverID = entry.serverID {
                            try DieterOutboxPolicy.retargetDependencies(
                                in: &self.syncDiskState.outbox,
                                from: entry.optimisticID,
                                to: serverID
                            )
                            shouldOpenCreatedConversation = self.retargetOptimisticConversation(
                                from: entry.optimisticID,
                                to: serverID
                            )
                        }
                    }
                    self.reconcileOutboxWithProjection()
                    try? await self.saveSyncPersistence()
                    if shouldOpenCreatedConversation, let serverID = entry.serverID {
                        self.scheduleCreatedConversationOpen(
                            cardID: serverID,
                            chat: entry.kind == .createChat
                        )
                    }
                } catch {
                    entry.attempts += 1
                    entry.lastError = DieterRPCFailure.message(for: error)
                    if DieterRPCFailure.isPermanent(error) {
                        entry.state = .failed
                        entry.nextAttemptAt = nil
                    } else {
                        entry.state = .retrying
                        entry.nextAttemptAt = Date().addingTimeInterval(DieterOutboxPolicy.backoff(after: entry.attempts))
                    }
                    guard let currentIndex = self.syncDiskState.outbox.firstIndex(where: { $0.commandID == entry.commandID }) else {
                        continue
                    }
                    self.syncDiskState.outbox[currentIndex] = entry
                    if entry.kind != .sendMessage {
                        self.setOptimisticConversationStatus(
                            entry,
                            status: entry.state == .failed ? "failed" : "pending"
                        )
                    }
                    self.rebuildOutboxOverlays()
                    try? await self.saveSyncPersistence()
                    let route = self.machineConnectionStatuses[entry.endpointID]?.route.rawValue ?? "Unknown"
                    outboxLogger.error(
                        "operation=\(entry.kind.rawValue, privacy: .public) card=\(entry.serverID ?? entry.optimisticID, privacy: .public) endpoint=\(entry.endpointID, privacy: .public) route=\(route, privacy: .public) status=\((error as? RPCError)?.code.description ?? "non-rpc", privacy: .public) message=\(DieterRPCFailure.message(for: error), privacy: .public) terminal=\(entry.state == .failed, privacy: .public)"
                    )
                }
            }
        }
    }

    func retryOutboxItem(_ id: String) async {
        guard let index = syncDiskState.outbox.firstIndex(where: {
            ($0.optimisticID == id || $0.serverID == id) && $0.state == .failed
        }) else { return }
        syncDiskState.outbox[index].state = .queued
        syncDiskState.outbox[index].attempts = 0
        syncDiskState.outbox[index].lastError = nil
        syncDiskState.outbox[index].nextAttemptAt = nil
        setOptimisticConversationStatus(syncDiskState.outbox[index], status: "pending")
        await persistAndDrainOutbox()
    }

    func retryOutbox(for machine: DieterEndpoint) async {
        var changed = false
        for index in syncDiskState.outbox.indices where
            syncDiskState.outbox[index].endpointID == machine.id &&
            syncDiskState.outbox[index].serverID == nil
        {
            syncDiskState.outbox[index].state = .queued
            syncDiskState.outbox[index].attempts = 0
            syncDiskState.outbox[index].lastError = nil
            syncDiskState.outbox[index].nextAttemptAt = nil
            setOptimisticConversationStatus(syncDiskState.outbox[index], status: "pending")
            changed = true
        }
        if changed {
            rebuildOutboxOverlays()
            try? await saveSyncPersistence()
        }
        await refreshDaemonPresence()
        startOutboxWorker()
        if endpoint.id == machine.id, !phase.isConnected {
            scheduleReconnect(to: machine)
        }
    }

    func discardOutboxItem(_ id: String) async {
        guard let index = syncDiskState.outbox.firstIndex(where: {
            ($0.optimisticID == id || $0.serverID == id) && $0.serverID == nil
        }) else { return }
        let entry = syncDiskState.outbox.remove(at: index)
        removeOptimisticOutboxArtifacts(for: [entry])
        rebuildOutboxOverlays()
        try? await saveSyncPersistence()
        startOutboxWorker()
    }

    @discardableResult
    func discardOutbox(for machine: DieterEndpoint) async -> Int {
        let removed = DieterOutboxPolicy.removeUndelivered(
            from: &syncDiskState.outbox,
            endpointID: machine.id
        )
        guard !removed.isEmpty else { return 0 }
        removeOptimisticOutboxArtifacts(for: removed)
        rebuildOutboxOverlays()
        try? await saveSyncPersistence()
        startOutboxWorker()
        return removed.count
    }

    func removeOptimisticOutboxArtifacts(for entries: [DieterOutboxEntry]) {
        let conversationIDs = Set(entries.lazy
            .filter { $0.kind != .sendMessage }
            .flatMap { [$0.optimisticID, $0.serverID].compactMap { $0 } })
        let messageIDs = Set(entries.lazy
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
    }

    @discardableResult
    func retargetOptimisticConversation(from optimisticID: String, to serverID: String) -> Bool {
        let selected = (selectedCardID ?? selectedChatID) == optimisticID
        let authoritative = state.cards.first(where: { $0.id == serverID })
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
        if var snapshot = conversation, snapshot.detail.card.id == optimisticID || snapshot.conversation.cardID == optimisticID {
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
        do {
            acceptState(try await rpc.state(stateRequest()))
        } catch {
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
        let boardProjection = OptimisticWorkspaceProjection.reconcileBoards(next.boards, pending: pendingBoards)
        next.boards = boardProjection.boards
        pendingBoards = boardProjection.pending
        let projectProjection = OptimisticWorkspaceProjection.reconcileProjects(next.projects, pending: pendingProjects)
        next.projects = projectProjection.projects
        pendingProjects = projectProjection.pending
        let cardProjection = OptimisticCardProjection.reconcile(
            cards: next.cards,
            moves: pendingCardMoves,
            labels: pendingCardLabelUpdates
        )
        next.cards = cardProjection.cards
        pendingCardMoves = cardProjection.moves
        pendingCardLabelUpdates = cardProjection.labels
        movingCardIDs = Set(cardProjection.moves.keys)
        labelUpdatingCardIDs = Set(cardProjection.labels.keys)
        for card in next.cards + next.chats {
            if let previous = notificationStatuses[card.id], previous != card.runtime,
               ["review", "waiting", "completed", "failed"].contains(card.runtime.lowercased()) {
                notify(title: card.title, body: "Status changed to \(card.runtime)")
            }
            notificationStatuses[card.id] = card.runtime
        }
        state = next
        if !next.project.id.isEmpty {
            navigationBoards[next.project.id] = next.boards
            navigationCards[next.project.id] = next.cards
        }
        for project in next.projects {
            projectDirectory[project.id] = project
            projectEndpointIDs[project.id] = endpoint.id
        }
        if selectedProjectID.isEmpty || !next.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = next.project.id.isEmpty ? (next.projects.first?.id ?? "") : next.project.id
        }
        if selectedBoardID.isEmpty || !next.boards.contains(where: { $0.id == selectedBoardID }) {
            selectedBoardID = next.boards.first(where: { $0.projectID == selectedProjectID })?.id ?? next.boards.first?.id ?? ""
        }
        rebuildOutboxOverlays()
    }

    func refreshNavigation() async {
        await refreshState()
    }
}
