import AppKit
import DieterAPI
import Foundation
import SharedCore

/// The session's connection, workspace, outbox, metadata, and board state
/// come from the shared core. These folds translate its slices into the
/// values views already read; they hold no policy of their own.
extension AppSession {
    /// Starts the core once and subscribes to the app-wide slices.
    func startCore() async {
        if let coreStart {
            await coreStart.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.subscribeCore()
            self.coreHost?.start()
            await self.composerDrafts.load()
            self.composer.adoptSavedTexts()
            if let override = self.launchSession {
                do {
                    try await self.core.dispatch {
                        $0.adoptSession = .with {
                            $0.gatewayURL = override.gateway.address
                            $0.sessionToken = override.token
                            $0.name = override.gateway.name
                        }
                    }
                } catch { self.show(error) }
            }
            // The menu bar, Island, and notifications need the live feed while
            // the app is in the background, so the Mac core always runs.
            _ = try? await self.core.dispatch { $0.setForeground = .with { $0.foreground = true } }
        }
        coreStart = task
        await task.value
    }

    private func subscribeCore() {
        guard coreSubscriptions.isEmpty else { return }
        coreSubscriptions = [
            SliceSubscription(client: core, slice: .session) { [weak self] update in
                guard let self, case .session(let value) = update.value else { return }
                self.session = value
                if !self.coreFoldsHeld { self.foldSession(value) }
            },
            SliceSubscription(client: core, slice: .workspace) { [weak self] update in
                guard let self else { return }
                switch update.value {
                case .workspace(let value): self.coreWorkspace = value
                case .workspaceDelta(let delta): self.coreWorkspace = self.coreWorkspace.applying(delta)
                default: return
                }
                if !self.coreFoldsHeld { self.foldWorkspace(self.coreWorkspace) }
            },
            SliceSubscription(client: core, slice: .outbox) { [weak self] update in
                guard let self, case .outbox(let value) = update.value else { return }
                self.outboxState = value
                if !self.coreFoldsHeld { self.foldOutbox(value) }
            },
            SliceSubscription(client: core, slice: .metadata) { [weak self] update in
                guard let self, case .metadata(let value) = update.value else { return }
                self.machineMetadata = value.machines
                if !self.coreFoldsHeld { self.foldMetadata(value) }
            },
            SliceSubscription(client: core, slice: .activity) { [weak self] update in
                guard let self, case .activity(let value) = update.value else { return }
                if self.activity != value { self.activity = value }
            },
            SliceSubscription(client: core, slice: .creation) { [weak self] update in
                guard let self, case .creation(let value) = update.value else { return }
                self.foldCreation(value)
            },
            // Layout edits made by fixtures and other devices always apply.
            SliceSubscription(client: core, slice: .navigation) { [weak self] update in
                guard let self, case .navigation(let value) = update.value else { return }
                self.foldNavigation(value)
            },
            SliceSubscription(client: core, slice: .board) { [weak self] update in
                guard let self, case .board(let value) = update.value else { return }
                self.boardState = value
                if !self.coreFoldsHeld { self.foldBoard(value) }
            },
            SliceSubscription(client: core, slice: .boardView, scope: Self.boardViewScope) { [weak self] update in
                guard let self, case .boardView(let value) = update.value else { return }
                self.foldBoardView(value)
            },
        ]
    }

    /// Applies the slices that arrived while folds were held.
    func releaseHeldFolds() {
        foldSession(session)
        foldWorkspace(coreWorkspace)
        foldOutbox(outboxState)
        foldMetadata(.with { $0.machines = machineMetadata })
        foldBoard(boardState)
    }

    // MARK: - Session

