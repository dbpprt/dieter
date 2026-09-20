import AppKit
import DieterAPI
import Foundation
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

private struct InitialConnectionState {
    let health: Dieter_V1_HealthResponse
    let state: Dieter_V1_State
}

private enum ProviderQuotaClientError: LocalizedError {
    case noGateway

    var errorDescription: String? { "No gateway is configured." }
}

extension DieterStore {
    func connect(to newEndpoint: DieterEndpoint? = nil, automatic: Bool = false) async {
        if let syncRestoreTask {
            await syncRestoreTask.value
            self.syncRestoreTask = nil
        }
        if !automatic {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        let requested = newEndpoint ?? endpoint
        let preferredDaemonID = MachineRoutingPolicy.preferredDaemonID(
            newEndpoint: newEndpoint, currentEndpoint: endpoint)
        let explicitMachineSelection = newEndpoint?.daemonID != nil
        let origin =
            gatewayOrigins.first(where: { $0.credentialID == requested.credentialID })
            ?? requested.gatewayEndpoint
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let preservingLiveConnection = phase.isConnected && rpc != nil
        if !preservingLiveConnection { phase = .connecting }
        var gatewayRPC: DieterRPC?
        var gatewayTask: Task<Void, Never>?
        var gatewayAuthenticated = false
        var attemptedTarget: DieterEndpoint?
        var discoveredDirectory: [DieterEndpoint]?
        do {
            let accessToken = await accessToken(for: origin)
            let control = try environment.clients.client(endpoint: origin, accessToken: accessToken)
            gatewayRPC = control
            gatewayTask = Task { try? await control.run() }
            let daemonDirectory = try await control.daemons()
            guard
                ConnectionAttemptOwnership.mayMutateSharedState(
                    attemptGeneration: generation,
                    currentGeneration: connectionGeneration
                )
            else {
                gatewayTask?.cancel()
                control.shutdown()
                return
            }
            gatewayAuthenticated = true
            if daemonDirectory.hasGatewayInformation {
                gatewayInformation[origin.credentialID] = daemonDirectory.gatewayInformation
            }
            var discovered = daemonDirectory.daemons.map {
                DieterEndpoint(
                    name: $0.name.isEmpty ? $0.id : $0.name,
                    host: origin.host,
                    port: origin.port,
                    secure: origin.secure,
                    daemonID: $0.id,
                    online: MachinePresenceText.online(serverOnline: $0.online, lastSeenAt: $0.lastSeenAt),
                    lastSeenAt: $0.lastSeenAt,
                    version: $0.version,
                    apiVersion: $0.apiVersion,
                    remoteDesktopReady: $0.remoteDesktop.ready,
                    remoteDesktopReason: $0.remoteDesktop.reason,
                    remoteDesktopPlatform: $0.remoteDesktop.platform
                )
            }
            guard !discovered.isEmpty else {
                throw NSError(
                    domain: "DieterGateway", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No Dieter daemons are enrolled for this account."])
            }
            discoveredDirectory = discovered
            if explicitMachineSelection,
                let requestedTarget = discovered.first(where: { $0.daemonID == preferredDaemonID })
            {
                attemptedTarget = requestedTarget
                if requestedTarget.apiCompatibility == .incompatible {
                    throw DieterStoreConnectionError.incompatible(found: requestedTarget.apiVersion)
                }
            }
            let targets = MachineRoutingPolicy.connectionTargets(
                from: discovered,
                preferredDaemonID: preferredDaemonID,
                explicitMachineSelection: explicitMachineSelection
            )
            if !explicitMachineSelection,
                targets.isEmpty,
                let incompatible = discovered.first(where: {
                    $0.online && $0.apiCompatibility == .incompatible
                })
            {
                attemptedTarget = incompatible
                throw DieterStoreConnectionError.incompatible(found: incompatible.apiVersion)
            }
            guard !targets.isEmpty else {
                throw NSError(
                    domain: "DieterGateway", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "No enrolled Dieter machines are online."])
            }

            var prepared: (target: DieterEndpoint, plane: DataPlaneConnection, initial: InitialConnectionState)?
            var lastTargetError: Error?
            for candidate in targets {
                attemptedTarget = candidate
                if candidate.apiCompatibility == .incompatible {
                    lastTargetError = DieterStoreConnectionError.incompatible(found: candidate.apiVersion)
                    break
                }
                do {
                    let plane = try await selectDataPlane(
                        gateway: control,
                        target: candidate,
                        gatewayAccessToken: accessToken
                    )
                    do {
                        let initial = try await loadInitialConnectionState(from: plane.rpc)
                        var connectedTarget = candidate
                        connectedTarget.apiVersion = initial.health.version
                        prepared = (connectedTarget, plane, initial)
                        break
                    } catch {
                        plane.task.cancel()
                        plane.rpc.shutdown()
                        if let connectionError = error as? DieterStoreConnectionError,
                            case .incompatible(let found) = connectionError
                        {
                            discovered = discovered.map { machine in
                                guard machine.id == candidate.id else { return machine }
                                var machine = machine
                                machine.apiVersion = found
                                return machine
                            }
                            discoveredDirectory = discovered
                        }
                        lastTargetError = error
                    }
                } catch {
                    lastTargetError = error
                }
                if explicitMachineSelection { break }
            }
            guard let prepared else {
                throw lastTargetError
                    ?? NSError(
                        domain: "DieterGateway",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "No compatible Dieter machine could be reached."]
                    )
            }
            guard
                ConnectionAttemptOwnership.mayMutateSharedState(
                    attemptGeneration: generation,
                    currentGeneration: connectionGeneration
                )
            else {
                prepared.plane.task.cancel()
                prepared.plane.rpc.shutdown()
                gatewayTask?.cancel()
                control.shutdown()
                return
            }
            gatewayTask?.cancel()
            control.shutdown()
            gatewayTask = nil
            gatewayRPC = nil

            let cachedData =
                syncDiskState.projections[prepared.target.id]?.snapshot ?? syncDiskState.snapshot
            let decodedSnapshot = await snapshotDecoder.snapshot(
                endpointID: prepared.target.id, data: cachedData)
            guard
                ConnectionAttemptOwnership.mayMutateSharedState(
                    attemptGeneration: generation,
                    currentGeneration: connectionGeneration
                )
            else {
                prepared.plane.task.cancel()
                prepared.plane.rpc.shutdown()
                return
            }

            // Decode the destination first, then retain the outgoing machine as
            // the final suspension before committing the switch. Otherwise a
            // live transcript update during decoding could be lost on return.
            try? await saveSyncPersistence()
            guard
                ConnectionAttemptOwnership.mayMutateSharedState(
                    attemptGeneration: generation, currentGeneration: connectionGeneration)
            else {
                prepared.plane.task.cancel()
                prepared.plane.rpc.shutdown()
                return
            }

            let reconnectingActiveMachine = prepared.target.id == endpoint.id
            let destinationSnapshot = reconnectingActiveMachine ? syncSnapshot : decodedSnapshot
            let destinationData = reconnectingActiveMachine ? syncProjection.snapshot : cachedData

            // Commit the route switch only after the candidate has passed Health and
            // its initial state has loaded. Until this point the previous machine and
            // all of its streams remain fully usable.
            stateTask?.cancel()
            conversationTask?.cancel()
            gitOperationTask?.cancel()
            terminalWatchTask?.cancel()
            syncTask?.cancel()
            syncRecoveryEscalationTask?.cancel()
            syncRecoveryEscalationTask = nil
            syncLivenessTask?.cancel()
            outboxTask?.cancel()
            connectionTask?.cancel()
            directRefreshTask?.cancel()
            machineDirectoryTask?.cancel()
            machinePresenceLeaseTask?.cancel()
            machineTelemetryTask?.cancel()
            connectionMetadataTask?.cancel()
            terminalStreamConnected = false
            rpc?.shutdown()
            rpc = prepared.plane.rpc
            directCredential = prepared.plane.directCredential
            connectionTask = prepared.plane.task
            endpoint = prepared.target
            endpoints = (discoveredDirectory ?? []).map {
                $0.id == prepared.target.id ? prepared.target : $0
            }
            machineConnectionStatuses[prepared.target.id] = prepared.plane.connection
            machineConnectionErrors.removeValue(forKey: prepared.target.id)
            activateSyncProjection(
                for: prepared.target, decodedSnapshot: destinationSnapshot, decodedData: destinationData)
            persistEndpoints()
            startMachinePresenceLeaseMonitor()
            if let expiresAt = prepared.plane.directTokenExpiresAt {
                scheduleDirectRefresh(expiresAt: expiresAt, target: prepared.target)
            }
            self.health = prepared.initial.health
            self.runtime = Dieter_V1_RuntimeStatus()
            acceptState(prepared.initial.state)
            self.harnessCatalog = harnessCatalogsByEndpoint[prepared.target.id] ?? Dieter_V1_HarnessCatalog()
            self.boardSettings = syncSnapshot?.settings ?? Dieter_V1_Settings()
            self.settingsOptions = Dieter_V1_SettingsOptions()
            errorMessage = nil
            phase = .connected(version: prepared.initial.health.version)
            startGlobalSync()
            startSyncLivenessMonitor()
            startConnectionMetadata(client: prepared.plane.rpc, endpointID: prepared.target.id)
            conversationModel.resumeSelectedConversation(client: prepared.plane.rpc)
            startOutboxWorker()
            // The selected machine is live as soon as WatchSync starts.
            // Refreshing auxiliary machines must not hold this connect attempt
            // (and its reconnect task) open on an unrelated half-open RPC.
            startMachineDirectoryRefresh(refreshImmediately: true)
            Task { [weak self] in await self?.loadProviderQuotas() }
            if section == .terminals { await loadTerminals() }
        } catch {
            gatewayTask?.cancel()
            gatewayRPC?.shutdown()
            guard
                ConnectionAttemptOwnership.mayMutateSharedState(
                    attemptGeneration: generation,
                    currentGeneration: connectionGeneration
                )
            else {
                connectionLogger.debug(
                    "Ignoring failed stale connection attempt generation \(generation, privacy: .public)")
                return
            }
            if let attemptedTarget {
                machineConnectionErrors[attemptedTarget.id] = Self.connectionFailureDescription(error)
            }
            if preservingLiveConnection, phase.isConnected, rpc != nil {
                if let connectionError = error as? DieterStoreConnectionError,
                    case .incompatible(let found) = connectionError,
                    let attemptedTarget
                {
                    endpoints = endpoints.map { machine in
                        guard machine.id == attemptedTarget.id else { return machine }
                        var machine = machine
                        machine.apiVersion = found
                        return machine
                    }
                }
                // A failed machine switch is local to that destination. Never turn a
                // healthy machine's workspace into a global offline state or modal.
                return
            }
            connectionTask?.cancel()
            connectionTask = nil
            rpc?.shutdown()
            rpc = nil
            directCredential = nil
            if let discoveredDirectory { endpoints = discoveredDirectory }
            if let connectionError = error as? DieterStoreConnectionError,
                case .incompatible(let found) = connectionError
            {
                phase = .incompatible(found: found)
                endpoint = origin
                persistEndpoints()
                errorMessage = nil
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
                phase = .failed(Self.connectionFailureDescription(error))
                // The connection overlay already presents startup failures in
                // context. Do not duplicate expected offline state as a modal.
                errorMessage = nil
            }
        }
    }

