import AppKit
import DieterAPI
import DieterClient
import DieterCore
import Foundation
import OSLog
import SharedCore

let coreSessionLogger = Logger(subsystem: "com.dbpprt.dieter.mac", category: "CoreSession")

/// The session's connection, workspace, outbox, metadata, and board state
/// come from the shared core. These folds translate its slices into the
/// values views already read; they hold no policy of their own.
extension AppSession {
    /// Starts the core once, imports the legacy state on the first launch,
    /// and subscribes to the app-wide slices.
    func startCore() async {
        if let coreStart {
            await coreStart.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.subscribeCore()
            if let summary = await self.coreHost?.start() {
                coreSessionLogger.notice("Imported the legacy app state: \(summary, privacy: .public)")
            }
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
                case .workspaceDelta(let delta):
                    var slice = self.coreWorkspace
                    slice.projects = delta.projects
                    slice.boards = delta.boards
                    slice.cards = KeyedList.apply(
                        slice.cards, upserted: delta.upsertedCards, removed: delta.removedCardIds,
                        order: delta.orderChanged ? delta.cardOrder : nil, key: \.id)
                    slice.pendingCardIds = delta.pendingCardIds
                    slice.loaded = delta.loaded
                    slice.projectReplicas = delta.projectReplicas
                    slice.retiredBoards = delta.retiredBoards
                    slice.settings = delta.settings
                    self.coreWorkspace = slice
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
                if self.activityRows != value.rows { self.activityRows = value.rows }
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
        session = slice
        let gateway = Self.gatewayEndpoint(slice)
        let origins = slice.gateways.compactMap { entry in
            DieterEndpoint.parse(entry.origin, name: entry.name.isEmpty ? "Dieter Gateway" : entry.name)
        }
        if gatewayOrigins != origins { gatewayOrigins = origins.isEmpty ? [gateway] : origins }
        let machines = slice.machines.map { Self.machineEndpoint($0, gateway: gateway) }
        if endpoints != machines { endpoints = machines }
        let attached = machines.first { !slice.attachedMachineID.isEmpty && $0.daemonID == slice.attachedMachineID }
        let next = attached ?? gateway
        if endpoint != next { endpoint = next }

        var statuses: [String: MachineConnectionStatus] = [:]
        var errors: [String: String] = [:]
        var issues: [String: String] = [:]
        for (entry, machine) in zip(slice.machines, machines) {
            if let route = Self.route(entry.route) {
                statuses[machine.id] = MachineConnectionStatus(
                    route: route, latencyMilliseconds: Int(entry.routeLatencyMillis))
            }
            if !entry.incompatibility.isEmpty { errors[machine.id] = entry.incompatibility }
            if !entry.syncWarnings.isEmpty { issues[machine.id] = entry.syncWarnings.joined(separator: "\n") }
        }
        if !slice.error.isEmpty, let attached, errors[attached.id] == nil,
            [.reconnecting, .noMachine, .updateRequired].contains(slice.phase)
        {
            errors[attached.id] = slice.error
        }
        if slice.hasGatewayBuild {
            let build = Dieter_Gateway_V1_GatewayInformation.with {
                $0.releaseVersion = slice.gatewayBuild.releaseVersion
                $0.sourceRevision = slice.gatewayBuild.sourceRevision
                $0.builtAt = slice.gatewayBuild.builtAt
            }
            if gatewayInformation[gateway.credentialID] != build { gatewayInformation[gateway.credentialID] = build }
        }
        if machineConnectionStatuses != statuses { machineConnectionStatuses = statuses }
        if machineConnectionErrors != errors { machineConnectionErrors = errors }
        if machineSyncIssues != issues { machineSyncIssues = issues }

        let nextPhase = Self.phase(slice, attached: attached, hasLoadedWorkspace: hasLoadedWorkspace)
        if phase != nextPhase { phase = nextPhase }
        let syncing =
            slice.phase == .syncing
            || (nextPhase.isConnected && (!slice.feed.live || slice.feed.projectionPending))
        if globalSyncing != syncing { globalSyncing = syncing }
        if slice.feed.lastAppliedAtMillis > 0 {
            let applied = Date(timeIntervalSince1970: Double(slice.feed.lastAppliedAtMillis) / 1_000)
            if lastSyncedAt != applied { lastSyncedAt = applied }
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

    nonisolated static func gatewayEndpoint(_ slice: ClientSessionSlice) -> DieterEndpoint {
        let name = slice.gateways.first { $0.origin == slice.gatewayOrigin }?.name ?? ""
        return DieterEndpoint.parse(slice.gatewayOrigin, name: name.isEmpty ? "Dieter Gateway" : name)
            ?? DieterEndpoint.defaults[0]
    }

    nonisolated static func machineEndpoint(_ entry: ClientMachineEntry, gateway: DieterEndpoint) -> DieterEndpoint {
        DieterEndpoint(
            name: entry.name.isEmpty ? entry.id : entry.name, host: gateway.host, port: gateway.port,
            secure: gateway.secure, daemonID: entry.id, online: entry.online, lastSeenAt: entry.lastSeenAt,
            releaseVersion: entry.releaseVersion, compatibility: compatibility(entry.compatibility),
            minimumReleaseVersion: entry.minimumReleaseVersion, remoteDesktopReady: entry.remoteDesktopReady,
            remoteDesktopReason: entry.remoteDesktopReason, remoteDesktopPlatform: entry.platform)
    }

    nonisolated static func compatibility(_ name: String) -> DieterCompatibility {
        switch name {
        case "COMPATIBILITY_STATUS_COMPATIBLE": .compatible
        case "COMPATIBILITY_STATUS_UPDATE_REQUIRED": .updateRequired
        case "COMPATIBILITY_STATUS_INVALID_VERSION": .invalidVersion
        default: .unknown
        }
    }

    nonisolated static func route(_ label: String) -> MachineConnectionRoute? {
        switch label {
        case "": nil
        case "Relay": .gateway
        default: MachineConnectionRoute(rawValue: label)
        }
    }

    nonisolated static func phase(
        _ slice: ClientSessionSlice, attached: DieterEndpoint?, hasLoadedWorkspace: Bool
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
        var summaries: [String: MachineOutboxSummary] = [:]
        for machine in slice.machines {
            summaries[endpointID(forDaemon: machine.daemonID)] = MachineOutboxSummary(
                messageCount: Int(machine.messageCount), changeCount: Int(machine.changeCount),
                retrying: machine.retrying, failed: machine.failed > 0,
                failureMessage: machine.lastError.isEmpty ? nil : machine.lastError)
        }
        if machineOutboxSummaries != summaries { machineOutboxSummaries = summaries }
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
        var catalogs: [String: Dieter_V1_HarnessCatalog] = [:]
        for (daemonID, metadata) in slice.machines where metadata.loaded {
            catalogs[endpointID(forDaemon: daemonID)] = metadata.harnesses
        }
        if harnessCatalogsByEndpoint != catalogs { harnessCatalogsByEndpoint = catalogs }
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
        var moves: [String: OptimisticCardMove] = [:]
        for move in slice.moves {
            let card = replica.navigationCards.values.lazy.compactMap { $0.first { $0.id == move.cardID } }.first
            moves[move.cardID] = OptimisticCardMove(
                operationID: pendingCardMoves[move.cardID]?.operationID ?? UUID(), lane: move.lane,
                position: card?.position ?? 0, afterCardID: move.afterCardID, beforeCardID: move.beforeCardID)
        }
        if pendingCardMoves != moves { pendingCardMoves = moves }
        var starts: [String: OptimisticCardStart] = [:]
        for (cardID, operation) in slice.operations where operation == "STARTING" {
            let card = replica.navigationCards.values.lazy.compactMap { $0.first { $0.id == cardID } }.first
            starts[cardID] =
                pendingCardStarts[cardID]
                ?? OptimisticCardStart(operationID: UUID(), runningLaneID: card?.lane ?? "running")
        }
        if pendingCardStarts != starts { pendingCardStarts = starts }
        let moving = Set(moves.keys).union(slice.operations.filter { $0.value == "MOVING" }.keys)
        if movingCardIDs != moving { movingCardIDs = moving }
        let labeling = Set(slice.operations.filter { $0.value == "LABELING" }.keys)
        if labelUpdatingCardIDs != labeling { labelUpdatingCardIDs = labeling }
    }

    /// Retries a failed or waiting outbox operation now.
    func retryOutboxItem(_ id: String) async {
        await perform { $0.retryPending = .with { $0.id = id } }
    }

    /// Retries everything waiting for `machine`.
    func retryOutbox(for machine: DieterEndpoint) async {
        guard let daemonID = machine.daemonID else { return }
        await perform { $0.retryPending = .with { $0.daemonID = daemonID } }
    }

    /// Drops an undelivered operation and anything that depends on it.
    func discardOutboxItem(_ id: String) async {
        await perform { $0.discardPending = .with { $0.id = id } }
    }

    /// Drops everything not yet delivered to `machine`; returns how many.
    @discardableResult
    func discardOutbox(for machine: DieterEndpoint) async -> Int {
        guard let daemonID = machine.daemonID else { return 0 }
        let count = machineOutboxSummaries[machine.id]?.itemCount ?? 0
        guard await perform({ $0.discardPending = .with { $0.daemonID = daemonID } }) != nil else { return 0 }
        return count
    }

    // MARK: - Creation memory

    func foldCreation(_ slice: ClientCreationSlice) {
        if creationMemory != slice { creationMemory = slice }
        quickTaskForm.adopt(slice)
    }

    /// What the core remembers from the last card or chat created on this Mac.
    var creationPreferences: ConversationCreationPreferences {
        ConversationCreationPreferences(
            provider: creationMemory.selection.provider, model: creationMemory.selection.model,
            effort: creationMemory.selection.effort,
            workspaceMode: ConversationWorkspaceMode(rawValue: creationMemory.workspaceMode) ?? .worktree)
    }

    func rememberCreation(_ preferences: ConversationCreationPreferences) {
        Task {
            await perform {
                $0.rememberCreation = .with {
                    $0.selection = .with {
                        $0.provider = preferences.provider
                        $0.model = preferences.model
                        $0.effort = preferences.effort
                    }
                    $0.workspaceMode = preferences.workspaceMode.rawValue
                }
            }
        }
    }

    /// Why a machine's agents and settings could not be read, if they could not.
    func metadataError(_ daemonID: String) -> String? {
        machineMetadata[daemonID].flatMap { $0.error.isEmpty ? nil : $0.error }
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
            try? await Task.sleep(for: .milliseconds(50))
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
        for id in directory.keys { directory[id]?.boardCount = Int32(boards[id]?.count ?? 0) }
        var cards: [String: [Dieter_V1_Card]] = [:]
        var chats: [Dieter_V1_Card] = []
        for card in slice.cards {
            if card.scope == "chat", card.boardID.isEmpty { chats.append(card) } else {
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

extension WorkspaceTarget {
    /// The daemon of a machine target (`origin#daemon`); the core addresses
    /// machines by daemon.
    var daemonID: String {
        endpointID.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }
}
