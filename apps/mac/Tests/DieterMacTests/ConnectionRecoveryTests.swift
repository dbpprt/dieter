import DieterAPI
import DieterClient
import DieterCore
import Foundation
import GRPCCore
import Synchronization
import Testing
@testable import DieterMac

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

    #expect(!TemporaryRouteCachePolicy.shouldProbeWebRTC(
        cachedRoute: .gateway, retry: retry, now: now.addingTimeInterval(119)))
    #expect(TemporaryRouteCachePolicy.shouldProbeWebRTC(
        cachedRoute: .gateway, retry: retry, now: now.addingTimeInterval(120)))
    #expect(!TemporaryRouteCachePolicy.shouldProbeWebRTC(
        cachedRoute: .webrtcTURN, retry: retry, now: now.addingTimeInterval(120)))
    #expect(TemporaryRouteCachePolicy.prefers(.webrtcTURN, over: .gateway))
    #expect(!TemporaryRouteCachePolicy.prefers(.gateway, over: .webrtcTURN))
    #expect(TemporaryRouteCachePolicy.healthyIdleLifetime == 300)
}

@Test func webRTCCandidateDiagnosticsExposeOnlyKindsAndCounts() {
    let summary = ControlRTCBridge.candidateSummary(in: """
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

private final class RecoveryProbe: Sendable {
    let attempts = Mutex(0)
    let cancelledAttempts: Int
    init(cancelledAttempts: Int = 0) { self.cancelledAttempts = cancelledAttempts }
}

@MainActor private func recoveryStore(probe: RecoveryProbe) -> DieterStore {
    let environment = DieterAppEnvironment.testing()
    let store = DieterStore(
        environment: DieterAppEnvironment(
            arguments: [], defaults: environment.defaults, storageRoot: environment.storageRoot,
            clients: DieterClientFactory { _, _, _, _ in
                let attempt = probe.attempts.withLock {
                    $0 += 1; return $0
                }
                if attempt <= probe.cancelledAttempts { throw CancellationError() }
                throw RecoveryFixtureError()
            }),
        restoreSync: false)
    let target = DieterEndpoint(
        name: "Fixture", host: "127.0.0.1", port: 1, daemonID: "fixture", online: true,
        apiVersion: dieterExpectedAPIVersion)
    store.endpoint = target
    store.endpoints = [target]
    store.gatewayOrigins = [target.gatewayEndpoint]
    store.projectReplicaEndpointIDs = ["project": target.id]
    var checkout = Dieter_V1_Checkout(); checkout.id = "checkout"; checkout.daemonID = "fixture";
    checkout.projectID = "project"
    var project = Dieter_V1_Project(); project.id = "project"; project.checkouts = [checkout]
    store.projectDirectory = [project.id: project]
    return store
}

@Test @MainActor func remoteModelCatalogRetriesTransportCancellationOnce() async {
    let probe = RecoveryProbe(cancelledAttempts: 1)
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    await #expect(throws: RecoveryFixtureError.self) {
        try await store.loadHarnessCatalog(forProjectID: "project")
    }
    #expect(probe.attempts.withLock { $0 } == 2)
}

@Test @MainActor func remoteModelCatalogDoesNotRetryIndefinitely() async {
    let probe = RecoveryProbe(cancelledAttempts: 10)
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    await #expect(throws: CancellationError.self) {
        try await store.loadHarnessCatalog(forProjectID: "project")
    }
    #expect(probe.attempts.withLock { $0 } == 2)
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

@Test @MainActor func selectedMachineMustReconnectBeforeAdmittingActions() async throws {
    let probe = RecoveryProbe()
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    let client = try DieterRPC(endpoint: store.endpoint)
    store.rpc = client
    store.phase = .connecting

    // A matching machine ID is insufficient: pin/archive must not receive the
    // old transport while recovery is in progress.
    #expect(!(await store.ensureReplicaConnection("project")))
    #expect(probe.attempts.withLock { $0 } == 1)
    #expect(store.errorMessage != nil)
}

@Test @MainActor func connectedMachineActionsReuseTheLiveTransport() async throws {
    let probe = RecoveryProbe()
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    store.rpc = try DieterRPC(endpoint: store.endpoint)
    store.phase = .connected(version: dieterExpectedAPIVersion)

    #expect(await store.ensureReplicaConnection("project"))
    #expect(probe.attempts.withLock { $0 } == 0)
}

@Test @MainActor func modelCatalogEscapesAStoppedActiveTransport() async throws {
    let probe = RecoveryProbe()
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    let client = try DieterRPC(endpoint: store.endpoint)
    client.shutdown()
    store.rpc = client
    store.phase = .connected(version: dieterExpectedAPIVersion)

    // The retry reaches the fresh route factory instead of repeatedly using
    // the closed client. The fixture never opens a socket or starts an agent.
    await #expect(throws: RecoveryFixtureError.self) {
        try await store.loadHarnessCatalog(forProjectID: "project")
    }
    #expect(probe.attempts.withLock { $0 } == 1)
}

@Test func cancelledTransportReadsRecoverButCancelledCallersDoNot() async throws {
    #expect(DieterRPCFailure.canRetryRead(CancellationError()))
    #expect(DieterRPCFailure.canRetryRead(RPCError(code: .cancelled, message: "relay closed")))
    #expect(DieterRPCFailure.canRetryRead(RPCError(code: .unavailable, message: "offline")))
    #expect(!DieterRPCFailure.canRetryRead(RPCError(code: .permissionDenied, message: "denied")))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return DieterRPCFailure.canRetryRead(CancellationError())
    }
    #expect(!(await task.value))
}

@Test func lowLevelAndRuntimeTransportFailuresAreRecoverableReads() {
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
    #expect(
        DieterRPCFailure.canRetryRead(
            RPCError(code: .unimplemented, message: "No messages received, exactly one was expected.")))
    #expect(!DieterRPCFailure.canRetryRead(RPCError(code: .unimplemented, message: "unknown method")))
}

@Test @MainActor func synchronizedConversationClearsAStaleStreamFailure() {
    let store = recoveryStore(probe: RecoveryProbe())
    defer { store.disconnect() }
    store.selectedChatID = "card"
    store.conversationError = "Conversation updates paused: broken pipe"
    store.conversationSyncing = true
    var snapshot = Dieter_V1_GlobalSnapshot()
    var conversation = Dieter_V1_ConversationSnapshot()
    conversation.detail.card.id = "card"
    conversation.conversation.cardID = "card"
    snapshot.conversations = [conversation]

    store.applySelectedConversationProjection(snapshot, endpointID: store.endpoint.id)

    #expect(store.conversation?.detail.card.id == "card")
    #expect(store.conversationError == nil)
    #expect(!store.conversationSyncing)
}

@Test @MainActor func cancelledActionsDoNotStartAnotherConnection() async {
    let probe = RecoveryProbe()
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await store.ensureReplicaConnection("project")
    }
    #expect(!(await task.value))
    #expect(probe.attempts.withLock { $0 } == 0)
    #expect(store.errorMessage == nil)
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

@Test func streamRecoveryRetriesImmediatelyThenBacksOff() {
    #expect(DieterStreamRecoveryPolicy.resubscriptionTimeout == 2)
    #expect(DieterStreamRecoveryPolicy.delay(consecutiveFailures: 1) == 0)
    #expect(DieterStreamRecoveryPolicy.delay(consecutiveFailures: 2) == 0.25)
    #expect(DieterStreamRecoveryPolicy.delay(consecutiveFailures: 100) == 5)
}

@Test @MainActor func transportHeartbeatNeverAdvancesAppliedProjection() async throws {
    let store = recoveryStore(probe: RecoveryProbe())
    defer { store.disconnect() }
    store.phase = .connected(version: "fixture")
    store.globalSyncing = true
    var cursor = Dieter_V1_SyncCursor(); cursor.epoch = "fixture"; cursor.sequence = 4
    store.syncProjection.cursor = try cursor.serializedData()
    var frame = Dieter_V1_SyncFrame()
    frame.heartbeat = true; frame.transportOnly = true; frame.projectionPending = true
    frame.cursor = cursor; frame.cursor.sequence = 99
    frame.observedCursor = frame.cursor
    await store.applySyncFrame(frame, endpointID: store.endpoint.id)
    let applied = try Dieter_V1_SyncCursor(serializedBytes: #require(store.syncProjection.cursor))
    #expect(applied.sequence == 4)
    #expect(store.globalSyncing)
    #expect(store.lastSyncFrameAt != nil)
    #expect(!store.syncTransportIsStale)
    #expect(store.machineIsAvailable(store.endpoint))
}

@Test @MainActor func partialSyncBatchCannotResumeAndOldSubscriptionCannotApply() async throws {
    let store = recoveryStore(probe: RecoveryProbe())
    defer { store.disconnect() }
    var frame = Dieter_V1_SyncFrame()
    frame.projectionPending = true
    frame.snapshot = Dieter_V1_GlobalSnapshot()
    frame.cursor.epoch = "fixture"; frame.cursor.sequence = 7
    store.syncProjection.cursor = try frame.cursor.serializedData()
    await store.applySyncFrame(frame, endpointID: store.endpoint.id)
    #expect(store.syncProjection.cursor == nil)
    #expect(store.globalSyncing)
    let last = store.lastSyncFrameAt
    store.syncSubscriptionGeneration = 2
    frame.projectionPending = false
    await store.applySyncFrame(frame, endpointID: store.endpoint.id, subscription: 1)
    #expect(store.syncProjection.cursor == nil)
    #expect(store.lastSyncFrameAt == last)
}

@Test @MainActor func screenFeedbackContinuesWhileMainActorAndStatisticsAreBlocked() {
    let frames = Mutex<[Dieter_V1_RemoteDesktopReceiverFeedback]>([])
    let pump = RemoteDesktopFeedbackPump { value in frames.withLock { $0.append(value) } }
    var initial = Dieter_V1_RemoteDesktopReceiverFeedback(); initial.protocolVersion = DieterContract.number
    pump.start(channel: nil, initial: initial)
    pump.input(active: true)
    // No statistics callback, lease renewal or main actor execution is needed.
    Thread.sleep(forTimeInterval: 1.7)
    pump.stop()
    let sent = frames.withLock { $0 }
    #expect(sent.count >= 3)
    #expect(sent.enumerated().allSatisfy { $0.element.sequence == UInt64($0.offset + 1) })
    #expect(sent.last?.inputActive == false)
}

@Test @MainActor func multiFrameWorkspacePublishesOnlyAfterTheFinalPage() async throws {
    let store = recoveryStore(probe: RecoveryProbe())
    defer { store.disconnect() }
    var existing = Dieter_V1_GlobalSnapshot(); existing.state.storePath = "visible"
    store.syncSnapshot = existing
    var first = Dieter_V1_SyncFrame()
    first.projectionPending = true; first.snapshot.state.storePath = "replacement"
    await store.applySyncFrame(first, endpointID: store.endpoint.id)
    #expect(store.syncSnapshot?.state.storePath == "visible")
    #expect(store.pendingSyncSnapshot?.state.storePath == "replacement")
    var last = Dieter_V1_SyncFrame()
    last.cursor.epoch = "fixture"; last.cursor.sequence = 9
    await store.applySyncFrame(last, endpointID: store.endpoint.id)
    #expect(store.syncSnapshot?.state.storePath == "replacement")
    #expect(store.pendingSyncSnapshot == nil)
    #expect(!store.globalSyncing)
}

@Test @MainActor func healthyActivationKeepsTheExistingSyncSubscription() throws {
    let store = recoveryStore(probe: RecoveryProbe())
    defer { store.disconnect() }
    store.rpc = try DieterRPC(endpoint: store.endpoint)
    store.phase = .connected(version: "fixture")
    store.syncLastActivity = ContinuousClock.now
    let task = Task { try? await Task.sleep(for: .seconds(60)) }
    store.syncTask = Task { await task.value }
    defer { task.cancel() }
    let subscription = store.syncSubscriptionGeneration

    store.applicationDidBecomeActive()
    store.applicationDidBecomeActive()

    #expect(store.syncSubscriptionGeneration == subscription)
    #expect(store.syncTask?.isCancelled == false)
    #expect(store.phase.isConnected)
}
