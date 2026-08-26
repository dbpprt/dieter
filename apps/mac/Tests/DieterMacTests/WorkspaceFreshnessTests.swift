import Testing
@testable import DieterMac

@Test func workspaceFreshnessRequiresBothATransportAndALiveSyncFrame() {
    #expect(WorkspaceFreshnessState.resolve(
        phase: .connected(version: "1"),
        globalSyncing: false,
        hasCachedWorkspace: true
    ) == .live)
    #expect(WorkspaceFreshnessState.resolve(
        phase: .connected(version: "1"),
        globalSyncing: true,
        hasCachedWorkspace: true
    ) == .syncing)
}

@Test func cachedWorkspaceDistinguishesReconnectFromOffline() {
    #expect(WorkspaceFreshnessState.resolve(
        phase: .connecting,
        globalSyncing: false,
        hasCachedWorkspace: true
    ) == .reconnecting)
    #expect(WorkspaceFreshnessState.resolve(
        phase: .disconnected,
        globalSyncing: false,
        hasCachedWorkspace: true
    ) == .offline)
    #expect(WorkspaceFreshnessState.resolve(
        phase: .connecting,
        globalSyncing: false,
        hasCachedWorkspace: false
    ) == .offline)
}
