import DieterAPI
import DieterClient
import DieterCore
import Foundation
import GRPCCore
import Synchronization
import Testing

private struct RecoveryFixtureError: Error {}

@Test func webRTCRouteFailuresBackOffFromTwoMinutesAndCapAtFifteen() {
    let now = Date(timeIntervalSince1970: 1_000)
    var state = WebRTCRouteRetryState()
    let expected: [TimeInterval] = [120, 240, 480, 900, 900]
    var attempt = now
    for (index, delay) in expected.enumerated() {
        #expect(state.recordFailure(at: attempt) == delay)
        #expect(state.consecutiveFailures == index + 1)
        #expect(!state.allowsAttempt(at: attempt.addingTimeInterval(delay - 0.001)))
        attempt = attempt.addingTimeInterval(delay)
        #expect(state.allowsAttempt(at: attempt))
    }
    state.recordSuccess()
    #expect(state == WebRTCRouteRetryState())
}

@Test func stableRelayIsKeptWhileBackgroundPromotionRuns() {
    let now = Date(timeIntervalSince1970: 1_000)
    var retry = WebRTCRouteRetryState()
    _ = retry.recordFailure(at: now)

    #expect(
        !TemporaryRouteCachePolicy.shouldProbeWebRTC(
            cachedRoute: .gateway, retry: retry, now: now.addingTimeInterval(119)))
    #expect(
        TemporaryRouteCachePolicy.shouldProbeWebRTC(
            cachedRoute: .gateway, retry: retry, now: now.addingTimeInterval(120)))
    #expect(
        !TemporaryRouteCachePolicy.shouldProbeWebRTC(
            cachedRoute: .webrtcTURN, retry: retry, now: now.addingTimeInterval(120)))
    #expect(TemporaryRouteCachePolicy.prefers(.webrtcTURN, over: .gateway))
    #expect(!TemporaryRouteCachePolicy.prefers(.gateway, over: .webrtcTURN))
    #expect(TemporaryRouteCachePolicy.healthyIdleLifetime == 300)
}

@Test func webRTCCandidateDiagnosticsExposeOnlyKindsAndCounts() {
    let summary = ControlRTCBridge.candidateSummary(
        in: """
            a=candidate:1 1 udp 1 10.0.0.1 100 typ host generation 0
            a=candidate:2 1 udp 1 203.0.113.1 200 typ srflx generation 0
            a=candidate:3 1 tcp 1 192.0.2.1 300 typ relay generation 0
            """)
    #expect(summary == .init(host: 1, srflx: 1, relay: 1))
}

private final class CredentialRolloverProbe: Sendable {
    let state = Mutex((now: Date(timeIntervalSince1970: 1_000), exchanges: 0, sleeps: [Double]()))
    var clock: ClientClock {
        ClientClock(
            now: { self.state.withLock { $0.now } },
            sleep: { duration in
                let seconds =
                    Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18
                self.state.withLock {
                    $0.now += seconds; $0.sleeps.append(seconds)
                }
            })
    }
}

@Test func screenCredentialSurvivesRepeatedRolloverThenStopsOnRevocation() async {
    let probe = CredentialRolloverProbe()
    let credential = DirectAccessCredential(
        token: "first", expiresAt: Date(timeIntervalSince1970: 1_300).ISO8601Format(), daemonGeneration: 7)
    await DirectCredentialRefreshLoop.run(credential: credential, clock: probe.clock) {
        let attempt = probe.state.withLock {
            $0.exchanges += 1; return $0.exchanges
        }
        if attempt == 1 { throw RPCError(code: .unavailable, message: "temporary gateway failure") }
        if attempt == 4 { throw RPCError(code: .unauthenticated, message: "session revoked") }
        var token = Dieter_Gateway_V1_DaemonAccessToken()
        token.tokenType = "Bearer"
        token.accessToken = "renewed-\(attempt)"
        token.expiresAt = probe.clock.now().addingTimeInterval(300).ISO8601Format()
        token.daemonGeneration = 7
        return token
    }
    #expect(credential.snapshot().token == "renewed-3")
    #expect(probe.state.withLock { $0.exchanges } == 4)
    #expect(probe.state.withLock { $0.sleeps } == [270, 1, 270, 270])
}

