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
    private var idle: [Key: Idle] = [:]
    private var generation: UInt64 = 0
    package init(factory: DieterClientFactory = .live, clock: ClientClock = .live) {
        self.factory = factory; self.clock = clock
    }

    /// At most eight idle transports, retained for at most thirty seconds from
    /// admission. Active UI and screen transports have their own lifetime.
    package func temporaryLease(
        target: DieterEndpoint, accessToken: String?,
        connect: @MainActor () async throws -> DataPlaneConnection
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
                return lease(cached.plane, key: key, expires: cached.expires, generation: current)
            } catch {
                cached.plane.shutdown()
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
            }
        }
        plane = try await connect()
        expires = min(
            clock.now().addingTimeInterval(30),
            plane.directTokenExpiresAt.flatMap(DieterTimestamp.date(from:))?.addingTimeInterval(-5) ?? .distantFuture)
        guard !Task.isCancelled, generation == current else { plane.shutdown(); throw CancellationError() }
        return lease(plane, key: key, expires: expires, generation: current)
    }

    private func lease(_ plane: DataPlaneConnection, key: Key, expires: Date, generation: UInt64) -> DataPlaneLease {
        DataPlaneLease(plane: plane) { [weak self] reusable in
            guard reusable, let self, self.generation == generation, self.clock.now() < expires else {
                plane.shutdown(); return
            }
            if let previous = self.idle.removeValue(forKey: key) { previous.timer.cancel(); previous.plane.shutdown() }
            if self.idle.count >= 8, let oldest = self.idle.min(by: { $0.value.expires < $1.value.expires }) {
                self.idle.removeValue(forKey: oldest.key); oldest.value.timer.cancel(); oldest.value.plane.shutdown()
            }
            let id = UUID(), delay = max(0, expires.timeIntervalSince(self.clock.now()))
            let timer = Task { [weak self, clock = self.clock] in
                do { try await clock.sleep(.seconds(delay)) } catch { return }
                guard let self, self.idle[key]?.id == id else { return }
                self.idle.removeValue(forKey: key)?.plane.shutdown()
            }
            self.idle[key] = Idle(plane: plane, expires: expires, timer: timer, id: id)
        }
    }

    package func invalidateTemporaryLeases() {
        generation &+= 1
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
        refreshDirectToken: Bool = true,
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
                            accessToken: token.accessToken
                        )
                    )
                    let directTask = run(direct)
                    let started = Date()
                    do {
                        _ = try await direct.health(timeout: .seconds(2))
                        try Task.checkCancellation()
                        return DataPlaneConnection(
                            rpc: direct,
                            task: directTask,
                            connection: .init(
                                route: .local, latencyMilliseconds: Self.latencyMilliseconds(since: started)),
                            directTokenExpiresAt: token.expiresAt
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
        guard route.relayAvailable else {
            throw NSError(
                domain: "DieterGateway", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "This Dieter daemon is offline."])
        }
        let relay = try factory.client(
            endpoint: target, accessToken: gatewayAccessToken, route: .relay(daemonID: daemonID))
        let relayTask = run(relay)
        do {
            let started = Date()
            _ = try await relay.health(timeout: .seconds(5))
            try Task.checkCancellation()
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
}