    func foldSession(_ slice: ClientSessionSlice) {
        // Only a change the core reports wins over a toggle still on its way to it.
        let reasoningChanged = slice.showReasoning != session.showReasoning
        session = slice
        if reasoningChanged, showReasoning != slice.showReasoning {
            foldingShowReasoning = true
            showReasoning = slice.showReasoning
            foldingShowReasoning = false
        }
        let gateway = Self.gatewayEndpoint(slice)
        let origins = slice.gateways.compactMap { entry in
            MachineEndpoint(origin: entry.origin, name: entry.name.isEmpty ? "Dieter Gateway" : entry.name)
        }
        if gatewayOrigins != origins { gatewayOrigins = origins.isEmpty ? [gateway] : origins }
        let machines = slice.machines.map { Self.machineEndpoint($0, gateway: gateway) }
        if endpoints != machines { endpoints = machines }
        let attached = machines.first { !slice.attachedMachineID.isEmpty && $0.daemonID == slice.attachedMachineID }
        let next = attached ?? gateway
        if endpoint != next { endpoint = next }

        var entries: [String: ClientMachineEntry] = [:]
        for (entry, machine) in zip(slice.machines, machines) { entries[machine.id] = entry }
        if machineEntries != entries { machineEntries = entries }
        if slice.hasGatewayBuild {
            let build = Dieter_Gateway_V1_GatewayInformation.with {
                $0.releaseVersion = slice.gatewayBuild.releaseVersion
                $0.sourceRevision = slice.gatewayBuild.sourceRevision
                $0.builtAt = slice.gatewayBuild.builtAt
            }
            if gatewayInformation[gateway.credentialID] != build { gatewayInformation[gateway.credentialID] = build }
        }
        let nextPhase = Self.phase(slice, attached: attached, hasLoadedWorkspace: hasLoadedWorkspace)
        if phase != nextPhase { phase = nextPhase }
        if workspaceIsLive != slice.workspaceLive { workspaceIsLive = slice.workspaceLive }
        let notice = slice.hasNotice ? slice.notice : nil
        if workspaceNotice != notice { workspaceNotice = notice }
        if let applied = Date(epochMillis: slice.feed.lastAppliedAtMillis), lastSyncedAt != applied {
            lastSyncedAt = applied
        }
        let connected = nextPhase.isConnected ? attached?.id : nil
        if connectedMachineID != connected { connectedMachineID = connected }
        // The attached machine's agents, settings choices, and runtime are
        // read once it is connected, as the composer and settings need them.
        if !nextPhase.isConnected { requestedMetadata = nil }
        if nextPhase.isConnected, let daemonID = attached?.daemonID, requestedMetadata != daemonID {
            requestedMetadata = daemonID
            Task { await perform { $0.ensureMetadata = .with { $0.daemonID = daemonID } } }
        }
        coreSessionChanged()
    }

    nonisolated static func gatewayEndpoint(_ slice: ClientSessionSlice) -> MachineEndpoint {
        let name = slice.gateways.first { $0.origin == slice.gatewayOrigin }?.name ?? ""
        return MachineEndpoint(origin: slice.gatewayOrigin, name: name.isEmpty ? "Dieter Gateway" : name)
            ?? MachineEndpoint.defaultGateway
    }

    nonisolated static func machineEndpoint(_ entry: ClientMachineEntry, gateway: MachineEndpoint) -> MachineEndpoint {
        MachineEndpoint(
            name: entry.name.isEmpty ? entry.id : entry.name, host: gateway.host, port: gateway.port,
            secure: gateway.secure, daemonID: entry.id, online: entry.online, lastSeenAt: entry.lastSeenAt,
            releaseVersion: entry.releaseVersion, minimumReleaseVersion: entry.minimumReleaseVersion,
            remoteDesktopReady: entry.remoteDesktopReady,
            remoteDesktopReason: entry.remoteDesktopReason, remoteDesktopPlatform: entry.platform)
    }

    nonisolated static func phase(
        _ slice: ClientSessionSlice, attached: MachineEndpoint?, hasLoadedWorkspace: Bool
    ) -> ConnectionPhase {
        switch slice.phase {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .reconnecting:
            // A first launch without any cached workspace reports why; later
            // interruptions keep the cached workspace and retry quietly.
            return hasLoadedWorkspace || slice.error.isEmpty ? .connecting : .failed(slice.error)
        case .syncing, .connected: return .connected(version: attached?.releaseVersion ?? "")
        case .noMachine:
            return .failed(slice.error.isEmpty ? "No enrolled Dieter machines are online." : slice.error)
        case .authRequired: return .authenticationRequired
        case .updateRequired:
            let found = attached?.minimumReleaseVersion ?? ""
            return .incompatible(found: found.isEmpty ? slice.error : found)
        case .UNRECOGNIZED: return .disconnected
        }
    }

    // MARK: - Workspace

