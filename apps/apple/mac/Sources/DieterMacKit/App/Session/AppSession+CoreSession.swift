import AppKit
import DieterAPI
import DieterClientAPI
import DieterCore
import DieterPlatform
import Foundation

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
                            $0.pairingCode = override.pairingCode
                        }
                    }
                } catch { self.show(error) }
            }
            // The menu bar, Island, and notifications need the live streams while
            // the app is in the background, so the Mac core always runs.
            _ = try? await self.core.dispatch { $0.setForeground = .with { $0.foreground = true } }
        }
        coreStart = task
        await task.value
    }

    private func subscribeCore() {
        guard coreSubscriptions.isEmpty else { return }
        coreSubscriptions = [
            subscribe(.session, fold: { $0.settleSession() }) { owner, update in
                guard case .session(let value) = update.value else { return false }
                owner.coreSession = value
                return true
            },
            subscribe(.workspace, fold: { if !$0.coreFoldsHeld { $0.foldWorkspace($0.coreWorkspace) } }) {
                owner, update in
                switch update.value {
                case .workspace(let value): owner.coreWorkspace = value
                case .workspaceDelta(let delta): owner.coreWorkspace = owner.coreWorkspace.applying(delta)
                default: return false
                }
                return true
            },
            subscribe(.outbox, fold: { $0.settleOutbox() }) { owner, update in
                guard case .outbox(let value) = update.value else { return false }
                owner.coreOutbox = value
                return true
            },
            subscribe(.metadata, fold: { if !$0.coreFoldsHeld { $0.foldMetadata($0.coreMetadata) } }) {
                owner, update in
                guard case .metadata(let value) = update.value else { return false }
                owner.coreMetadata = value
                return true
            },
            subscribe(.activity, fold: { if $0.activity != $0.coreActivity { $0.activity = $0.coreActivity } }) {
                owner, update in
                guard case .activity(let value) = update.value else { return false }
                owner.coreActivity = value
                return true
            },
            subscribe(.creation, fold: { $0.foldCreation($0.coreCreation) }) { owner, update in
                guard case .creation(let value) = update.value else { return false }
                owner.coreCreation = value
                return true
            },
            // Layout edits made by fixtures and other devices always apply.
            subscribe(.navigation, fold: { $0.foldNavigation($0.coreNavigation) }) { owner, update in
                guard case .navigation(let value) = update.value else { return false }
                owner.coreNavigation = value
                return true
            },
            subscribe(.board, fold: { $0.settleBoard() }) { owner, update in
                guard case .board(let value) = update.value else { return false }
                owner.coreBoard = value
                return true
            },
        ]
        boardViewModel.onChange = { [weak self] in self?.refreshBoardProjection() }
        boardViewModel.attach(core)
        channelsModel.attach(core)
        mailModel.attach(core)
    }

    /// Observes an app-wide slice. `apply` keeps each update that carries the
    /// slice (deltas fold onto the kept base at once); `fold` presents what was
    /// kept once the latest queued update is applied, so a burst presents once.
    private func subscribe(
        _ slice: ClientSlice, fold: @escaping @MainActor (AppSession) -> Void,
        apply: @escaping @MainActor (AppSession, ClientUpdate) -> Bool
    ) -> SliceSubscription {
        SliceSubscription(
            client: core, slice: slice,
            onSettled: { [weak self] in
                guard let self, self.unfoldedSlices.remove(slice) != nil else { return }
                fold(self)
            }
        ) { [weak self] update in
            guard let self, apply(self, update) else { return }
            self.unfoldedSlices.insert(slice)
        }
    }

    /// Fixtures that hold the folds still see the core's session, outbox, and
    /// board operations as they arrive.
    private func settleSession() {
        if coreFoldsHeld {
            if session != coreSession { session = coreSession }
        } else {
            foldSession(coreSession)
        }
    }

    private func settleOutbox() {
        if coreFoldsHeld {
            if outboxState != coreOutbox { outboxState = coreOutbox }
        } else {
            foldOutbox(coreOutbox)
        }
    }

    private func settleBoard() {
        if coreFoldsHeld {
            if boardState != coreBoard { boardState = coreBoard }
        } else {
            foldBoard(coreBoard)
        }
    }

    /// Applies the slices that arrived while folds were held.
    func releaseHeldFolds() {
        foldSession(session)
        foldWorkspace(coreWorkspace)
        foldOutbox(outboxState)
        foldMetadata(coreMetadata)
        foldBoard(boardState)
    }

    // MARK: - Session

    func foldSession(_ slice: ClientSessionSlice) {
        // Only a change the core reports wins over a toggle still on its way to it.
        let reasoningChanged = slice.showReasoning != session.showReasoning
        if session != slice { session = slice }
        if reasoningChanged, showReasoning != slice.showReasoning {
            foldingShowReasoning = true
            showReasoning = slice.showReasoning
            foldingShowReasoning = false
        }
        let gateway = Self.gatewayEndpoint(slice)
        let origins = slice.gateways.compactMap { entry in
            MachineEndpoint(origin: entry.origin, name: entry.name)
        }
        if gatewayOrigins != origins { gatewayOrigins = origins.isEmpty ? [gateway] : origins }
        if activeGateway != gateway { activeGateway = gateway }
        let machines = slice.machines.map { Self.machineEndpoint($0, gateway: gateway) }
        if endpoints != machines { endpoints = machines }

        var entries: [String: ClientMachineEntry] = [:]
        for (entry, machine) in zip(slice.machines, machines) { entries[machine.id] = entry }
        if machineEntries != entries { machineEntries = entries }
        let local = Set(slice.machines.filter(\.local).map(\.id))
        if localDaemonIDs != local { localDaemonIDs = local }
        if deviceNeedsPairing != slice.deviceTrust.needsPairing { deviceNeedsPairing = slice.deviceTrust.needsPairing }
        if slice.hasGatewayBuild {
            let build = Dieter_Gateway_V1_GatewayInformation.with {
                $0.releaseVersion = slice.gatewayBuild.releaseVersion
                $0.sourceRevision = slice.gatewayBuild.sourceRevision
                $0.builtAt = slice.gatewayBuild.builtAt
            }
            if gatewayInformation[gateway.credentialID] != build { gatewayInformation[gateway.credentialID] = build }
        }
        let nextPhase = Self.phase(slice, hasLoadedWorkspace: hasLoadedWorkspace)
        if phase != nextPhase { phase = nextPhase }
        if workspaceIsLive != slice.synced { workspaceIsLive = slice.synced }
        let notice = slice.hasNotice ? slice.notice : nil
        if workspaceNotice != notice { workspaceNotice = notice }
        let updated = Date(epochMillis: slice.updatedAtMillis)
        if lastSyncedAt != updated { lastSyncedAt = updated }
        requestMetadata(slice.machines)
    }

    /// Reads the agents and runtime of every machine that can take work, once
    /// per connection and again after a machine was away, as the composers,
    /// schedules, and settings of its conversations and projects need them.
    private func requestMetadata(_ entries: [ClientMachineEntry]) {
        guard phase.isConnected else { return requestedMetadata.removeAll() }
        let available = Set(entries.filter(\.available).map(\.id))
        requestedMetadata.formIntersection(available)
        for daemonID in available.subtracting(requestedMetadata).sorted() {
            requestedMetadata.insert(daemonID)
            Task { await perform { $0.ensureMetadata = .with { $0.daemonID = daemonID } } }
        }
    }

    nonisolated static func gatewayEndpoint(_ slice: ClientSessionSlice) -> MachineEndpoint {
        let name =
            slice.gateways.first { $0.origin == slice.gatewayOrigin }?.name ?? MachineEndpoint.defaultGatewayName
        return MachineEndpoint(origin: slice.gatewayOrigin, name: name) ?? MachineEndpoint.defaultGateway
    }

    nonisolated static func machineEndpoint(_ entry: ClientMachineEntry, gateway: MachineEndpoint) -> MachineEndpoint {
        MachineEndpoint(
            name: entry.name.isEmpty ? entry.id : entry.name, host: gateway.host, port: gateway.port,
            secure: gateway.secure, daemonID: entry.id, online: entry.online, lastSeenAt: entry.lastSeenAt,
            releaseVersion: entry.releaseVersion, minimumReleaseVersion: entry.minimumReleaseVersion,
            remoteDesktopReady: entry.remoteDesktopReady,
            remoteDesktopReason: entry.remoteDesktopReason, remoteDesktopPlatform: entry.platform)
    }

    nonisolated static func phase(_ slice: ClientSessionSlice, hasLoadedWorkspace: Bool) -> ConnectionPhase {
        switch slice.phase {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .reconnecting:
            // A first launch without any cached workspace reports why; later
            // interruptions keep the cached workspace and retry quietly.
            return hasLoadedWorkspace || slice.error.isEmpty ? .connecting : .failed(slice.error)
        case .connected: return .connected
        case .authRequired: return .authenticationRequired
        case .updateRequired:
            return .incompatible(slice.error.isEmpty ? slice.phaseLabel : slice.error)
        case .UNRECOGNIZED: return .disconnected
        }
    }

    // MARK: - Workspace

    func foldWorkspace(_ slice: ClientWorkspaceSlice) {
        coreWorkspace = slice
        replica.acceptCore(slice, archivedChats: archivedChats)
        refreshSelectedCard()
        if boardAttention != slice.boardAttention { boardAttention = slice.boardAttention }
        refreshPendingCards()
        let presentations = replicaPresentations
        updateSelectedState()
        // A changed selected state was presented as it was published, after
        // the replica above; only an unchanged one still needs it.
        if replicaPresentations == presentations { refreshReplicaPresentation() }
        // A project's host can change with the workspace.
        refreshLiveFlags()
        // A conversation opened before its card arrived gets its draft now.
        bindComposer()
    }

    func endpointID(forDaemon daemonID: String) -> String {
        endpoints.first { $0.daemonID == daemonID }?.id ?? "\(activeGateway.credentialID)#\(daemonID)"
    }

    // MARK: - Outbox

    func foldOutbox(_ slice: ClientOutboxSlice) {
        if outboxState != slice { outboxState = slice }
        let messages = Set(slice.pendingMessageIds)
        if pendingMessageIDs != messages { pendingMessageIDs = messages }
        let accepted = Set(slice.acceptedIds)
        if acceptedOutboxIDs != accepted { acceptedOutboxIDs = accepted }
        let failed = Set(slice.failedIds)
        if failedOutboxIDs != failed { failedOutboxIDs = failed }
        if machineOutboxes != slice.machines { machineOutboxes = slice.machines }
        if !slice.storageError.isEmpty, errorMessage == nil { errorMessage = slice.storageError }
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
            composer.retarget(conversation: local, to: server)
        }
    }

    // MARK: - Metadata and board

    func foldMetadata(_ slice: ClientMetadataSlice) {
        if machineMetadata != slice.machines { machineMetadata = slice.machines }
    }

    /// The agents `daemonID` offers; empty until its metadata arrives.
    func harnessCatalog(forDaemon daemonID: String) -> Dieter_V1_HarnessCatalog {
        machineMetadata[daemonID].flatMap { $0.loaded ? $0.harnesses : nil } ?? Dieter_V1_HarnessCatalog()
    }

    /// The agents the selected conversation's machine offers.
    var harnessCatalog: Dieter_V1_HarnessCatalog {
        harnessCatalog(forDaemon: selectedCard?.ownerDaemonID ?? selectedDetail?.card.ownerDaemonID ?? "")
    }

    func foldBoard(_ slice: ClientBoardSlice) {
        if boardState != slice { boardState = slice }
        let moving = Set(slice.moves.map(\.cardID)).union(slice.operations.filter { $0.value == "MOVING" }.keys)
        if movingCardIDs != moving { movingCardIDs = moving }
        let labeling = Set(slice.operations.filter { $0.value == "LABELING" }.keys)
        if labelUpdatingCardIDs != labeling { labelUpdatingCardIDs = labeling }
    }

    // MARK: - Board view

    /// Points the core's board view at the selected board and filters.
    func bindBoardView() {
        boardViewModel.bind(
            .with {
                $0.boardID = selectedBoardID
                $0.machineID = machineFilter
                $0.labelID = labelFilter
                $0.state = stateFilter
                $0.query = query
            })
    }

    /// Drops `cardID` into `laneID` above `beforeCardID` ("" for the lane's
    /// end), as the board view shows the lane.
    func drop(cardID: String, laneID: String, beforeCardID: String = "") async {
        boardViewModel.drop(cardID: cardID, laneID: laneID, beforeCardID: beforeCardID)
        await boardViewModel.settle()
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
    func acceptCore(_ slice: ClientWorkspaceSlice, archivedChats: [Dieter_V1_Card]) {
        var directory: [String: Dieter_V1_Project] = [:]
        for project in slice.projects { directory[project.id] = project }
        var boards: [String: [Dieter_V1_Board]] = [:]
        for board in slice.boards { boards[board.projectID, default: []].append(board) }
        var cards: [String: [Dieter_V1_Card]] = [:]
        var chats: [Dieter_V1_Card] = []
        for card in slice.cards {
            if isChat(card) {
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
        let order = slice.projects.map(\.id)
        if projectOrder != order { projectOrder = order }
        if projectHosts != slice.projectHosts { projectHosts = slice.projectHosts }
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
        return phase.isConnected && !daemonID.isEmpty && localDaemonIDs.contains(daemonID)
    }
}
