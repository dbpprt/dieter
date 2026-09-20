import AppKit
import DieterAPI
import DieterCore
import Synchronization
import Testing
@testable import DieterMac

@Suite(.serialized) @MainActor struct RemoteDesktopDisplayMatchingTests {
    @Test func choosesRetinaGeometryBeforeRefreshRateAndRejectsInvalidModes() {
        let target = RemoteDesktopDisplayTarget(width: 1440, height: 900, scale: 2, refresh: 120)
        let scaled = mode("retina", 1440, 900, 2880, 1800, 60)
        let tiny = mode("tiny", 2880, 1800, 2880, 1800, 120)
        let low = mode("low", 1440, 900, 1440, 900, 120)
        #expect(target.bestMode(in: [.init(), tiny, low, scaled])?.id == "retina")
        #expect(target.exactlyMatches(scaled))
        #expect(!target.exactlyMatches(low))
        #expect(target.bestMode(in: [.init()]) == nil)
        let fast = mode("fast", 1440, 900, 2880, 1800, 120)
        #expect(target.bestMode(in: [scaled, fast])?.id == "fast")
    }

    @Test func exitingWhileApplyIsInFlightRestoresAfterTheReply() async throws {
        let rpc = DisplayMatchingRPC()
        let matcher = RemoteDesktopDisplayMatching()
        matcher.update(.init(rpc: rpc, sessionID: "viewer", displayID: "screen", target: target))
        try await waitUntil { rpc.state.withLock { $0.setStarted } }
        matcher.update(nil)
        try await waitUntil { !matcher.busy }
        #expect(rpc.state.withLock { $0.operations } == ["list", "set", "restore"])
        #expect(rpc.state.withLock { $0.current } == "original")
    }

    @Test func failedOrRepeatedUpdatesDoNotContinuouslyChangeTheDesktop() async throws {
        let rpc = DisplayMatchingRPC(failAfterSet: true)
        let matcher = RemoteDesktopDisplayMatching()
        let intent = RemoteDesktopDisplayMatching.Intent(
            rpc: rpc, sessionID: "viewer", displayID: "screen", target: target)
        matcher.update(intent)
        try await waitUntil { matcher.status.contains("unavailable") }
        for _ in 0..<10 { matcher.update(intent) }
        try await Task.sleep(for: .milliseconds(450))
        #expect(rpc.state.withLock { $0.operations } == ["list", "set", "restore"])
        #expect(rpc.state.withLock { $0.current } == "original")
    }

    @Test func experimentalPreferenceDefaultsOffAndPersists() throws {
        let suite = "screen-resolution-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ScreensModel(defaults: defaults)
        #expect(!model.matchClientResolution)
        #expect(model.captureFullscreenKeyboard)
        model.matchClientResolution = true
        model.captureFullscreenKeyboard = false
        let restored = ScreensModel(defaults: defaults)
        #expect(restored.matchClientResolution)
        #expect(!restored.captureFullscreenKeyboard)
    }

    private var target: RemoteDesktopDisplayTarget { .init(width: 1280, height: 720, scale: 1, refresh: 60) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Display matching did not settle")
    }
    private func mode(_ id: String, _ w: Int32, _ h: Int32, _ pw: Int32, _ ph: Int32, _ rate: Double)
        -> Dieter_V1_RemoteDesktopDisplayMode
    {
        var value = Dieter_V1_RemoteDesktopDisplayMode()
        value.id = id; value.logicalWidth = w; value.logicalHeight = h
        value.pixelWidth = pw; value.pixelHeight = ph; value.refreshRate = rate
        return value
    }
}

private final class DisplayMatchingRPC: ScreenSignalingRPC, @unchecked Sendable {
    struct State { var current = "original"; var operations: [String] = []; var setStarted = false }
    let state = Mutex(State())
    let failAfterSet: Bool
    init(failAfterSet: Bool = false) { self.failAfterSet = failAfterSet }
    func remoteDesktopDisplayModes(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes {
        var result = Dieter_V1_RemoteDesktopDisplayModes(); result.displayID = "screen"
        result.currentModeID = state.withLock {
            $0.operations.append("list"); return $0.current
        }
        var mode = Dieter_V1_RemoteDesktopDisplayMode()
        mode.id = "matched"; mode.logicalWidth = 1280; mode.logicalHeight = 720
        mode.pixelWidth = 1280; mode.pixelHeight = 720; mode.refreshRate = 60
        result.modes = [mode]; return result
    }
    func setRemoteDesktopDisplayMode(_ request: Dieter_V1_SetRemoteDesktopDisplayModeRequest) async throws
        -> Dieter_V1_RemoteDesktopDisplayModes
    {
        state.withLock {
            $0.operations.append("set"); $0.current = request.modeID; $0.setStarted = true
        }
        try await Task.sleep(for: .milliseconds(200))
        if failAfterSet { throw CancellationError() }
        var result = Dieter_V1_RemoteDesktopDisplayModes(); result.temporary = true; return result
    }
    func restoreRemoteDesktopDisplayMode(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes {
        state.withLock {
            $0.operations.append("restore"); $0.current = "original"
        }
        return .init()
    }
    func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities { .init() }
    func startRemoteDesktop(
        _ request: Dieter_V1_StartRemoteDesktopRequest,
        receive: @escaping @Sendable (Dieter_V1_RemoteDesktopSignal) async throws -> Void
    ) async throws {}
    func sendRemoteDesktopSignal(_ signal: Dieter_V1_RemoteDesktopSignal) async throws {}
    func remoteDesktopSession(sessionID: String) async throws -> Dieter_V1_RemoteDesktopSessionState { .init() }
    func updateRemoteDesktopSession(_ request: Dieter_V1_UpdateRemoteDesktopSessionRequest) async throws
        -> Dieter_V1_RemoteDesktopSessionState
    { .init() }
    func setRemoteDesktopControl(sessionID: String, take: Bool) async throws -> Dieter_V1_RemoteDesktopSessionState {
        .init()
    }
    func closeRemoteDesktop(sessionID: String) async throws {}
    func shutdown() {}
}