    func foldWorkspace(_ slice: ClientWorkspaceSlice) {
        coreWorkspace = slice
        let replicas = slice.projectReplicas.mapValues { daemonID in endpointID(forDaemon: daemonID) }
        replica.acceptCore(slice, replicaEndpointIDs: replicas, archivedChats: archivedChats)
        if boardSettings != slice.settings { boardSettings = slice.settings }
        if boardAttention != slice.boardAttention { boardAttention = slice.boardAttention }
        refreshPendingCards()
        updateSelectedState()
        refreshReplicaPresentation()
    }

    func endpointID(forDaemon daemonID: String) -> String {
        endpoints.first { $0.daemonID == daemonID }?.id ?? "\(activeGateway.credentialID)#\(daemonID)"
    }

    // MARK: - Outbox

    func foldOutbox(_ slice: ClientOutboxSlice) {
        outboxState = slice
        let messages = Set(slice.pendingMessageIds)
        if pendingMessageIDs != messages { pendingMessageIDs = messages }
        let accepted = Set(slice.acceptedIds)
        if acceptedOutboxIDs != accepted { acceptedOutboxIDs = accepted }
        let failed = Set(slice.failedIds)
        if failedOutboxIDs != failed { failedOutboxIDs = failed }
        if machineOutboxes != slice.machines { machineOutboxes = slice.machines }
        if !slice.storageError.isEmpty, errorMessage == nil {
            errorMessage = "Could not save pending changes: \(slice.storageError)"
        }
        refreshPendingCards()
        followResolutions(slice.resolutions)
    }

    private func refreshPendingCards() {
        let pending = Set(coreWorkspace.pendingCardIds).union(outboxState.pendingCardIds)
        if pendingCardIDs != pending { pendingCardIDs = pending }
    }

    /// A conversation created on this Mac is selected under its local ID until
    /// the machine accepts it; then the selection follows the server ID.
    private func followResolutions(_ resolutions: [String: String]) {
        for (local, server) in resolutions where local != server {
            if selectedCardID == local { selectedCardID = server }
            if selectedChatID == local { selectedChatID = server }
            if lastUsedChatID == local { lastUsedChatID = server }
            composer.retarget(
                from: WorkspaceTarget(endpointID: endpoint.id, projectID: "", conversationID: local),
                to: WorkspaceTarget(endpointID: endpoint.id, projectID: "", conversationID: server))
        }
    }

    // MARK: - Metadata and board

    func foldMetadata(_ slice: ClientMetadataSlice) {
        machineMetadata = slice.machines
        let attached = endpoint.daemonID.flatMap { slice.machines[$0] }
        let catalog = attached?.harnesses ?? Dieter_V1_HarnessCatalog()
        if harnessCatalog != catalog { harnessCatalog = catalog }
        let options = attached?.settingsOptions ?? Dieter_V1_SettingsOptions()
        if settingsOptions != options { settingsOptions = options }
        let status = attached?.runtime ?? Dieter_V1_RuntimeStatus()
        if runtime != status { runtime = status }
    }

    func foldBoard(_ slice: ClientBoardSlice) {
        boardState = slice
        let moving = Set(slice.moves.map(\.cardID)).union(slice.operations.filter { $0.value == "MOVING" }.keys)
        if movingCardIDs != moving { movingCardIDs = moving }
        let labeling = Set(slice.operations.filter { $0.value == "LABELING" }.keys)
        if labelUpdatingCardIDs != labeling { labelUpdatingCardIDs = labeling }
    }

    // MARK: - Board view

    /// The scope of the core's view of the selected board.
    static let boardViewScope = "mac-board"

    /// Points the core's board view at the selected board and filters.
    func bindBoardView() {
        let target = ClientBoardViewTarget.with {
            $0.boardID = selectedBoardID
            $0.machineID = machineFilter
            $0.labelID = labelFilter
            $0.state = stateFilter
            $0.query = query
        }
        guard target != boardViewTarget else { return }
        boardViewTarget = target
        guard !target.boardID.isEmpty else { return }
        let core = core
        Task {
            _ = try? await core.dispatch(
                .with {
                    $0.boardView = .with {
                        $0.scope = Self.boardViewScope
                        $0.bind = target
                    }
                })
        }
    }

    /// The core's view of the board the Mac shows; a view of another board is stale.
    func foldBoardView(_ slice: ClientBoardViewSlice) {
        guard slice.target.boardID == boardViewTarget.boardID else { return }
        boardView = slice
        refreshBoardProjection()
    }

