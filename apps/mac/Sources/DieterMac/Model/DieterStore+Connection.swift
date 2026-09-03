import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func connect(to newEndpoint: DieterEndpoint? = nil, automatic: Bool = false) async {
        if let syncRestoreTask {
            await syncRestoreTask.value
            self.syncRestoreTask = nil
        }
        if !automatic { reconnectTask?.cancel(); reconnectTask = nil }
        let requested = newEndpoint ?? endpoint
        let preferredDaemonID = requested.daemonID ?? (requested.credentialID == endpoint.credentialID ? endpoint.daemonID : nil)
        let origin = gatewayOrigins.first(where: { $0.credentialID == requested.credentialID }) ?? requested.gatewayEndpoint
        connectionGeneration &+= 1
        let generation = connectionGeneration
        phase = .connecting
        stateTask?.cancel(); conversationTask?.cancel(); gitOperationTask?.cancel(); terminalWatchTask?.cancel(); syncTask?.cancel(); syncLivenessTask?.cancel(); outboxTask?.cancel(); connectionTask?.cancel(); directRefreshTask?.cancel(); machineDirectoryTask?.cancel(); machinePresenceLeaseTask?.cancel(); machineTelemetryTask?.cancel()
        startMachinePresenceLeaseMonitor()
        terminalStreamConnected = false
        rpc?.shutdown()
        rpc = nil
        connectionTask = nil
        var gatewayRPC: DieterRPC?
        var gatewayTask: Task<Void, Never>?
        var gatewayAuthenticated = false
        do {
            let accessToken = await accessToken(for: origin)
            let control = try DieterRPC(endpoint: origin, accessToken: accessToken)
            gatewayRPC = control
            gatewayTask = Task { try? await control.run() }
            let daemonDirectory = try await control.daemons()
            guard ConnectionAttemptOwnership.mayMutateSharedState(
                attemptGeneration: generation,
                currentGeneration: connectionGeneration
            ) else {
                gatewayTask?.cancel()
                control.shutdown()
                return
            }
            gatewayAuthenticated = true
            let discovered = daemonDirectory.daemons.map {
                DieterEndpoint(
                    name: $0.name.isEmpty ? $0.id : $0.name,
                    host: origin.host,
                    port: origin.port,
                    secure: origin.secure,
                    daemonID: $0.id,
                    online: MachinePresenceText.online(serverOnline: $0.online, lastSeenAt: $0.lastSeenAt),
                    lastSeenAt: $0.lastSeenAt,
					version: $0.version,
					remoteDesktopReady: $0.remoteDesktop.ready,
					remoteDesktopReason: $0.remoteDesktop.reason,
					remoteDesktopPlatform: $0.remoteDesktop.platform
                )
            }
            guard !discovered.isEmpty else {
                throw NSError(domain: "DieterGateway", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Dieter daemons are enrolled for this account."])
            }
            endpoints = discovered
            let target = MachineRoutingPolicy.automaticConnectionTarget(
                from: discovered,
                preferredDaemonID: preferredDaemonID
            )
            guard let target else {
                throw NSError(domain: "DieterGateway", code: 3, userInfo: [NSLocalizedDescriptionKey: "No enrolled Dieter machines are online."])
            }

            let dataPlane = try await selectDataPlane(
                gateway: control,
                target: target,
                gatewayAccessToken: accessToken
            )
            guard ConnectionAttemptOwnership.mayMutateSharedState(
                attemptGeneration: generation,
                currentGeneration: connectionGeneration
            ) else {
                dataPlane.task.cancel()
                dataPlane.rpc.shutdown()
                gatewayTask?.cancel()
                control.shutdown()
                return
            }
            gatewayTask?.cancel()
            control.shutdown()
            gatewayTask = nil
            gatewayRPC = nil

            rpc = dataPlane.rpc
            connectionTask = dataPlane.task
            machineConnectionStatuses[target.id] = dataPlane.connection
            if let expiresAt = dataPlane.directTokenExpiresAt {
                scheduleDirectRefresh(expiresAt: expiresAt, target: target)
            }
            try? await saveSyncPersistence()
            guard ConnectionAttemptOwnership.mayMutateSharedState(
                attemptGeneration: generation,
                currentGeneration: connectionGeneration
            ) else {
                dataPlane.task.cancel()
                dataPlane.rpc.shutdown()
                return
            }
            endpoint = target
            activateSyncProjection(for: target)
            persistEndpoints()
            // Do not use `async let` in this throwing `do` scope. Swift 6.1–6.3 can
            // destroy failed child tasks out of allocation order (Swift #81771),
            // aborting the process while a gRPC connection is unwinding. Explicit
            // tasks preserve parallel loading without using async-let stack storage.
            let healthTask = Task { try await dataPlane.rpc.health() }
            let runtimeTask = Task { try await dataPlane.rpc.runtimeStatus() }
            let stateTask = Task { try await dataPlane.rpc.state() }
            let harnessesTask = Task { try await dataPlane.rpc.harnesses() }
            let settingsTask = Task { try await dataPlane.rpc.settings() }
            let optionsTask = Task { try await dataPlane.rpc.settingsOptions() }
            defer {
                healthTask.cancel()
                runtimeTask.cancel()
                stateTask.cancel()
                harnessesTask.cancel()
                settingsTask.cancel()
                optionsTask.cancel()
            }
            let initialHealth = try await healthTask.value
            guard initialHealth.status == "ok", initialHealth.version == dieterExpectedAPIVersion else {
                throw DieterStoreConnectionError.incompatible(found: initialHealth.version)
            }
            let initialRuntime = try await runtimeTask.value
            let initialState = try await stateTask.value
            let initialHarnesses = try await harnessesTask.value
            let initialSettings = try await settingsTask.value
            let initialOptions = try await optionsTask.value
            guard ConnectionAttemptOwnership.mayMutateSharedState(
                attemptGeneration: generation,
                currentGeneration: connectionGeneration
            ) else {
                dataPlane.task.cancel()
                dataPlane.rpc.shutdown()
                return
            }
            self.health = initialHealth
            self.runtime = initialRuntime
            acceptState(initialState)
            self.harnessCatalog = initialHarnesses
            self.boardSettings = initialSettings
            self.settingsOptions = initialOptions
            phase = .connected(version: initialHealth.version)
            startGlobalSync()
            startSyncLivenessMonitor()
            startOutboxWorker()
            // The selected machine is live as soon as WatchSync starts.
            // Refreshing auxiliary machines must not hold this connect attempt
            // (and its reconnect task) open on an unrelated half-open RPC.
            startMachineDirectoryRefresh(refreshImmediately: true)
            if section == .terminals { await loadTerminals() }
        } catch {
            gatewayTask?.cancel()
            gatewayRPC?.shutdown()
            guard ConnectionAttemptOwnership.mayMutateSharedState(
                attemptGeneration: generation,
                currentGeneration: connectionGeneration
            ) else {
                connectionLogger.debug("Ignoring failed stale connection attempt generation \(generation, privacy: .public)")
                return
            }
            connectionTask?.cancel()
            connectionTask = nil
            rpc?.shutdown()
            rpc = nil
            if let connectionError = error as? DieterStoreConnectionError,
               case let .incompatible(found) = connectionError {
                phase = .incompatible(found: found)
                errorMessage = error.localizedDescription
                return
            }
            if !gatewayAuthenticated, let rpcError = error as? RPCError, rpcError.code == .unauthenticated {
                phase = .authenticationRequired
                errorMessage = nil
                return
            }
            if hasLoadedWorkspace {
                phase = .connecting
                scheduleReconnect(to: requested)
            } else {
                phase = .failed(error.localizedDescription)
                // The connection overlay already presents startup failures in
                // context. Do not duplicate expected offline state as a modal.
                errorMessage = nil
            }
        }
    }

    func selectDataPlane(
        gateway: DieterRPC,
        target: DieterEndpoint,
        gatewayAccessToken: String?,
        directCandidateScope: DirectCandidateScope = .all,
        refreshDirectToken: Bool = true
    ) async throws -> DataPlaneConnection {
        guard let daemonID = target.daemonID else {
            throw NSError(domain: "DieterGateway", code: 5, userInfo: [NSLocalizedDescriptionKey: "No routed Dieter machine is available."])
        }
        let route = try await gateway.route(daemonID: daemonID)
        let directCandidates = directCandidateScope.ordered(route.directCandidates)
        if !directCandidates.isEmpty {
            let token = try await gateway.daemonAccessToken(daemonID: daemonID)
            guard token.tokenType == "Bearer" else {
                throw NSError(domain: "DieterGateway", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gateway returned an unsupported daemon token."])
            }
            for candidate in directCandidates {
                do {
                    let direct = try DieterRPC(
                        endpoint: target,
                        direct: .init(
                            host: candidate.host,
                            port: Int(candidate.port),
                            daemonID: daemonID,
                            daemonCAPEM: route.daemonCaPem,
                            accessToken: token.accessToken
                        )
                    )
                    let directTask = startConnectionTask(for: direct)
                    let started = Date()
                    do {
                        _ = try await direct.health(timeout: .seconds(2))
                        return DataPlaneConnection(
                            rpc: direct,
                            task: directTask,
                            connection: .init(route: .local, latencyMilliseconds: Self.latencyMilliseconds(since: started)),
                            directTokenExpiresAt: refreshDirectToken ? token.expiresAt : nil
                        )
                    } catch {
                        connectionLogger.debug(
                            "Direct candidate \(candidate.id, privacy: .public) for \(daemonID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                        )
                        directTask.cancel()
                        direct.shutdown()
                    }
                } catch {
                    connectionLogger.debug(
                        "Direct candidate \(candidate.id, privacy: .public) for \(daemonID, privacy: .public) could not start: \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
            }
        }
        guard route.relayAvailable else {
            throw NSError(domain: "DieterGateway", code: 3, userInfo: [NSLocalizedDescriptionKey: "This Dieter daemon is offline."])
        }
        let relay = try DieterRPC(endpoint: target, accessToken: gatewayAccessToken, route: .relay(daemonID: daemonID))
        let relayTask = startConnectionTask(for: relay)
        do {
            let started = Date()
            _ = try await relay.health(timeout: .seconds(5))
            return DataPlaneConnection(
                rpc: relay,
                task: relayTask,
                connection: .init(route: .gateway, latencyMilliseconds: Self.latencyMilliseconds(since: started)),
                directTokenExpiresAt: nil
            )
        } catch {
            relayTask.cancel()
            relay.shutdown()
            throw error
        }
    }

	func remoteDesktopConnection(machineID: String) async throws -> RemoteDesktopSignalingConnection {
		guard let target = machines.first(where: { $0.id == machineID }) ?? (endpoint.id == machineID ? endpoint : nil),
			  let daemonID = target.daemonID else {
			throw NSError(domain: "DieterScreens", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select an enrolled Dieter machine."])
		}
		guard target.online else {
			throw NSError(domain: "DieterScreens", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."])
		}
		let origin = gatewayOrigins.first(where: { $0.credentialID == target.credentialID }) ?? target.gatewayEndpoint
		let gatewayToken = await accessToken(for: origin)
		let gateway = try DieterRPC(endpoint: origin, accessToken: gatewayToken)
		let gatewayTask = Task { try? await gateway.run() }
		defer {
			gatewayTask.cancel()
			gateway.shutdown()
		}
		let route = try await gateway.route(daemonID: daemonID)
		let rtcConfiguration = try await gateway.rtcConfiguration(daemonID: daemonID)

		if !route.directCandidates.isEmpty {
			let token = try await gateway.daemonAccessToken(daemonID: daemonID)
			guard token.tokenType == "Bearer" else {
				throw NSError(domain: "DieterScreens", code: 3, userInfo: [NSLocalizedDescriptionKey: "Gateway returned an unsupported daemon token."])
			}
			for candidate in route.directCandidates.sorted(by: { $0.priority > $1.priority }) {
				do {
					let direct = try DieterRPC(
						endpoint: target,
						direct: .init(
							host: candidate.host, port: Int(candidate.port), daemonID: daemonID,
							daemonCAPEM: route.daemonCaPem, accessToken: token.accessToken
						)
					)
					let runner = Task { _ = try? await direct.run() }
					do {
						_ = try await direct.health(timeout: .seconds(2))
						return RemoteDesktopSignalingConnection(
							rpc: direct, connectionTask: runner, rtcConfiguration: rtcConfiguration,
							daemonCertificatePEM: route.daemonCertificatePem, routeLabel: "Direct"
						)
					} catch {
						runner.cancel()
						direct.shutdown()
					}
				} catch {
					continue
				}
			}
		}

		guard route.relayAvailable else {
			throw NSError(domain: "DieterScreens", code: 4, userInfo: [NSLocalizedDescriptionKey: "This Dieter daemon is offline."])
		}
		let relay = try DieterRPC(endpoint: target, accessToken: gatewayToken, route: .relay(daemonID: daemonID))
		let runner = Task { _ = try? await relay.run() }
		do {
			_ = try await relay.health(timeout: .seconds(5))
			return RemoteDesktopSignalingConnection(
				rpc: relay, connectionTask: runner, rtcConfiguration: rtcConfiguration,
				daemonCertificatePEM: route.daemonCertificatePem, routeLabel: "Gateway"
			)
		} catch {
			runner.cancel()
			relay.shutdown()
			throw error
		}
	}

    func startConnectionTask(for client: DieterRPC) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await client.run()
                if !Task.isCancelled {
                    self?.connectionStopped(
                        NSError(domain: "DieterTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Dieter connection closed."]),
                        client: client
                    )
                }
            }
            catch where Self.isExpectedCancellation(error) { }
            catch { self?.connectionStopped(error, client: client) }
        }
    }

    func scheduleDirectRefresh(expiresAt: String, target: DieterEndpoint) {
        let expires = DieterTimestamp.date(from: expiresAt)
        guard let expires else { return }
        let delay = max(1, expires.timeIntervalSinceNow - 30)
        directRefreshTask?.cancel()
        directRefreshTask = Task { [weak self] in
            try? await DieterTaskSleep.seconds(delay)
            guard !Task.isCancelled, let self else { return }
            // Do not let connect(to:) cancel the task that is currently
            // performing the scheduled token refresh.
            self.directRefreshTask = nil
            await self.connect(to: target, automatic: true)
        }
    }

    func signIn() async {
        do {
            let origin = gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) ?? endpoint.gatewayEndpoint
            _ = try await authentication.signIn(to: origin)
            await connect(to: endpoint)
        } catch {
            errorMessage = "Could not sign in: \(error.localizedDescription)"
        }
    }

    func completeAuthentication(url: URL) {
        guard !authentication.complete(url: url) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let endpoint = try await self.authentication.resumePending(url: url) else { return }
                await self.connect(to: endpoint)
            } catch {
                self.errorMessage = "Could not finish sign-in: \(error.localizedDescription)"
            }
        }
    }

    func signOut() async {
        await DieterCredentialStore.remove(for: endpoint)
        disconnect()
        phase = endpoint.secure ? .authenticationRequired : .disconnected
    }

    func connectionStopped(_ error: Error, client: DieterRPC) {
        guard !Task.isCancelled else { return }
        guard rpc === client else { return }
        guard hasLoadedWorkspace else {
            phase = .failed(error.localizedDescription)
            return
        }
        // A lost daemon is connectivity state, not an application error. Keep
        // the cached projection visible and let the workspace badge report the
        // interruption while the normal reconnect loop rebuilds the streams.
        errorMessage = nil
        phase = .connecting
        scheduleReconnect(to: endpoint)
    }

    func scheduleReconnect(to target: DieterEndpoint) {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled, let self {
                try? await DieterTaskSleep.seconds(delay)
                guard !Task.isCancelled else { return }
                await self.connect(to: target, automatic: true)
                if self.phase.isConnected {
                    self.reconnectTask = nil
                    return
                }
                delay = min(15, delay * 1.8)
            }
        }
    }

    func disconnect() {
        connectionGeneration &+= 1
        stateTask?.cancel(); conversationTask?.cancel(); gitOperationTask?.cancel(); terminalWatchTask?.cancel(); syncTask?.cancel(); syncLivenessTask?.cancel(); outboxTask?.cancel(); connectionTask?.cancel(); directRefreshTask?.cancel(); machineDirectoryTask?.cancel(); machinePresenceLeaseTask?.cancel(); machineTelemetryTask?.cancel(); reconnectTask?.cancel()
        reconnectTask = nil
        terminalStreamConnected = false
        rpc?.shutdown(); rpc = nil
        lastSyncFrameAt = nil
        globalSyncing = false
        endpoints = endpoints.map { machine in
            var machine = machine
            if machine.daemonID != nil { machine.online = false }
            return machine
        }
        phase = .disconnected
    }

    func cleanSync() async {
        let gateway = activeGateway
        disconnect()
        syncDiskState.clearProjections()
        syncProjection = .empty
        syncSnapshot = nil
        syncStateDirty = false
        clearDeploymentWorkspace()
        do {
            try await syncPersistence.save(syncDiskState)
        } catch {
            show(error)
            return
        }
        await connect(to: gateway)
    }

    func chooseGateway(_ gateway: DieterEndpoint) async {
        guard gateway.daemonID == nil else { return }
        if !gatewayOrigins.contains(where: { $0.credentialID == gateway.credentialID }) {
            gatewayOrigins.append(gateway)
        }
        if gateway.credentialID != activeGateway.credentialID {
            if syncStateDirty { try? await saveSyncPersistence() }
            clearDeploymentWorkspace()
        }
        endpoint = gateway
        await connect(to: gateway)
    }

    func saveEndpoint(_ endpoint: DieterEndpoint) async {
        if let index = gatewayOrigins.firstIndex(where: { $0.credentialID == endpoint.credentialID || $0.name == endpoint.name }) {
            gatewayOrigins[index] = endpoint
        } else {
            gatewayOrigins.append(endpoint)
        }
        if endpoint.credentialID != activeGateway.credentialID {
            if syncStateDirty { try? await saveSyncPersistence() }
            clearDeploymentWorkspace()
        }
        persistEndpoints()
        await connect(to: endpoint)
    }

    func clearDeploymentWorkspace() {
        state = Dieter_V1_State()
        projectDirectory.removeAll()
        projectEndpointIDs.removeAll()
        navigationBoards.removeAll()
        navigationCards.removeAll()
        chats.removeAll()
        chatProjects.removeAll()
        schedules.removeAll()
        scheduleRuns.removeAll()
        schedulesLoading = false
        schedulesLoadingMore = false
        scheduleRunsLoading = false
        scheduleRunsLoadingMore = false
        schedulesTotalCount = 0
        schedulesNextPageToken = ""
        scheduleRunsNextPageToken = ""
        schedulesLoadedProjectID = ""
        schedulesLoadedEndpointID = ""
        schedulesRequestGeneration &+= 1
        scheduleRunsRequestGeneration &+= 1
        selectedProjectID = ""
        selectedBoardID = ""
        closeConversation()
        syncProjection = .empty
        syncSnapshot = nil
        syncStateDirty = false
    }

    func deleteEndpoint(_ endpoint: DieterEndpoint) {
        guard endpoint.daemonID == nil, gatewayOrigins.count > 1 else { return }
        gatewayOrigins.removeAll { $0.credentialID == endpoint.credentialID }
        persistEndpoints()
    }

    func revokeDaemon(_ endpoint: DieterEndpoint) async {
        guard let daemonID = endpoint.daemonID, let rpc else { return }
        do {
            try await rpc.revokeDaemon(daemonID: daemonID)
            endpoints.removeAll { $0.daemonID == daemonID }
            projectEndpointIDs = projectEndpointIDs.filter { $0.value != endpoint.id }
            projectDirectory = projectDirectory.filter { projectEndpointIDs[$0.key] != nil }
            persistEndpoints()
            await connect(to: endpoints.first(where: \.online) ?? gatewayOrigins[0])
        } catch { show(error) }
    }

    func renameMachine(_ endpoint: DieterEndpoint, name: String) async {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let daemonID = endpoint.daemonID, !normalized.isEmpty else { return }
        let origin = gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) ?? endpoint.gatewayEndpoint
        do {
            let client = try DieterRPC(endpoint: origin, accessToken: await accessToken(for: origin))
            let runner = Task { try? await client.run() }
            defer { runner.cancel(); client.shutdown() }
            _ = try await client.renameDaemon(daemonID: daemonID, name: normalized)
            await refreshDaemonPresence()
            persistEndpoints()
        } catch { show(error) }
    }

    func persistEndpoints() {
        guard persistConnectionSelection else { return }
        if let data = try? JSONEncoder().encode(gatewayOrigins) { UserDefaults.standard.set(data, forKey: "DieterEndpoints") }
        if let data = try? JSONEncoder().encode(endpoint) { UserDefaults.standard.set(data, forKey: "DieterActiveEndpoint") }
    }

    @discardableResult
    func ensureProjectConnection(_ projectID: String, reportOffline: Bool = true) async -> Bool {
        guard let target = machine(forProjectID: projectID) else { return true }
        guard target.online else {
            if reportOffline {
                errorMessage = "\(target.name) is offline. Start Dieter on that machine to open this project."
            }
            return false
        }
        guard target.id != endpoint.id else { return true }
        selectedProjectID = projectID
        await connect(to: target)
        return phase.isConnected && endpoint.id == target.id
    }

    func refreshMachineDirectory(includeArchivedChats: Bool = false) async {
        // The active machine is owned by WatchSync. Polling it here used to
        // replace the live snapshot while retaining its cursor, so later
        // deltas could be reduced against state from a different point in time.
        let onlineMachines = machines.filter { $0.online && $0.id != endpoint.id }
        guard !onlineMachines.isEmpty else { return }

        var snapshots: [MachineSnapshot] = []
        for machine in onlineMachines {
            do {
                snapshots.append(try await loadMachine(machine, includeArchivedChats: includeArchivedChats))
            } catch {
                // Presence is authoritative and refreshed on the next gateway
                // connection. One unreachable host must not hide other hosts.
                continue
            }
        }
        guard !snapshots.isEmpty else { return }

        var persistenceChanged = false
        for snapshot in snapshots {
            if machineConnectionStatuses[snapshot.endpoint.id] != snapshot.connection {
                machineConnectionStatuses[snapshot.endpoint.id] = snapshot.connection
            }
            if !snapshot.unchanged {
                persistenceChanged = await persistInactiveMachineSnapshot(snapshot) || persistenceChanged
            }
        }

        let changedSnapshots = snapshots.filter { !$0.unchanged }
        guard !changedSnapshots.isEmpty else { return }

        let current = MachineDirectoryProjection(
            projects: projectDirectory,
            projectEndpointIDs: projectEndpointIDs,
            boards: navigationBoards,
            cards: navigationCards,
            chats: chats
        )
        let next = MachineDirectoryReducer.merging(current, snapshots: changedSnapshots)
        if projectDirectory != next.projects { projectDirectory = next.projects }
        if projectEndpointIDs != next.projectEndpointIDs { projectEndpointIDs = next.projectEndpointIDs }
        if navigationBoards != next.boards { navigationBoards = next.boards }
        if navigationCards != next.cards { navigationCards = next.cards }
        if chats != next.chats { chats = next.chats }
        let nextChatProjects = next.sortedProjects
        if chatProjects != nextChatProjects { chatProjects = nextChatProjects }
        if current != next { updateSelectedState() }
        if let selectedChatID, let selected = chats.first(where: { $0.id == selectedChatID }) {
            markChatRead(selected)
        }
        if persistenceChanged { await scheduleSyncPersistence() }
    }

    @discardableResult
    func persistInactiveMachineSnapshot(_ machine: MachineSnapshot) async -> Bool {
        guard machine.endpoint.id != endpoint.id else { return false }
        let current = syncDiskState.projections[machine.endpoint.id] ?? .empty
        let next = await Task.detached(priority: .utility) {
            DieterSyncProjectionCache.replacingMetadata(
                in: current,
                projects: machine.projects,
                boards: machine.boards,
                cards: machine.cards,
                chats: machine.chats,
                cursor: machine.cursor
            )
        }.value
        guard current.cursor != next.cursor || current.snapshot != next.snapshot else { return false }
        syncDiskState.projections[machine.endpoint.id] = next
        syncStateDirty = true
        return true
    }

    func startMachineDirectoryRefresh(refreshImmediately: Bool = false) {
        machineDirectoryTask?.cancel()
        machineDirectoryTask = Task { [weak self] in
            if refreshImmediately {
                guard !Task.isCancelled, let self else { return }
                await self.refreshMachineDirectory()
            }
            while !Task.isCancelled {
                try? await DieterTaskSleep.seconds(15)
                guard !Task.isCancelled, let self else { return }
                await self.refreshDaemonPresence()
                await self.refreshMachineDirectory()
            }
        }
    }

    func startMachinePresenceLeaseMonitor() {
        machinePresenceLeaseTask?.cancel()
        machinePresenceLeaseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard !Task.isCancelled, let self else { return }
                let now = Date()
                let next = MachinePresenceText.applyingExpirations(to: self.endpoints, relativeTo: now)
                if next != self.endpoints {
                    self.endpoints = next
                }
                if let active = next.first(where: { $0.id == self.endpoint.id }), active != self.endpoint {
                    self.endpoint = active
                }
                let delay = MachinePresenceText.nextExpiration(in: next, relativeTo: now)
                    .map { max(0.05, min(5, $0.timeIntervalSince(now) + 0.05)) }
                    ?? 5
                try? await DieterTaskSleep.seconds(delay)
            }
        }
    }

    /// Directory refreshes are independent RPCs and may themselves stall on a
    /// half-open transport. Keep sync liveness on its own task so those calls
    /// can never prevent recovery of the stream which owns the visible board.
    /// Reopening WatchSync on the same transport is insufficient: a half-open
    /// HTTP/2 connection can accept the new subscription without delivering a
    /// frame, leaving the app in "Syncing" forever. Rebuild the data plane after
    /// three missed heartbeats instead.
    func startSyncLivenessMonitor() {
        syncLivenessTask?.cancel()
        syncLivenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await DieterTaskSleep.seconds(15)
                guard !Task.isCancelled, let self else { return }
                guard self.phase.isConnected, let rpc = self.rpc else { continue }
                guard SyncStreamLiveness.requiresConnectionRecovery(lastFrameAt: self.lastSyncFrameAt) else { continue }
                self.connectionStopped(DieterStoreConnectionError.syncTimedOut, client: rpc)
                return
            }
        }
    }

    /// Waking or reopening the app is an explicit consistency boundary. A new
    /// WatchSync subscription returns a fresh bounded snapshot immediately,
    /// while retaining the durable cursor for subsequent deltas.
    func applicationDidBecomeActive() {
        guard phase.isConnected, let rpc else { return }
        if SyncStreamLiveness.requiresConnectionRecovery(lastFrameAt: lastSyncFrameAt) {
            connectionStopped(DieterStoreConnectionError.syncTimedOut, client: rpc)
            return
        }
        startGlobalSync()
        guard let cardID = selectedCardID ?? selectedChatID,
              DieterConversationID.isServerBacked(cardID) else { return }
        conversationSyncing = true
        conversationTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self, let rpc = self.rpc,
                  (self.selectedCardID ?? self.selectedChatID) == cardID else { return }
            await self.fetchConversation(cardID: cardID, chat: self.selectedChatID == cardID, rpc: rpc)
        }
    }

    func refreshDaemonPresence() async {
        guard let origin = gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) else { return }
        do {
            let client = try DieterRPC(endpoint: origin, accessToken: await accessToken(for: origin))
            let runner = Task { try? await client.run() }
            defer { runner.cancel(); client.shutdown() }
            let directory = try await client.daemons()
            let previous = Dictionary(uniqueKeysWithValues: endpoints.compactMap { item in item.daemonID.map { ($0, item) } })
            endpoints = directory.daemons.map { daemon in
                var item = previous[daemon.id] ?? DieterEndpoint(
                    name: daemon.name.isEmpty ? daemon.id : daemon.name,
                    host: origin.host,
                    port: origin.port,
                    secure: origin.secure,
                    daemonID: daemon.id
                )
                item.name = daemon.name.isEmpty ? daemon.id : daemon.name
                item.online = MachinePresenceText.online(serverOnline: daemon.online, lastSeenAt: daemon.lastSeenAt)
                item.lastSeenAt = daemon.lastSeenAt
                item.version = daemon.version
				item.remoteDesktopReady = daemon.remoteDesktop.ready
				item.remoteDesktopReason = daemon.remoteDesktop.reason
				item.remoteDesktopPlatform = daemon.remoteDesktop.platform
                return item
            }
            if let refreshedActive = endpoints.first(where: { $0.id == endpoint.id }) {
                endpoint = refreshedActive
            }
            if endpoints.contains(where: { $0.online && machineOutboxSummaries[$0.id] != nil }) {
                startOutboxWorker()
            }
        } catch {
            // Keep the last known directory during a transient gateway loss.
        }
    }

    func loadMachine(_ machine: DieterEndpoint, includeArchivedChats: Bool) async throws -> MachineSnapshot {
        let client: DieterRPC
        let ownsClient: Bool
        var runner: Task<Void, Never>?
        var selectedConnection: MachineConnectionStatus?
        if machine.id == endpoint.id, let rpc {
            client = rpc
            ownsClient = false
        } else {
            let dataPlane = try await selectDirectoryDataPlane(for: machine)
            client = dataPlane.rpc
            ownsClient = true
            runner = dataPlane.task
            selectedConnection = dataPlane.connection
        }
        defer {
            if ownsClient { client.shutdown() }
            runner?.cancel()
        }

        let started = Date()
        var request = Dieter_V1_GetStateRequest()
        request.allProjects = true
        if let cursorData = syncDiskState.projections[machine.id]?.cursor,
           let cursor = try? Dieter_V1_SyncCursor(serializedBytes: cursorData) {
            request.ifNotModified = cursor
        }
        let root = try await client.state(request)
        let connection = MachineConnectionStatus(
            route: selectedConnection?.route
                ?? machineConnectionStatuses[machine.id]?.route
                ?? (ownsClient ? .gateway : .local),
            latencyMilliseconds: Self.latencyMilliseconds(since: started)
        )
        let cursor = root.cursor.epoch.isEmpty ? nil : try? root.cursor.serializedData()
        if root.notModified {
            return MachineSnapshot(
                endpoint: machine,
                connection: connection,
                projects: [], boards: [], cards: [], chats: [],
                cursor: cursor,
                unchanged: true
            )
        }

        let projects = root.projects.filter { !$0.archived }
        var boards = root.boards
        var cards = root.cards
        var chats = root.chats
        // Older remote daemons ignore all_projects. Retain a bounded
        // compatibility path until every enrolled machine has upgraded.
        if root.cursor.epoch.isEmpty {
            boards = []
            cards = []
            for project in projects {
                var legacy = Dieter_V1_GetStateRequest()
                legacy.projectID = project.id
                legacy.limit = 500
                let snapshot = try await client.state(legacy)
                boards.append(contentsOf: snapshot.boards)
                cards.append(contentsOf: snapshot.cards)
            }
            let chatResponse = try await client.chats(includeArchived: includeArchivedChats)
            chats = chatResponse.chats
        } else if includeArchivedChats {
            let chatResponse = try await client.chats(includeArchived: true)
            chats = chatResponse.chats
        }
        return MachineSnapshot(
            endpoint: machine,
            connection: connection,
            projects: projects,
            boards: Array(boards.reduce(into: [String: Dieter_V1_Board]()) { $0[$1.id] = $1 }.values),
            cards: Array(cards.reduce(into: [String: Dieter_V1_Card]()) { $0[$1.id] = $1 }.values),
            chats: chats,
            cursor: cursor
        )
    }

    func selectDirectoryDataPlane(for machine: DieterEndpoint) async throws -> DataPlaneConnection {
        guard machine.daemonID != nil else {
            throw NSError(domain: "DieterGateway", code: 5, userInfo: [NSLocalizedDescriptionKey: "Machine endpoint is missing its daemon identity."])
        }
        let origin = gatewayOrigins.first(where: { $0.credentialID == machine.credentialID }) ?? machine.gatewayEndpoint
        let gatewayAccessToken = await accessToken(for: origin)
        let gateway = try DieterRPC(endpoint: origin, accessToken: gatewayAccessToken)
        let gatewayTask = Task { try? await gateway.run() }
        defer {
            gatewayTask.cancel()
            gateway.shutdown()
        }
        return try await selectDataPlane(
            gateway: gateway,
            target: machine,
            gatewayAccessToken: gatewayAccessToken,
            directCandidateScope: .loopbackOnly,
            refreshDirectToken: false
        )
    }

    nonisolated static func latencyMilliseconds(since started: Date) -> Int {
        max(1, Int((Date().timeIntervalSince(started) * 1_000).rounded()))
    }

    nonisolated static func parseTimestamp(_ value: String) -> Date? {
        DieterTimestamp.date(from: value)
    }
}
