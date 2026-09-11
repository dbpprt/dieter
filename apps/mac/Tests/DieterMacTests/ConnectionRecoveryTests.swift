import DieterAPI
import Foundation
import GRPCCore
import Synchronization
import Testing
@testable import DieterMac

private struct RecoveryFixtureError: Error {}

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
    store.projectEndpointIDs = ["project": target.id]
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
    let plane = DataPlaneConnection(
        rpc: client, task: runner, connection: .init(route: .local, latencyMilliseconds: 0),
        directTokenExpiresAt: nil)
    let lease = try await manager.temporaryLease(target: endpoint, accessToken: nil) { plane }
    lease.release(reusable: false)
    #expect(runner.isCancelled)
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
    #expect(!(await store.ensureProjectConnection("project")))
    #expect(probe.attempts.withLock { $0 } == 1)
    #expect(store.errorMessage != nil)
}

@Test @MainActor func connectedMachineActionsReuseTheLiveTransport() async throws {
    let probe = RecoveryProbe()
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    store.rpc = try DieterRPC(endpoint: store.endpoint)
    store.phase = .connected(version: dieterExpectedAPIVersion)

    #expect(await store.ensureProjectConnection("project"))
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

@Test @MainActor func cancelledActionsDoNotStartAnotherConnection() async {
    let probe = RecoveryProbe()
    let store = recoveryStore(probe: probe)
    defer { store.disconnect() }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await store.ensureProjectConnection("project")
    }
    #expect(!(await task.value))
    #expect(probe.attempts.withLock { $0 } == 0)
    #expect(store.errorMessage == nil)
}