    /// Drops `cardID` into `laneID` above `beforeCardID` ("" for the lane's
    /// end), as the board view shows the lane.
    func drop(cardID: String, laneID: String, beforeCardID: String = "") async {
        await perform {
            $0.boardView = .with {
                $0.scope = Self.boardViewScope
                $0.drop = .with {
                    $0.cardID = cardID
                    $0.laneID = laneID
                    $0.beforeCardID = beforeCardID
                }
            }
        }
    }

    /// Retries a failed or waiting outbox operation now.
    func retryOutboxItem(_ id: String) async {
        await perform { $0.retryPending = .with { $0.id = id } }
    }

    /// Retries everything waiting for a machine's daemon.
    func retryOutbox(daemonID: String) async {
        await perform { $0.retryPending = .with { $0.daemonID = daemonID } }
    }

    /// Drops an undelivered operation and anything that depends on it.
    func discardOutboxItem(_ id: String) async {
        await perform { $0.discardPending = .with { $0.id = id } }
    }

    /// Drops everything not yet delivered to a machine's daemon.
    func discardOutbox(daemonID: String) async {
        await perform { $0.discardPending = .with { $0.daemonID = daemonID } }
    }

    // MARK: - Creation memory

    func foldCreation(_ slice: ClientCreationSlice) {
        if creationMemory != slice { creationMemory = slice }
        quickTaskForm.adopt(slice)
    }

    /// Values derived from the session that views read directly.
    private func coreSessionChanged() {
        var health = Dieter_V1_HealthResponse()
        if phase.isConnected {
            health.status = "ok"
            health.releaseVersion = endpoint.releaseVersion
        }
        if self.health != health { self.health = health }
    }

    // MARK: - Commands

    /// Runs `build` on the core and reports its failure; nil on failure.
    @discardableResult
    func perform(_ build: (inout ClientCommand) -> Void) async -> ClientResult? {
        var command = ClientCommand()
        build(&command)
        do {
            return try await core.dispatch(command)
        } catch {
            show(error)
            return nil
        }
    }

    /// Waits until `condition` holds or `timeout` elapses.
    func awaitCore(timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            try? await DieterTaskSleep.milliseconds(50)
        }
        return true
    }
}

extension WorkspaceReplica {
    /// Replaces the replica with the core's merged, optimistic workspace.
    /// `archivedChats` are listed separately; live chats come from the core.
    func acceptCore(
        _ slice: ClientWorkspaceSlice, replicaEndpointIDs: [String: String], archivedChats: [Dieter_V1_Card]
    ) {
        var directory: [String: Dieter_V1_Project] = [:]
        for project in slice.projects { directory[project.id] = project }
        var boards: [String: [Dieter_V1_Board]] = [:]
        for board in slice.boards { boards[board.projectID, default: []].append(board) }
        var cards: [String: [Dieter_V1_Card]] = [:]
        var chats: [Dieter_V1_Card] = []
        for card in slice.cards {
            if card.scope == "chat", card.boardID.isEmpty {
                chats.append(card)
            } else {
                cards[card.projectID, default: []].append(card)
            }
        }
        let live = Set(chats.map(\.id))
        chats += archivedChats.filter { !live.contains($0.id) }
        let retired = Dictionary(slice.retiredBoards.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if retiredBoards != retired { retiredBoards = retired }
        if projectDirectory != directory { projectDirectory = directory }
        if projectReplicaEndpointIDs != replicaEndpointIDs { projectReplicaEndpointIDs = replicaEndpointIDs }
        if navigationBoards != boards { navigationBoards = boards }
        if navigationCards != cards { navigationCards = cards }
        if self.chats != chats { self.chats = chats }
        if chatProjects != projects { chatProjects = projects }
    }
}

extension AppSession {
    /// Whether `endpointID` is this Mac's own daemon, reached over loopback,
    /// so its workspace paths open locally (the core reports the route).
    func isLocalMachine(_ endpointID: String) -> Bool {
        let daemonID = WorkspaceTarget(endpointID: endpointID, projectID: "").daemonID
        return phase.isConnected && !daemonID.isEmpty
            && session.machines.contains { $0.id == daemonID && $0.local }
    }
}
