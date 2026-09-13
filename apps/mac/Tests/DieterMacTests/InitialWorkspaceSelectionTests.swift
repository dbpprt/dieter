import DieterAPI
import Foundation
import Testing
@testable import DieterMac

@Test @MainActor func cachedMachineRestoreSelectsAfterBuildingTheCompleteSidebar() async throws {
    let suiteName = "DieterInitialWorkspaceSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let root = FileManager.default.temporaryDirectory
        .appending(path: "dieter-initial-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = DieterSyncPersistence(root: root)
    let environment = DieterAppEnvironment.testing(defaults: defaults)
    let store = DieterStore(
        environment: environment,
        syncPersistenceOverride: persistence,
        restoreSync: false
    )

    var firstProject = Dieter_V1_Project()
    firstProject.id = "p_first_machine"
    firstProject.name = "Dieter"
    var preferredProject = Dieter_V1_Project()
    preferredProject.id = "p_preferred_machine"
    preferredProject.name = "Dieter"
    var preferredBoard = Dieter_V1_Board()
    preferredBoard.id = "b_preferred"
    preferredBoard.projectID = preferredProject.id
    preferredBoard.name = "Main"

    SidebarProjectNavigationPreferences(
        projectOrder: [preferredProject.id, firstProject.id]
    ).save(to: defaults)
    store.sidebarProjectNavigation = .load(from: defaults)

    var firstSnapshot = Dieter_V1_GlobalSnapshot()
    firstSnapshot.state.projects = [firstProject]
    var preferredSnapshot = Dieter_V1_GlobalSnapshot()
    preferredSnapshot.state.projects = [preferredProject]
    preferredSnapshot.state.boards = [preferredBoard]

    let prefix = store.activeGateway.credentialID + "#"
    try await persistence.save(
        .init(projections: [
            prefix + "a-first": .init(cursor: nil, snapshot: try firstSnapshot.serializedData()),
            prefix + "z-preferred": .init(cursor: nil, snapshot: try preferredSnapshot.serializedData()),
        ]))

    await store.restorePersistentSync()

    #expect(store.projects.map(\.id).sorted() == [firstProject.id, preferredProject.id].sorted())
    #expect(store.selectedProjectID == preferredProject.id)
    #expect(store.selectedBoardID == preferredBoard.id)
    #expect(store.state.project.id == preferredProject.id)
    #expect(store.selectedBoard?.id == preferredBoard.id)
}
