import DieterClient
import Foundation
import Testing

private struct RouteFailure: Error {}

@Test @MainActor func fastPreferredRouteDoesNotOpenRelay() async throws {
    var fallbacks = 0
    let value = try await HedgedRoute.connect(
        preferred: { "direct" },
        fallback: {
            fallbacks += 1; return "relay"
        }, dispose: { _ in })
    #expect(value == "direct")
    #expect(fallbacks == 0)
}

@Test @MainActor func stalledPreferredRouteDoesNotDelayHealthyRelayAndLateSuccessIsClosed() async throws {
    var pending: CheckedContinuation<String, Never>?
    var disposed: [String] = []
    let value = try await HedgedRoute.connect(
        delay: .milliseconds(10),
        preferred: { await withCheckedContinuation { pending = $0 } },
        fallback: { "relay" }, dispose: { disposed.append($0) })
    #expect(value == "relay")
    #expect(disposed.isEmpty)
    pending?.resume(returning: "late-rtc")
    for _ in 0..<20 where disposed.isEmpty { await Task.yield() }
    #expect(disposed == ["late-rtc"])
}

@Test @MainActor func failedRelayStillAllowsPreferredRouteAndBothFailuresAreReported() async throws {
    var disposed: [String] = []
    let value = try await HedgedRoute.connect(
        delay: .milliseconds(1),
        preferred: {
            try await Task.sleep(for: .milliseconds(30)); return "rtc"
        },
        fallback: { throw RouteFailure() }, dispose: { disposed.append($0) })
    #expect(value == "rtc")
    #expect(disposed.isEmpty)
    await #expect(throws: RouteFailure.self) {
        try await HedgedRoute.connect(
            preferred: { () -> String in throw RouteFailure() },
            fallback: { throw RouteFailure() }, dispose: { _ in })
    }
}

@Test @MainActor func cancelingRouteSelectionClosesLateTransportWithoutReturningIt() async {
    var pending: CheckedContinuation<String, Never>?
    var disposed: [String] = []
    let task = Task {
        try await HedgedRoute.connect(
            preferred: { await withCheckedContinuation { pending = $0 } },
            fallback: { "relay" }, dispose: { disposed.append($0) })
    }
    while pending == nil { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    pending?.resume(returning: "late-rtc")
    for _ in 0..<20 where disposed.isEmpty { await Task.yield() }
    #expect(disposed == ["late-rtc"])
}

@Test @MainActor func cancellationAtSuccessfulDeliveryDisposesSelectedTransport() async {
    var disposed: [String] = []
    var task: Task<String, Error>?
    task = Task {
        try await HedgedRoute.connect(
            preferred: {
                task?.cancel()
                return "canceled-winner"
            },
            fallback: { "relay" }, dispose: { disposed.append($0) })
    }
    await #expect(throws: CancellationError.self) { try await task?.value }
    #expect(disposed == ["canceled-winner"])
}
