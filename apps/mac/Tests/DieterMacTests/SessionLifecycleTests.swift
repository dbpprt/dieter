import AppKit
import DieterAPI
import DieterCore
import Foundation
import Synchronization
import Testing
@testable import DieterMac

private final class ScreenFixture: ScreenSignalingRPC {
    let closed = Mutex(false)
    let capabilities = Mutex<Dieter_V1_RemoteDesktopCapabilities>(.init())
    let starts = Mutex(0)
    let leaseSignals = Mutex<[Dieter_V1_RemoteDesktopSignal]>([])
    func shutdown() { closed.withLock { $0 = true } }
    func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities {
        capabilities.withLock { $0 }
    }
    func startRemoteDesktop(
        _ request: Dieter_V1_StartRemoteDesktopRequest,
        receive: @escaping @Sendable (Dieter_V1_RemoteDesktopSignal) async throws -> Void
    ) async throws { starts.withLock { $0 += 1 } }
    func sendRemoteDesktopSignal(_ signal: Dieter_V1_RemoteDesktopSignal) async throws {
        leaseSignals.withLock { $0.append(signal) }
    }
    func remoteDesktopSession(sessionID: String) async throws -> Dieter_V1_RemoteDesktopSessionState { .init() }
    func updateRemoteDesktopSession(_ request: Dieter_V1_UpdateRemoteDesktopSessionRequest) async throws
        -> Dieter_V1_RemoteDesktopSessionState
    { .init() }
    func setRemoteDesktopControl(sessionID: String, take: Bool) async throws -> Dieter_V1_RemoteDesktopSessionState {
        .init()
    }
    func closeRemoteDesktop(sessionID: String) async throws {}
    func remoteDesktopDisplayModes(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes { .init() }
    func setRemoteDesktopDisplayMode(_ request: Dieter_V1_SetRemoteDesktopDisplayModeRequest) async throws
        -> Dieter_V1_RemoteDesktopDisplayModes
    { .init() }
    func restoreRemoteDesktopDisplayMode(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes {
        .init()
    }
    func connection(_ label: String) -> RemoteDesktopSignalingConnection {
        .init(
            rpc: self, connectionTask: Task {}, rtcConfiguration: .init(), daemonCertificatePEM: Data(),
            routeLabel: label)
    }
}

@Test @MainActor func screenUnavailableHostOffersPermissionGuidanceWithoutStartingMedia() async {
    let rpc = ScreenFixture(), controller = RemoteDesktopController()
    rpc.capabilities.withLock {
        $0.availability = .permissionRequired
        $0.unavailableReason = "Run dieter daemon permissions on the host"
    }
    await controller.connect(machineName: "Host") { rpc.connection("fixture") }.value
    #expect(controller.phase == .permissionRequired("Run dieter daemon permissions on the host"))
    #expect(rpc.starts.withLock { $0 } == 0)
    controller.disconnect()
    rpc.capabilities.withLock {
        $0.availability = .unsupported
        $0.unavailableReason = "No graphical session"
    }
    await controller.connect(machineName: "Host") { rpc.connection("fixture") }.value
    #expect(controller.phase == .unsupported("No graphical session"))
    #expect(rpc.starts.withLock { $0 } == 0)
    controller.disconnect()
}

@Test @MainActor func screenLeaseRenewalDoesNotWaitForTheMainActor() async throws {
    let rpc = ScreenFixture()
    let renewal = RemoteDesktopLeaseRenewal.start(rpc: rpc, sessionID: "owned-session", interval: .milliseconds(15)) {
        _ in
    }
    // Confirm the detached sender has been scheduled before measuring it while
    // the main actor is blocked. Task startup latency is not part of the lease
    // renewal invariant.
    for _ in 0..<200 where rpc.leaseSignals.withLock({ $0.isEmpty }) {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(rpc.leaseSignals.withLock { !$0.isEmpty })
    rpc.leaseSignals.withLock { $0.removeAll() }
    // Deliberately prevent the UI actor from executing. The sender must keep
    // renewing independently, just like the native receiver feedback pump.
    blockUIForLeaseRenewalTest()
    #expect(rpc.leaseSignals.withLock { !$0.isEmpty })
    #expect(
        rpc.leaseSignals.withLock { signals in
            signals.allSatisfy { signal in
                guard case .leaseHeartbeat = signal.payload else { return false }
                return signal.sessionID == "owned-session"
            }
        })
    renewal.cancel(); await renewal.value
    let count = rpc.leaseSignals.withLock { $0.count }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(rpc.leaseSignals.withLock { $0.count } == count)
}

@MainActor private func blockUIForLeaseRenewalTest() {
    Thread.sleep(forTimeInterval: 0.18)
}

@Test func screenRecoveryContinuesWithBoundedFrequencyUntilDisconnected() {
    var recovery = RemoteDesktopRecovery()
    #expect(recovery.nextDelay(now: 0) == 0.25)
    recovery.streaming(now: 1)
    #expect(recovery.nextDelay(now: 2) == 0.5)
    #expect(recovery.nextDelay(now: 3) == 1)
    #expect(recovery.nextDelay(now: 4) == 2)
    for now in 5..<1000 { #expect(recovery.nextDelay(now: Double(now)) <= 5) }
    recovery.streaming(now: 5)
    #expect(recovery.nextDelay(now: 16) == 0.25)
    #expect(RemoteDesktopRecovery.retryableClosure("session lease expired"))
    for reason in [
        "native capture rendition stopped", "native daemon heartbeat expired",
        "native capture helper unresponsive", "native capture helper stopped",
    ] {
        #expect(RemoteDesktopRecovery.retryableClosure(reason))
    }
    #expect(!RemoteDesktopRecovery.retryableClosure("closed by client"))
    #expect(!RemoteDesktopRecovery.retryableClosure("capture permission denied"))
}
private actor DelayedScreenRoute {
    var continuation: CheckedContinuation<RemoteDesktopSignalingConnection, Never>?
    func route() async -> RemoteDesktopSignalingConnection {
        await withCheckedContinuation { continuation = $0 }
    }
    var waiting: Bool { continuation != nil }
    func finish(_ connection: RemoteDesktopSignalingConnection) {
        continuation?.resume(returning: connection); continuation = nil
    }
}
@MainActor private func waitForSession(_ condition: () async -> Bool) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw CocoaError(.coderValueNotFound)
}

@Test @MainActor func screenDisconnectClosesALateRouteWithoutResurrectingSession() async throws {
    let controller = RemoteDesktopController(), route = DelayedScreenRoute(), rpc = ScreenFixture()
    let task = controller.connect(machineName: "A") { await route.route() }
    try await waitForSession { await route.waiting }
    controller.disconnect()
    await route.finish(rpc.connection("late")); await task.value
    #expect(controller.phase == .idle)
    #expect(controller.routeLabel.isEmpty)
    #expect(rpc.closed.withLock { $0 })
}

@Test @MainActor func screenTeardownWithClosedInputDoesNotFailRecursively() async {
    let controller = RemoteDesktopController(), rpc = ScreenFixture()
    await controller.connect(machineName: "Fixture") { rpc.connection("fixture") }.value
    // The peer can close its data channel before the main actor observes it.
    // Teardown still tries to release held keys, but that send is best effort.
    controller.controlActive = true
    controller.disconnect()
    #expect(controller.phase == .idle)
    #expect(controller.errorMessage == nil)
    #expect(!controller.controlActive)
    #expect(rpc.closed.withLock { $0 })
}

@Test @MainActor func screenSupersededSetupCannotDisconnectItsSuccessor() async throws {
    let controller = RemoteDesktopController(), route = DelayedScreenRoute()
    let old = ScreenFixture(), current = ScreenFixture()
    let first = controller.connect(machineName: "A") { await route.route() }
    try await waitForSession { await route.waiting }
    let second = controller.connect(machineName: "B") { current.connection("B") }
    await second.value
    await route.finish(old.connection("A")); await first.value
    #expect(controller.routeLabel == "B")
    #expect(controller.machineName == "B")
    #expect(old.closed.withLock { $0 })
    #expect(!current.closed.withLock { $0 })
    controller.disconnect()
    #expect(current.closed.withLock { $0 })
}

private actor TerminalInputFixture: TerminalInputRPC {
    var writes: [Data] = []
    var continuation: CheckedContinuation<Dieter_V1_Terminal, Error>?
    var waiting: Bool { continuation != nil }
    func writeTerminal(id: String, data: Data) async throws -> Dieter_V1_Terminal {
        writes.append(data)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fail() { continuation?.resume(throwing: CocoaError(.fileWriteUnknown)); continuation = nil }
    func finish() { continuation?.resume(returning: .init()); continuation = nil }
}

@Test @MainActor func terminalInputBoundsPendingAndInFlightBytesWithoutRetryingAmbiguousWrites() async throws {
    let input = TerminalInputForwarder(byteLimit: 1_024), rpc = TerminalInputFixture()
    var failures: [String] = []
    input.enqueue(endpointID: "machine", id: "terminal", data: Data(repeating: 1, count: 1_000), rpc: rpc) {
        failures.append($0)
    }
    try await waitForSession { await rpc.waiting }
    input.enqueue(endpointID: "machine", id: "terminal", data: Data(repeating: 2, count: 24), rpc: rpc) {
        failures.append($0)
    }
    input.enqueue(endpointID: "machine", id: "terminal", data: Data([3]), rpc: rpc) { failures.append($0) }
    #expect(input.pendingByteCount == 1_024)
    #expect(failures.count == 1)
    await rpc.fail()
    try await waitForSession { input.pendingByteCount == 0 }
    #expect(await rpc.writes.count == 1)
    #expect(failures.count == 2)
}

@Test @MainActor func terminalRouteReplacementDoesNotReplayOldInputOrClearNewPump() async throws {
    let input = TerminalInputForwarder(), old = TerminalInputFixture(), new = TerminalInputFixture()
    var failures: [String] = []
    input.enqueue(endpointID: "machine", id: "terminal", data: Data([1]), rpc: old) { failures.append($0) }
    try await waitForSession { await old.waiting }
    input.suspend()
    input.enqueue(endpointID: "machine", id: "terminal", data: Data([2]), rpc: new) { failures.append($0) }
    try await waitForSession { await new.waiting }
    await old.fail()
    #expect(input.pendingByteCount == 1)
    await new.finish()
    try await waitForSession { input.pendingByteCount == 0 }
    #expect(failures.isEmpty)
    #expect(await new.writes == [Data([2])])
}

@Test func callbackCancellationCompletesWithoutWaitingForNativeCallback() async throws {
    let callback = Mutex<(@Sendable (Result<Int, Error>) -> Void)?>(nil)
    let task = Task { try await awaitCancellableCallback { finish in callback.withLock { $0 = finish } } as Int }
    for _ in 0..<1_000 {
        if callback.withLock({ $0 != nil }) { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    // A native callback after cancellation is harmless and cannot resume twice.
    callback.withLock { $0 }?(.success(7))
}

@Test @MainActor func screenWakeNotificationReopensOnlyAnIntentionallyOpenTab() async throws {
    let controller = RemoteDesktopController(), rpc = ScreenFixture()
    let session = ScreenShareSession(
        machineID: "wake", machineName: "Fixture", controller: controller, monitorsInactivity: false)
    session.configureInactivityTimeout(enabled: true, minutes: 1)
    var openings = 0
    session.connect {
        openings += 1; return rpc.connection("wake fixture")
    }
    try await waitForSession { openings == 1 }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(controller.systemSleeping)
    #expect(!session.disconnectIfInactive(at: Date().addingTimeInterval(3600)))
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await waitForSession { openings == 2 }
    #expect(!controller.systemSleeping)
    #expect(!session.disconnectIfInactive())
    session.disconnect()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(openings == 2)
    #expect(controller.phase == .idle)
}