@Test func screenCredentialRejectsChangedEnrollmentAndCanceledRefresh() async {
    for cancel in [false, true] {
        let probe = CredentialRolloverProbe()
        let credential = DirectAccessCredential(
            token: "first", expiresAt: Date(timeIntervalSince1970: 1_300).ISO8601Format(), daemonGeneration: 7)
        await Task {
            await DirectCredentialRefreshLoop.run(credential: credential, clock: probe.clock) {
                probe.state.withLock { $0.exchanges += 1 }
                if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                var token = Dieter_Gateway_V1_DaemonAccessToken()
                token.tokenType = "Bearer"; token.accessToken = "replacement"
                token.expiresAt = probe.clock.now().addingTimeInterval(300).ISO8601Format()
                token.daemonGeneration = cancel ? 7 : 8
                return token
            }
        }.value
        #expect(credential.snapshot().token == "first")
        #expect(probe.state.withLock { $0.exchanges } == 1)
    }
}

@Test @MainActor func failedModelTransportIsDiscardedInsteadOfReused() async throws {
    let manager = ConnectionManager()
    let endpoint = DieterEndpoint(name: "Fixture", host: "127.0.0.1", port: 1)
    let client = try DieterRPC(endpoint: endpoint)
    let runner = Task<Void, Never> {}
    let renewal = Task<Void, Never> {}
    let plane = DataPlaneConnection(
        rpc: client, task: runner, connection: .init(route: .local, latencyMilliseconds: 0),
        directTokenExpiresAt: nil, credentialRefreshTask: renewal)
    let lease = try await manager.temporaryLease(target: endpoint, accessToken: nil) { plane }
    lease.release(reusable: false)
    #expect(runner.isCancelled)
    #expect(renewal.isCancelled)
    // Releasing twice must not return the discarded client to the pool.
    lease.release()
    var openedFreshRoute = false
    await #expect(throws: RecoveryFixtureError.self) {
        _ = try await manager.temporaryLease(target: endpoint, accessToken: nil) {
            openedFreshRoute = true
            throw RecoveryFixtureError()
        }
    }
    #expect(openedFreshRoute)
    manager.invalidateTemporaryLeases()
}

@Test func lowLevelAndRuntimeTransportFailuresAreTransient() {
    #expect(DieterRPCFailure.isTransient(POSIXError(.EPIPE)))
    #expect(DieterRPCFailure.isTransient(POSIXError(.ECONNRESET)))
    #expect(
        DieterRPCFailure.isTransient(
            RuntimeError(code: .transportError, message: "connection closed", cause: POSIXError(.EPIPE))))
    #expect(
        DieterRPCFailure.isTransient(
            RPCError(
                code: .unknown, message: "transport failed",
                cause: RuntimeError(code: .transportError, message: "broken pipe"))))
    #expect(!DieterRPCFailure.isTransient(POSIXError(.EPERM)))
}

@Test func directCredentialRenewsInPlace() {
    let credential = DirectAccessCredential(
        token: "first",
        expiresAt: "2026-09-15T12:05:00Z",
        daemonGeneration: 7
    )
    #expect(credential.snapshot().token == "first")

    credential.update(
        token: "second",
        expiresAt: "2026-09-15T12:10:00Z",
        daemonGeneration: 7
    )

    #expect(
        credential.snapshot()
            == DirectAccessCredentialSnapshot(
                token: "second",
                expiresAt: "2026-09-15T12:10:00Z",
                daemonGeneration: 7
            ))
}

@Test func directCredentialRefreshPolicyRenewsBeforeExpiryAndEscalatesGenerationChanges() {
    let now = Date(timeIntervalSince1970: 1_000)
    let expires = now.addingTimeInterval(300)

    #expect(DirectCredentialRefreshPolicy.renewalDelay(expiresAt: expires, now: now) == 270)
    #expect(DirectCredentialRefreshPolicy.retryDelay(attempt: 0, expiresAt: expires, now: now) == 1)
    #expect(
        !DirectCredentialRefreshPolicy.requiresConnectionReplacement(
            currentGeneration: 7,
            renewedGeneration: 7
        ))
    #expect(
        DirectCredentialRefreshPolicy.requiresConnectionReplacement(
            currentGeneration: 7,
            renewedGeneration: 8
        ))
    #expect(
        DirectCredentialRefreshPolicy.retryDelay(
            attempt: 3,
            expiresAt: now.addingTimeInterval(0.5),
            now: now
        ) == nil)
}
