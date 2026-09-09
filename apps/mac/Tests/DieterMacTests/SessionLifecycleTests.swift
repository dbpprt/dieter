import DieterAPI
import DieterCore
import Foundation
import Synchronization
import Testing
@testable import DieterMac

private final class ScreenFixture: ScreenSignalingRPC {
    let closed = Mutex(false)
    func shutdown() { closed.withLock { $0 = true } }
    func remoteDesktopSettings() async throws -> Dieter_V1_RemoteDesktopSettings { .init() }
    func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities { .init() }
    func updateRemoteDesktopSettings(enabled: Bool, controlEnabled: Bool) async throws
        -> Dieter_V1_RemoteDesktopSettings
    { .init() }
    func startRemoteDesktop(
        _ request: Dieter_V1_StartRemoteDesktopRequest,
        receive: @escaping @Sendable (Dieter_V1_RemoteDesktopSignal) async throws -> Void
    ) async throws {}
    func sendRemoteDesktopSignal(_ signal: Dieter_V1_RemoteDesktopSignal) async throws {}
    func closeRemoteDesktop(sessionID: String) async throws {}
    func connection(_ label: String) -> RemoteDesktopSignalingConnection {
        .init(
            rpc: self, connectionTask: Task {}, rtcConfiguration: .init(), daemonCertificatePEM: Data(),
            routeLabel: label)
    }
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