    private static func connectionFailureDescription(_ error: Error) -> String {
        if let rpcError = error as? RPCError {
            return "gRPC \(rpcError.code): \(rpcError.message)"
        }
        return error.localizedDescription
    }

    private func loadInitialConnectionState(from rpc: DieterRPC) async throws
        -> InitialConnectionState
    {
        let health = try await loadInitialRead("health") { try await rpc.health() }
        guard health.status == "ok" else {
            throw NSError(
                domain: "DieterDaemon", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Dieter reported an unhealthy data plane."])
        }
        guard health.version == dieterExpectedAPIVersion else {
            throw DieterStoreConnectionError.incompatible(found: health.version)
        }
        return try await InitialConnectionState(
            health: health,
            state: loadInitialRead("state") { try await rpc.state() }
        )
    }

    private func startConnectionMetadata(client: DieterRPC, endpointID: String) {
        connectionMetadataTask?.cancel()
        connectionMetadataTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.rpc === client, self.endpoint.id == endpointID {
                // Provider discovery is auxiliary: a slow or unavailable model
                // catalog must never delay WatchSync or tear down its route.
                // Explicit tasks preserve the existing Swift async-let workaround.
                let runtimeTask = Task { try await client.runtimeStatus() }
                let harnessesTask = Task { try await client.harnesses() }
                let optionsTask = Task { try await client.settingsOptions() }
                do {
                    let values = try await withTaskCancellationHandler {
                        try await (runtimeTask.value, harnessesTask.value, optionsTask.value)
                    } onCancel: {
                        runtimeTask.cancel(); harnessesTask.cancel(); optionsTask.cancel()
                    }
                    guard !Task.isCancelled, self.rpc === client, self.endpoint.id == endpointID else { return }
                    self.runtime = values.0
                    self.harnessCatalog = values.1
                    self.harnessCatalogsByEndpoint[endpointID] = values.1
                    self.settingsOptions = values.2
                    return
                } catch {
                    runtimeTask.cancel(); harnessesTask.cancel(); optionsTask.cancel()
                    guard !Task.isCancelled, self.rpc === client else { return }
                    connectionLogger.warning(
                        "Connection metadata unavailable on \(endpointID, privacy: .public); retrying independently")
                    try? await DieterTaskSleep.seconds(5)
                }
            }
        }
    }

