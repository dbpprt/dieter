import Foundation
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

@Test func refreshingWorkspaceStaysReadableAndInteractive() {
    let refreshing = WorkspaceSurfaceTreatment.resolve(
        showsSynchronizedWorkspace: true,
        hasCachedWorkspace: true,
        freshness: .syncing
    )
    #expect(refreshing == .refreshing)
    #expect(refreshing.showsNotice)
    #expect(!refreshing.blocksInteraction)
}

@Test func unavailableWorkspaceUsesAReadOnlyCachedSurface() {
    for freshness in [WorkspaceFreshnessState.reconnecting, .offline] {
        let treatment = WorkspaceSurfaceTreatment.resolve(
            showsSynchronizedWorkspace: true,
            hasCachedWorkspace: true,
            freshness: freshness
        )
        #expect(treatment == .unavailable)
        #expect(treatment.blocksInteraction)
    }
    #expect(WorkspaceSurfaceTreatment.resolve(
        showsSynchronizedWorkspace: false,
        hasCachedWorkspace: true,
        freshness: .offline
    ) == .current)
}

@Test func syncFreshnessSeparatesConnectionAndUpdateLanguage() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(SyncFreshnessPresentation.lastUpdateLabel(lastUpdatedAt: nil, now: now) == "Not updated yet")
    #expect(SyncFreshnessPresentation.lastUpdateLabel(
        lastUpdatedAt: now.addingTimeInterval(-360),
        now: now
    ) == "Updated 6m ago")
}
