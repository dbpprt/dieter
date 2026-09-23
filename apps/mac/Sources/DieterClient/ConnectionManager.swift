import DieterCore
import DieterAPI
import Foundation
import OSLog

private let connectionLogger = Logger(subsystem: "com.dbpprt.dieter.mac", category: "Connection")

/// One route-selection policy for active work, background reads, outbox delivery,
/// telemetry, and screen signaling. Each caller owns the returned transport lease.
@MainActor package final class ConnectionManager {
    private let factory: DieterClientFactory
    private let clock: ClientClock
    private struct Key: Hashable {
        let target: DieterEndpoint
        let token: String?
    }
    private struct Idle {
        let plane: DataPlaneConnection
        let expires: Date
        let timer: Task<Void, Never>
        let id: UUID
    }
    private struct Promotion {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var idle: [Key: Idle] = [:]
    private var promotions: [Key: Promotion] = [:]
    private var webRTCRetries: [String: WebRTCRouteRetryState] = [:]
    private var generation: UInt64 = 0
    package init(factory: DieterClientFactory = .live, clock: ClientClock = .live) {
        self.factory = factory; self.clock = clock
    }

    /// At most eight healthy idle transports, retained for at most five minutes
    /// from admission. Active UI and screen transports have their own lifetime.
    package func temporaryLease(
        target: DieterEndpoint, accessToken: String?,
        connect: @escaping @MainActor () async throws -> DataPlaneConnection
    ) async throws -> DataPlaneLease {
        let key = Key(target: target, token: accessToken)
        let current = generation
        let plane: DataPlaneConnection
        let expires: Date
        if let cached = idle.removeValue(forKey: key) {
            cached.timer.cancel()
            do {
                guard clock.now() < cached.expires else { throw CancellationError() }
                _ = try await cached.plane.rpc.health(timeout: .seconds(2))
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                if cached.plane.connection.route == .gateway,
                    let daemonID = target.daemonID,
                    TemporaryRouteCachePolicy.shouldProbeWebRTC(
                        cachedRoute: cached.plane.connection.route,
                        retry: webRTCRetries[daemonID],
                        now: clock.now())
                {
                    startBackgroundPromotion(
                        key: key, daemonID: daemonID, generation: current, connect: connect)
                }
                return lease(cached.plane, key: key, expires: cached.expires, generation: current)
            } catch {
                cached.plane.shutdown()
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
            }
        }
        plane = try await connect()
        expires = expiration(for: plane)
        guard !Task.isCancelled, generation == current else { plane.shutdown(); throw CancellationError() }
        return lease(plane, key: key, expires: expires, generation: current)
    }

    private func lease(_ plane: DataPlaneConnection, key: Key, expires: Date, generation: UInt64) -> DataPlaneLease {
        DataPlaneLease(plane: plane) { [weak self] reusable in
            guard reusable, let self, self.generation == generation, self.clock.now() < expires else {
                plane.shutdown(); return
            }
            self.storeIdle(plane, key: key, expires: expires)
        }
    }

    private func expiration(for plane: DataPlaneConnection) -> Date {
        let credentialDeadline =
            plane.credentialRefreshTask == nil
            ? plane.directTokenExpiresAt.flatMap(DieterTimestamp.date(from:))?.addingTimeInterval(-5)
                ?? .distantFuture
            : .distantFuture
        return min(
            clock.now().addingTimeInterval(TemporaryRouteCachePolicy.healthyIdleLifetime),
            credentialDeadline)
    }

    private func storeIdle(_ plane: DataPlaneConnection, key: Key, expires: Date) {
        if let previous = idle[key],
            !TemporaryRouteCachePolicy.prefers(plane.connection.route, over: previous.plane.connection.route)
        {
            plane.shutdown()
            return
        }
        if let previous = idle.removeValue(forKey: key) {
            previous.timer.cancel()
            previous.plane.shutdown()
        }
        if idle.count >= 8, let oldest = idle.min(by: { $0.value.expires < $1.value.expires }) {
            idle.removeValue(forKey: oldest.key)
            oldest.value.timer.cancel()
            oldest.value.plane.shutdown()
        }
        let id = UUID(), delay = max(0, expires.timeIntervalSince(clock.now()))
        let timer = Task { [weak self, clock = self.clock] in
            do { try await clock.sleep(.seconds(delay)) } catch { return }
            guard let self, self.idle[key]?.id == id else { return }
            self.idle.removeValue(forKey: key)?.plane.shutdown()
        }
        idle[key] = Idle(plane: plane, expires: expires, timer: timer, id: id)
    }

    private func startBackgroundPromotion(
        key: Key,
        daemonID: String,
        generation: UInt64,
        connect: @escaping @MainActor () async throws -> DataPlaneConnection
    ) {
        guard promotions[key] == nil else { return }
        let id = UUID()
        let task = Task { [weak self] in
            defer {
                if self?.promotions[key]?.id == id { self?.promotions.removeValue(forKey: key) }
            }
            do {
                let candidate = try await connect()
                guard let self, !Task.isCancelled, self.generation == generation else {
                    candidate.shutdown()
                    return
                }
                guard candidate.connection.route != .gateway else {
                    candidate.shutdown()
                    return
                }
                self.storeIdle(candidate, key: key, expires: self.expiration(for: candidate))
                connectionLogger.info(
                    "Background WebRTC promotion succeeded for \(daemonID, privacy: .public) via \(candidate.connection.route.rawValue, privacy: .public)"
                )
            } catch is CancellationError {
            } catch {
                connectionLogger.debug(
                    "Background WebRTC promotion did not replace the stable relay for \(daemonID, privacy: .public)")
            }
        }
        promotions[key] = Promotion(id: id, task: task)
    }

    package func invalidateTemporaryLeases() {
        generation &+= 1
        for value in promotions.values { value.task.cancel() }
        promotions.removeAll()
        for value in idle.values { value.timer.cancel(); value.plane.shutdown() }
        idle.removeAll()
    }
    package static func run(_ client: DieterRPC) -> Task<Void, Never> {
        Task { try? await client.run() }
    }

    private static func latencyMilliseconds(since started: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(started) * 1_000))
    }

    package func selectDataPlane(
        gateway: DieterRPC,
        target: DieterEndpoint,
        gatewayAccessToken: String?,
        directCandidateScope: DirectCandidateScope = .all,
        refreshDirectToken: Bool = false,
        route suppliedRoute: Dieter_Gateway_V1_DaemonRoute? = nil,
        run: @escaping @MainActor (DieterRPC) -> Task<Void, Never> = ConnectionManager.run
    ) async throws -> DataPlaneConnection {
        guard let daemonID = target.daemonID else {
            throw NSError(
                domain: "DieterGateway", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "No routed Dieter machine is available."])
        }
        try Task.checkCancellation()
        let route: Dieter_Gateway_V1_DaemonRoute
        if let suppliedRoute { route = suppliedRoute } else { route = try await gateway.route(daemonID: daemonID) }
        try Task.checkCancellation()
        let directCandidates = directCandidateScope.ordered(route.directCandidates)
        if !directCandidates.isEmpty {
            let token = try await gateway.daemonAccessToken(daemonID: daemonID)
            guard token.tokenType == "Bearer" else {
                throw NSError(
                    domain: "DieterGateway", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Gateway returned an unsupported daemon token."])
            }
            for candidate in directCandidates {
                try Task.checkCancellation()
                do {
                    let direct = try factory.client(
                        endpoint: target,
                        direct: .init(
                            host: candidate.host,
                            port: Int(candidate.port),
                            daemonID: daemonID,
                            daemonCAPEM: route.daemonCaPem,
                            accessToken: token.accessToken,
                            expiresAt: token.expiresAt,
                            daemonGeneration: token.daemonGeneration
                        )
                    )
                    let directTask = run(direct)
                    let started = Date()
                    do {
                        _ = try await direct.health(timeout: .seconds(2))
                        try Task.checkCancellation()
                        var credentialRefreshTask: Task<Void, Never>?
                        if refreshDirectToken, let credential = direct.directCredential {
                            let clients = factory
                            let origin = gateway.endpoint
                            credentialRefreshTask = Task {
                                await DirectCredentialRefreshLoop.run(credential: credential) {
                                    let renewalGateway = try clients.client(
                                        endpoint: origin, accessToken: gatewayAccessToken)
                                    let renewalTask = Task { try? await renewalGateway.run() }
                                    defer {
                                        renewalTask.cancel()
                                        renewalGateway.shutdown()
                                    }
                                    return try await renewalGateway.daemonAccessToken(daemonID: daemonID)
                                }
                            }
                        }
                        return DataPlaneConnection(
                            rpc: direct,
                            task: directTask,
                            connection: .init(
                                route: candidate.network.caseInsensitiveCompare("loopback") == .orderedSame
                                    ? .local : .directTLS,
                                latencyMilliseconds: Self.latencyMilliseconds(since: started)),
                            directTokenExpiresAt: token.expiresAt,
                            directCredential: direct.directCredential,
                            credentialRefreshTask: credentialRefreshTask
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
        try Task.checkCancellation()
        if route.controlWebrtc && route.relayAvailable,
            webRTCRetries[daemonID]?.allowsAttempt(at: clock.now()) ?? true
        {
            do {
                let connection = try await HedgedRoute.connect(
                    preferred: {
                        try await self.controlConnection(
                            gateway: gateway, target: target, gatewayAccessToken: gatewayAccessToken, route: route,
                            refreshDirectToken: refreshDirectToken, run: run)
                    },
                    fallback: {
                        try await self.relayConnection(target: target, accessToken: gatewayAccessToken, run: run)
                    },
                    dispose: { $0.shutdown() })
                if connection.connection.route == .gateway {
                    var retry = webRTCRetries[daemonID] ?? WebRTCRouteRetryState()
                    _ = retry.recordFailure(at: clock.now())
                    webRTCRetries[daemonID] = retry
                    connectionLogger.info("Relay became healthy before WebRTC for \(daemonID, privacy: .public)")
                } else {
                    webRTCRetries.removeValue(forKey: daemonID)
                }
                return connection
            } catch {
                try Task.checkCancellation()
                var retry = webRTCRetries[daemonID] ?? WebRTCRouteRetryState()
                let delay = retry.recordFailure(at: clock.now())
                webRTCRetries[daemonID] = retry
                let diagnostic = error as? ControlRouteDiagnosticError
                let stage = diagnostic?.stage ?? "unknown"
                let reason = diagnostic?.reason ?? "unavailable"
                let elapsedMilliseconds = diagnostic?.elapsedMilliseconds ?? 0
                connectionLogger.info(
                    "WebRTC control route unavailable for \(daemonID, privacy: .public); stage=\(stage, privacy: .public) reason=\(reason, privacy: .public) elapsed_ms=\(elapsedMilliseconds) retry_in_s=\(Int(delay))"
                )
                throw error
            }
        } else if let retryAt = webRTCRetries[daemonID]?.retryAt {
            connectionLogger.debug(
                "Using stable gateway relay for \(daemonID, privacy: .public); WebRTC retry in \(max(0, Int(retryAt.timeIntervalSince(self.clock.now()))))s"
            )
        }
        guard route.relayAvailable else {
            throw NSError(
                domain: "DieterGateway", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "This Dieter daemon is offline."])
        }
        return try await relayConnection(target: target, accessToken: gatewayAccessToken, run: run)
    }

    private func relayConnection(
        target: DieterEndpoint, accessToken: String?,
        run: @escaping @MainActor (DieterRPC) -> Task<Void, Never>
    ) async throws -> DataPlaneConnection {
        guard let daemonID = target.daemonID else { throw CancellationError() }
        let relay = try factory.client(
            endpoint: target, accessToken: accessToken, route: .relay(daemonID: daemonID))
        let relayTask = run(relay)
        do {
            let started = Date()
            _ = try await relay.health(timeout: .seconds(5))
            try Task.checkCancellation()
            return DataPlaneConnection(
                rpc: relay,
                task: relayTask,
                connection: .init(route: .gateway, latencyMilliseconds: Self.latencyMilliseconds(since: started)),
                directTokenExpiresAt: nil,
                directCredential: nil
            )
        } catch {
            relayTask.cancel()
            relay.shutdown()
            throw error
        }
    }

    /// Opens an independently owned screen-signaling route. The returned
    /// connection keeps its direct credential refresh alive and must be shut
    /// down by the screen session without affecting app observation RPCs.
    package func remoteDesktopConnection(
        gateway: DieterRPC,
        target: DieterEndpoint,
        gatewayAccessToken: String?,
        directCandidateScope: DirectCandidateScope = .all,
        route suppliedRoute: Dieter_Gateway_V1_DaemonRoute? = nil,
        run: @escaping @MainActor (DieterRPC) -> Task<Void, Never> = ConnectionManager.run
    ) async throws -> RemoteDesktopSignalingConnection {
        guard let daemonID = target.daemonID else {
            throw NSError(
                domain: "DieterScreens", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Select an enrolled Dieter machine."])
        }
        guard target.online else {
            throw NSError(
                domain: "DieterScreens", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."])
        }
        let route: Dieter_Gateway_V1_DaemonRoute
        if let suppliedRoute {
            route = suppliedRoute
        } else {
            route = try await gateway.route(daemonID: daemonID)
        }
        let configuration = try await gateway.rtcConfiguration(daemonID: daemonID)
        let plane = try await selectDataPlane(
            gateway: gateway,
            target: target,
            gatewayAccessToken: gatewayAccessToken,
            directCandidateScope: directCandidateScope,
            refreshDirectToken: true,
            route: route,
            run: run)
        return RemoteDesktopSignalingConnection(
            rpc: plane.rpc,
            connectionTask: plane.task,
            rtcConfiguration: configuration,
            daemonCertificatePEM: route.daemonCertificatePem,
            routeLabel: plane.connection.route == .local ? "Direct" : plane.connection.route.rawValue,
            credentialRefreshTask: plane.credentialRefreshTask)
    }
}