    private func loadInitialRead<Value>(
        _ name: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        var failures = 0
        while true {
            do {
                return try await operation()
            } catch {
                failures += 1
                guard failures < 3, DieterRPCFailure.canRetryRead(error) else {
                    throw NSError(
                        domain: "DieterInitialConnection",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Initial \(name) read failed: \(DieterRPCFailure.message(for: error))",
                            NSUnderlyingErrorKey: error,
                        ]
                    )
                }
                let delay = DieterStreamRecoveryPolicy.delay(consecutiveFailures: failures)
                try await DieterTaskSleep.seconds(delay)
            }
        }
    }

    func selectDataPlane(
        gateway: DieterRPC, target: DieterEndpoint, gatewayAccessToken: String?,
        directCandidateScope: DirectCandidateScope = .all, refreshDirectToken: Bool = false
    ) async throws -> DataPlaneConnection {
        try await connections.selectDataPlane(
            gateway: gateway, target: target, gatewayAccessToken: gatewayAccessToken,
            directCandidateScope: directCandidateScope, refreshDirectToken: refreshDirectToken,
            run: { [weak self] client in
                self?.startConnectionTask(for: client) ?? ConnectionManager.run(client)
            }
        )
    }

    func remoteDesktopConnection(machineID: String) async throws -> RemoteDesktopSignalingConnection {
        guard
            let target = machines.first(where: { $0.id == machineID })
                ?? (endpoint.id == machineID ? endpoint : nil)
        else {
            throw NSError(
                domain: "DieterScreens", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Select an enrolled Dieter machine."])
        }
        guard target.online else {
            throw NSError(
                domain: "DieterScreens", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."])
        }
        let origin =
            gatewayOrigins.first(where: { $0.credentialID == target.credentialID })
            ?? target.gatewayEndpoint
        let gatewayToken = await accessToken(for: origin)
        let gateway = try environment.clients.client(endpoint: origin, accessToken: gatewayToken)
        let gatewayTask = Task { try? await gateway.run() }
        defer {
            gatewayTask.cancel()
            gateway.shutdown()
        }
        return try await connections.remoteDesktopConnection(
            gateway: gateway, target: target, gatewayAccessToken: gatewayToken)
    }

    func startConnectionTask(for client: DieterRPC) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await client.run()
                if !Task.isCancelled {
                    self?.connectionStopped(
                        NSError(
                            domain: "DieterTransport", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The Dieter connection closed."]),
                        client: client,
                        source: "transport-ended"
                    )
                }
            } catch {
                // Only the owner cancelling this task is expected. A remote
                // cancellation still means our active transport needs recovery.
                self?.connectionStopped(error, client: client, source: "transport-runner")
            }
        }
    }

    func scheduleDirectRefresh(expiresAt: String, target: DieterEndpoint) {
        guard let expires = DieterTimestamp.date(from: expiresAt),
            let credential = directCredential,
            let client = rpc
        else { return }
        let delay = DirectCredentialRefreshPolicy.renewalDelay(expiresAt: expires, now: Date())
        scheduleDirectRefresh(
            after: delay,
            expiresAt: expires,
            target: target,
            credential: credential,
            client: client,
            attempt: 0
        )
    }

    private func scheduleDirectRefresh(
        after delay: TimeInterval,
        expiresAt: Date,
        target: DieterEndpoint,
        credential: DirectAccessCredential,
        client: DieterRPC,
        attempt: Int
    ) {
        directRefreshTask?.cancel()
        directRefreshTask = Task { [weak self] in
            try? await DieterTaskSleep.seconds(delay)
            guard !Task.isCancelled, let self,
                self.rpc === client,
                self.directCredential === credential
            else { return }
            self.directRefreshTask = nil
            await self.refreshDirectCredential(
                expiresAt: expiresAt,
                target: target,
                credential: credential,
                client: client,
                attempt: attempt
            )
        }
    }

    private func refreshDirectCredential(
        expiresAt: Date,
        target: DieterEndpoint,
        credential: DirectAccessCredential,
        client: DieterRPC,
        attempt: Int
    ) async {
        let origin =
            gatewayOrigins.first(where: { $0.credentialID == target.credentialID })
            ?? target.gatewayEndpoint
        let startedAt = Date()
        do {
            let gatewayToken = await accessToken(for: origin)
            let gateway = try environment.clients.client(endpoint: origin, accessToken: gatewayToken)
            let gatewayTask = Task { try? await gateway.run() }
            defer {
                gatewayTask.cancel()
                gateway.shutdown()
            }
            guard let daemonID = target.daemonID else {
                throw NSError(
                    domain: "DieterGateway", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "No routed Dieter machine is available."])
            }
            let token = try await gateway.daemonAccessToken(daemonID: daemonID)
            guard token.tokenType == "Bearer" else {
                throw NSError(
                    domain: "DieterGateway", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Gateway returned an unsupported daemon token."])
            }
            guard !Task.isCancelled, rpc === client, directCredential === credential else { return }
            let current = credential.snapshot()
            if DirectCredentialRefreshPolicy.requiresConnectionReplacement(
                currentGeneration: current.daemonGeneration,
                renewedGeneration: token.daemonGeneration
            ) {
                connectionLogger.notice(
                    "Direct credential generation changed for \(target.id, privacy: .public); rebuilding the data plane"
                )
                connectionStopped(
                    NSError(
                        domain: "DieterTransport", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The daemon connection generation changed."]),
                    client: client,
                    source: "direct-token-generation"
                )
                return
            }
            credential.update(
                token: token.accessToken,
                expiresAt: token.expiresAt,
                daemonGeneration: token.daemonGeneration
            )
            connectionLogger.debug(
                "Renewed direct credential for \(target.id, privacy: .public) in \(Self.latencyMilliseconds(since: startedAt), privacy: .public) ms without replacing streams"
            )
            scheduleDirectRefresh(expiresAt: token.expiresAt, target: target)
        } catch {
            guard !Task.isCancelled, rpc === client, directCredential === credential else { return }
            if let delay = DirectCredentialRefreshPolicy.retryDelay(
                attempt: attempt,
                expiresAt: expiresAt,
                now: Date()
            ) {
                connectionLogger.warning(
                    "Direct credential renewal for \(target.id, privacy: .public) failed; retrying in \(delay, privacy: .public)s: \(DieterRPCFailure.message(for: error), privacy: .public)"
                )
                scheduleDirectRefresh(
                    after: delay,
                    expiresAt: expiresAt,
                    target: target,
                    credential: credential,
                    client: client,
                    attempt: attempt + 1
                )
            } else {
                connectionStopped(error, client: client, source: "direct-token-expired")
            }
        }
    }

    func signIn() async {
        let target = endpoint
        let generation = connectionGeneration
        do {
            _ = try await authentication.signIn(to: target.gatewayEndpoint)
            guard endpoint.id == target.id, generation == connectionGeneration else { return }
            await connect(to: target)
        } catch {
            guard !DieterRPCFailure.isCancellation(error), endpoint.id == target.id,
                generation == connectionGeneration
            else { return }
            errorMessage = "Could not sign in: \(error.localizedDescription)"
        }
    }

    func completeAuthentication(url: URL) {
        guard !authentication.complete(url: url) else { return }
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let endpoint = try await self.authentication.resumePending(url: url) else { return }
                guard generation == self.connectionGeneration else { return }
                await self.connect(to: endpoint)
            } catch {
                guard generation == self.connectionGeneration, !DieterRPCFailure.isCancellation(error)
                else { return }
                self.errorMessage = "Could not finish sign-in: \(error.localizedDescription)"
            }
        }
    }

    func signOut() async {
        let target = endpoint
        authentication.cancel()
        do { try await environment.credentials.remove(for: target.credentialID) } catch {
            errorMessage = "Could not remove the saved sign-in: \(error.localizedDescription)"
            return
        }
        guard endpoint.credentialID == target.credentialID else { return }
        disconnect()
        phase = endpoint.secure ? .authenticationRequired : .disconnected
    }

    func connectionStopped(_ error: Error, client: DieterRPC, source: String = "rpc") {
        guard !Task.isCancelled else { return }
        guard rpc === client else { return }
        syncRecoveryEscalationTask?.cancel()
        syncRecoveryEscalationTask = nil
        guard hasLoadedWorkspace else {
            phase = .failed(Self.connectionFailureDescription(error))
            return
        }
        // A lost daemon is connectivity state, not an application error. Keep
        // the cached projection visible and let the workspace badge report the
        // interruption while the normal reconnect loop rebuilds the streams.
        errorMessage = nil
        if connectionRecoveryStartedAt == nil {
            connectionRecoveryStartedAt = Date()
            connectionRecoverySource = source
        }
        connectionLogger.warning(
            "Connection recovery requested by \(source, privacy: .public) on \(self.endpoint.id, privacy: .public): \(Self.connectionFailureDescription(error), privacy: .public)"
        )
        phase = .connecting
        scheduleReconnect(to: endpoint)
    }

    func scheduleReconnect(to target: DieterEndpoint) {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled, let self {
                await self.connect(to: target, automatic: true)
                if self.phase.isConnected {
                    self.reconnectTask = nil
                    return
                }
                try? await DieterTaskSleep.seconds(delay)
                guard !Task.isCancelled else { return }
                delay = min(15, delay * 1.8)
            }
        }
    }

    func disconnect() {
        connections.invalidateTemporaryLeases()
        connectionGeneration &+= 1
        stateTask?.cancel()
        conversationTask?.cancel()
        gitOperationTask?.cancel()
        terminalWatchTask?.cancel()
        syncTask?.cancel()
        syncLivenessTask?.cancel()
        outboxTask?.cancel()
        connectionTask?.cancel()
        directRefreshTask?.cancel()
        syncRecoveryEscalationTask?.cancel()
        syncRecoveryEscalationTask = nil
        directCredential = nil
        machineDirectoryTask?.cancel()
        machinePresenceLeaseTask?.cancel()
        machineTelemetryTask?.cancel()
        connectionMetadataTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        terminalStreamConnected = false
        rpc?.shutdown()
        rpc = nil
        lastSyncFrameAt = nil
        connectionRecoveryStartedAt = nil
        connectionRecoverySource = ""
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
        if let index = gatewayOrigins.firstIndex(where: {
            $0.credentialID == endpoint.credentialID || $0.name == endpoint.name
        }) {
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
        projectReplicaEndpointIDs.removeAll()
        harnessCatalogsByEndpoint.removeAll()
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
        selectedProjectID = ""
        selectedBoardID = ""
        resetFileSurface()
        bindSchedules()
        chatsRead.cancel()
        terminalsRead.cancel()
        chatsRequestGeneration &+= 1
        terminalRequestGeneration &+= 1
        archiveRequestGeneration &+= 1
        chatsLoading = false
        terminalLoading = false
        archiveLoading = false
        chatsError = nil
        terminalError = nil
        archiveError = nil
        schedulesError = nil
        providerQuotaGroups.removeAll()
        providerQuotasLoading = false
        providerQuotaError = nil
        providerQuotaMutatingAccounts.removeAll()
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
            projectReplicaEndpointIDs = projectReplicaEndpointIDs.filter { $0.value != endpoint.id }
            persistEndpoints()
            await connect(to: endpoints.first(where: \.online) ?? gatewayOrigins[0])
        } catch { show(error) }
    }

    func renameMachine(_ endpoint: DieterEndpoint, name: String) async {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let daemonID = endpoint.daemonID, !normalized.isEmpty else { return }
        let origin =
            gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID })
            ?? endpoint.gatewayEndpoint
        do {
            let client = try environment.clients.client(
                endpoint: origin, accessToken: await accessToken(for: origin))
            let runner = Task { try? await client.run() }
            defer {
                runner.cancel()
                client.shutdown()
            }
            _ = try await client.renameDaemon(daemonID: daemonID, name: normalized)
            await refreshDaemonPresence()
            persistEndpoints()
        } catch { show(error) }
    }

    func persistEndpoints() {
        guard persistConnectionSelection else { return }
        if let data = try? JSONEncoder().encode(gatewayOrigins) {
            environment.defaults.set(data, forKey: "DieterEndpoints")
        }
        if let data = try? JSONEncoder().encode(endpoint) {
            environment.defaults.set(data, forKey: "DieterActiveEndpoint")
        }
    }

    @discardableResult
    func ensureReplicaConnection(_ projectID: String, reportOffline: Bool = true) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let target = replica(forProjectID: projectID) else { return true }
        guard target.apiCompatibility != .incompatible else {
            machineConnectionErrors[target.id] = target.incompatibilityDescription
            return false
        }
        guard target.online else {
            if reportOffline {
                errorMessage =
                    "\(target.name) is offline. Start Dieter on that machine to open this project."
            }
            return false
        }
        if target.id == endpoint.id, phase.isConnected, rpc != nil { return true }
        selectedProjectID = projectID
        await connect(to: target)
        let connected = !Task.isCancelled && phase.isConnected && endpoint.id == target.id && rpc != nil
        if !connected, reportOffline, !Task.isCancelled {
            errorMessage = machineConnectionErrors[target.id] ?? "Could not connect to \(target.name). Try again."
        }
        return connected
    }

    func cachedHarnessCatalog(forProjectID projectID: String) -> Dieter_V1_HarnessCatalog? {
        let checkout = checkout(forProjectID: projectID)
        let endpointID = endpoints.first { $0.daemonID == checkout?.daemonID }?.id ?? "unavailable-checkout"
        return ConversationHarnessCatalogDirectory.catalog(
            endpointID: endpointID,
            activeEndpointID: endpoint.id,
            activeCatalog: harnessCatalog,
            catalogsByEndpoint: harnessCatalogsByEndpoint
        )
    }

    func loadHarnessCatalog(forProjectID projectID: String) async throws -> Dieter_V1_HarnessCatalog {
        try Task.checkCancellation()
        guard let checkout = checkout(forProjectID: projectID) else {
            throw NSError(
                domain: "DieterHarnessCatalog", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Choose a machine and checkout to load models."])
        }
        let endpointID = endpoints.first { $0.daemonID == checkout.daemonID }?.id ?? "unavailable-checkout"
        if let cached = harnessCatalogsByEndpoint[endpointID], !cached.harnesses.isEmpty {
            return cached
        }
        if endpointID == endpoint.id, phase.isConnected, let rpc {
            do {
                let catalog = try await rpc.harnesses()
                try Task.checkCancellation()
                if self.rpc === rpc, endpoint.id == endpointID { harnessCatalog = catalog }
                harnessCatalogsByEndpoint[endpointID] = catalog
                return catalog
            } catch {
                guard DieterRPCFailure.canRetryRead(error) else { throw error }
                connectionLogger.info(
                    "Active harness catalog read failed transiently; retrying on a temporary route without replacing the data plane"
                )
            }
        }
        guard let machine = endpoints.first(where: { $0.id == endpointID }), machine.online else {
            throw NSError(
                domain: "DieterHarnessCatalog", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The selected checkout’s machine is offline."])
        }
        let catalog: Dieter_V1_HarnessCatalog
        do {
            catalog = try await readHarnessCatalog(on: machine)
        } catch {
            guard DieterRPCFailure.canRetryRead(error) else { throw error }
            catalog = try await readHarnessCatalog(on: machine)
        }
        harnessCatalogsByEndpoint[endpointID] = catalog
        return catalog
    }

    private func readHarnessCatalog(on machine: DieterEndpoint) async throws -> Dieter_V1_HarnessCatalog {
        let plane = try await selectDirectoryDataPlane(for: machine)
        do {
            let catalog = try await plane.rpc.harnesses()
            try Task.checkCancellation()
            plane.release()
            return catalog
        } catch {
            // A failed read must not put its cancelled transport back in the
            // idle pool for the next model load or user action.
            plane.release(reusable: false)
            throw error
        }
    }

    func refreshMachineDirectory(includeArchivedChats: Bool = false) async {
        let generation = connectionGeneration
        let origin = activeGateway.credentialID
        // The active machine is owned by WatchSync. Polling it here used to
        // replace the live snapshot while retaining its cursor, so later
        // deltas could be reduced against state from a different point in time.
        let onlineMachines = machines.filter {
            $0.online && $0.apiCompatibility != .incompatible && $0.id != endpoint.id
        }
        guard !onlineMachines.isEmpty else { return }

        let snapshots = await withTaskGroup(of: MachineSnapshot?.self) { group in
            var next = 0
            var snapshots: [MachineSnapshot] = []
            for _ in 0..<min(3, onlineMachines.count) {
                let machine = onlineMachines[next]
                next += 1
                group.addTask {
                    try? await self.loadMachine(machine, includeArchivedChats: includeArchivedChats)
                }
            }
            for await snapshot in group {
                if let snapshot { snapshots.append(snapshot) }
                if !Task.isCancelled, next < onlineMachines.count {
                    let machine = onlineMachines[next]
                    next += 1
                    group.addTask {
                        try? await self.loadMachine(machine, includeArchivedChats: includeArchivedChats)
                    }
                }
            }
            return snapshots
        }
        guard !Task.isCancelled, generation == connectionGeneration,
            origin == activeGateway.credentialID,
            !snapshots.isEmpty
        else { return }

        var persistenceChanged = false
        for snapshot in snapshots {
            if machineConnectionStatuses[snapshot.endpoint.id] != snapshot.connection {
                machineConnectionStatuses[snapshot.endpoint.id] = snapshot.connection
            }
            if !snapshot.unchanged {
                persistenceChanged = await persistInactiveMachineSnapshot(snapshot) || persistenceChanged
                guard !Task.isCancelled, generation == connectionGeneration,
                    origin == activeGateway.credentialID
                else {
                    return
                }
            }
        }

        let changedSnapshots = snapshots.filter { !$0.unchanged }
        guard !changedSnapshots.isEmpty else { return }

        let current = MachineDirectoryProjection(
            projects: projectDirectory,
            projectReplicaEndpointIDs: projectReplicaEndpointIDs,
            boards: navigationBoards,
            cards: navigationCards,
            chats: chats
        )
        let next = MachineDirectoryReducer.merging(current, snapshots: changedSnapshots)
        replica.accept(next)
        refreshReplicaPresentation()
        rebuildOutboxOverlays()
        if current != next { updateSelectedState() }
        if let selectedChatID, let selected = chats.first(where: { $0.id == selectedChatID }) {
            markChatRead(selected)
        }
        if persistenceChanged { await scheduleSyncPersistence() }
    }

    @discardableResult
    func persistInactiveMachineSnapshot(_ machine: MachineSnapshot) async -> Bool {
        guard machine.endpoint.id != endpoint.id else { return false }
        let generation = connectionGeneration
        let origin = activeGateway.credentialID
        let current = syncDiskState.projections[machine.endpoint.id] ?? .empty
        let next = await Task.detached(priority: .utility) {
            DieterSyncProjectionCache.replacingMetadata(
                in: current,
                projects: machine.projects,
                boards: machine.boards,
                cards: machine.cards,
                chats: machine.chats,
                cursor: machine.cursor,
                archives: machine.archives
            )
        }.value
        guard !Task.isCancelled, generation == connectionGeneration,
            origin == activeGateway.credentialID,
            machine.endpoint.id != endpoint.id,
            syncDiskState.projections[machine.endpoint.id]?.cursor == current.cursor,
            syncDiskState.projections[machine.endpoint.id]?.snapshot == current.snapshot,
            current.cursor != next.cursor || current.snapshot != next.snapshot
        else { return false }
        syncDiskState.projections[machine.endpoint.id] = next
        syncStateDirty = true
        return true
    }

    func startMachineDirectoryRefresh(refreshImmediately: Bool = false) {
        machineDirectoryTask?.cancel()
        machineDirectoryTask = Task { [weak self] in
            await MachineDirectoryRefreshLoop.run(
                refreshImmediately: refreshImmediately,
                refreshPresence: { [weak self] in await self?.refreshDaemonPresence() },
                refreshDirectory: { [weak self] in
                    guard let self else { return }
                    await self.refreshMachineDirectory()
                    guard !Task.isCancelled else { return }
                    await self.loadProviderQuotas()
                }
            )
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
                let delay =
                    MachinePresenceText.nextExpiration(in: next, relativeTo: now)
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
    var syncTransportIsStale: Bool {
        guard let activity = syncLastActivity else { return true }
        return activity.duration(to: ContinuousClock.now) >= syncTransportTimeout
    }

    func startSyncLivenessMonitor() {
        syncLivenessTask?.cancel()
        syncLivenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await DieterTaskSleep.seconds(5)
                guard !Task.isCancelled, let self else { return }
                guard self.phase.isConnected, let rpc = self.rpc else { continue }
                guard self.syncTransportIsStale
                else { continue }
                self.connectionStopped(
                    DieterStoreConnectionError.syncTimedOut,
                    client: rpc,
                    source: "watch-sync-liveness"
                )
                return
            }
        }
    }

    /// Keep a healthy stream across activation; only stale transport evidence
    /// warrants reconnecting the shared data plane.
    func applicationDidBecomeActive() {
        guard phase.isConnected, let rpc else { return }
        if syncTransportIsStale {
            connectionStopped(
                DieterStoreConnectionError.syncTimedOut,
                client: rpc,
                source: "activation-liveness"
            )
            return
        }
        if syncTask == nil { startGlobalSync() }
        conversationModel.resumeSelectedConversation(client: rpc)
    }

    func refreshDaemonPresence() async {
        let generation = connectionGeneration
        guard let origin = gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID })
        else { return }
        do {
            let client = try environment.clients.client(
                endpoint: origin, accessToken: await accessToken(for: origin))
            let runner = Task { try? await client.run() }
            defer {
                runner.cancel()
                client.shutdown()
            }
            let directory = try await client.daemons()
            guard !Task.isCancelled, generation == connectionGeneration,
                origin.credentialID == activeGateway.credentialID
            else { return }
            if directory.hasGatewayInformation {
                gatewayInformation[origin.credentialID] = directory.gatewayInformation
            }
            let previous = Dictionary(
                uniqueKeysWithValues: endpoints.compactMap { item in item.daemonID.map { ($0, item) } })
            endpoints = directory.daemons.map { daemon in
                var item =
                    previous[daemon.id]
                    ?? DieterEndpoint(
                        name: daemon.name.isEmpty ? daemon.id : daemon.name,
                        host: origin.host,
                        port: origin.port,
                        secure: origin.secure,
                        daemonID: daemon.id
                    )
                item.name = daemon.name.isEmpty ? daemon.id : daemon.name
                item.online = MachinePresenceText.online(
                    serverOnline: daemon.online, lastSeenAt: daemon.lastSeenAt)
                item.lastSeenAt = daemon.lastSeenAt
                item.version = daemon.version
                item.apiVersion = daemon.apiVersion
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

    func loadProviderQuotas(requestRefresh: Bool = false) async {
        guard !providerQuotasLoading else { return }
        let generation = connectionGeneration
        guard
            let origin = gatewayOrigins.first(where: { $0.credentialID == activeGateway.credentialID })
                ?? gatewayOrigins.first
        else { return }
        providerQuotasLoading = true
        defer {
            if origin.credentialID == activeGateway.credentialID { providerQuotasLoading = false }
        }
        do {
            let client = try environment.clients.client(
                endpoint: origin, accessToken: await accessToken(for: origin))
            let runner = Task { try? await client.run() }
            defer {
                runner.cancel()
                client.shutdown()
            }
            let groups =
                if requestRefresh {
                    try await client.refreshProviderQuotas().groups
                } else {
                    try await client.providerQuotas().groups
                }
            guard !Task.isCancelled, generation == connectionGeneration,
                origin.credentialID == activeGateway.credentialID
            else { return }
            providerQuotaGroups = groups
            providerQuotaError = nil
        } catch {
            guard generation == connectionGeneration,
                origin.credentialID == activeGateway.credentialID
            else { return }
            providerQuotaError = DieterRPCFailure.message(for: error)
        }
    }

    func setProviderQuotaSummaryInclusion(
        provider: Dieter_Gateway_V1_ProviderQuotaProvider,
        accountKey: String,
        included: Bool
    ) async {
        guard providerQuotaMutatingAccounts.insert(accountKey).inserted else { return }
        defer { providerQuotaMutatingAccounts.remove(accountKey) }
        do {
            let (client, origin, runner) = try await providerQuotaClient()
            defer {
                runner.cancel()
                client.shutdown()
            }
            let response = try await client.setProviderQuotaSummaryInclusion(
                provider: provider, accountKey: accountKey, included: included)
            guard origin.credentialID == activeGateway.credentialID else { return }
            replaceProviderQuotaGroups(response.groups, provider: provider)
            providerQuotaError = nil
        } catch {
            providerQuotaError = DieterRPCFailure.message(for: error)
        }
    }

    func consumeProviderQuotaReset(accountKey: String) async {
        guard providerQuotaMutatingAccounts.insert(accountKey).inserted else { return }
        defer { providerQuotaMutatingAccounts.remove(accountKey) }
        do {
            let (client, origin, runner) = try await providerQuotaClient()
            defer {
                runner.cancel()
                client.shutdown()
            }
            let response = try await client.consumeProviderQuotaReset(
                accountKey: accountKey, idempotencyKey: UUID().uuidString.lowercased())
            guard origin.credentialID == activeGateway.credentialID else { return }
            replaceProviderQuotaGroups(response.groups, provider: .openaiCodex)
            providerQuotaError =
                response.accepted
                ? nil : "No online machine with access to this OpenAI account accepted the reset."
        } catch {
            providerQuotaError = DieterRPCFailure.message(for: error)
        }
    }

    private func providerQuotaClient() async throws -> (
        DieterRPC, DieterEndpoint, Task<Void, Never>
    ) {
        guard
            let origin = gatewayOrigins.first(where: { $0.credentialID == activeGateway.credentialID })
                ?? gatewayOrigins.first
        else { throw ProviderQuotaClientError.noGateway }
        let client = try environment.clients.client(
            endpoint: origin, accessToken: await accessToken(for: origin))
        let runner = Task<Void, Never> { _ = try? await client.run() }
        return (client, origin, runner)
    }

    private func replaceProviderQuotaGroups(
        _ groups: [Dieter_Gateway_V1_ProviderQuotaGroup],
        provider: Dieter_Gateway_V1_ProviderQuotaProvider
    ) {
        providerQuotaGroups.removeAll { $0.provider == provider }
        providerQuotaGroups.append(contentsOf: groups)
        providerQuotaGroups.sort { $0.provider.rawValue < $1.provider.rawValue }
    }

    func loadMachine(_ machine: DieterEndpoint, includeArchivedChats: Bool) async throws
        -> MachineSnapshot
    {
        let client: DieterRPC
        var lease: DataPlaneLease?
        var selectedConnection: MachineConnectionStatus?
        if machine.id == endpoint.id, let rpc {
            client = rpc
        } else {
            let dataPlane = try await selectDirectoryDataPlane(for: machine)
            client = dataPlane.rpc
            lease = dataPlane
            selectedConnection = dataPlane.connection
        }
        defer { lease?.release() }

        let started = Date()
        var request = Dieter_V1_GetStateRequest()
        request.allProjects = true
        if let cursorData = syncDiskState.projections[machine.id]?.cursor,
            let cursor = try? Dieter_V1_SyncCursor(serializedBytes: cursorData)
        {
            request.ifNotModified = cursor
        }
        let root = try await client.state(request)
        let connection = MachineConnectionStatus(
            route: selectedConnection?.route
                ?? machineConnectionStatuses[machine.id]?.route
                ?? (lease != nil ? .gateway : .local),
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
        if includeArchivedChats {
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
            cursor: cursor,
            archives: root.archives
        )
    }

    func selectDirectoryDataPlane(for machine: DieterEndpoint) async throws -> DataPlaneLease {
        guard machine.daemonID != nil else {
            throw NSError(
                domain: "DieterGateway", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Machine endpoint is missing its daemon identity."])
        }
        guard machine.apiCompatibility != .incompatible else {
            throw DieterStoreConnectionError.incompatible(found: machine.apiVersion)
        }
        let origin =
            gatewayOrigins.first(where: { $0.credentialID == machine.credentialID })
            ?? machine.gatewayEndpoint
        let gatewayAccessToken = await accessToken(for: origin)
        return try await connections.temporaryLease(target: machine, accessToken: gatewayAccessToken) {
            let gateway = try environment.clients.client(
                endpoint: origin, accessToken: gatewayAccessToken)
            let gatewayTask = Task { try? await gateway.run() }
            defer {
                gatewayTask.cancel()
                gateway.shutdown()
            }
            return try await selectDataPlane(
                gateway: gateway, target: machine, gatewayAccessToken: gatewayAccessToken,
                directCandidateScope: .loopbackOnly, refreshDirectToken: true
            )
        }
    }

    nonisolated static func latencyMilliseconds(since started: Date) -> Int {
        max(1, Int((Date().timeIntervalSince(started) * 1_000).rounded()))
    }

    nonisolated static func parseTimestamp(_ value: String) -> Date? {
        DieterTimestamp.date(from: value)
    }
}
