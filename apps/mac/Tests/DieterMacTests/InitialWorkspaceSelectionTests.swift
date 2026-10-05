import DieterAPI
import Foundation
import Testing
@testable import DieterMac

@Test @MainActor func cachedWorkspaceSelectsTheSidebarsFirstProjectOnceItArrives() async throws {
    let suiteName = "DieterInitialWorkspaceSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = DieterStore(environment: .testing(defaults: defaults), liveEnvironment: false)

    var firstProject = Dieter_V1_Project()
    firstProject.id = "p_listed_first"
    firstProject.name = "Dieter"
    var preferredProject = Dieter_V1_Project()
    preferredProject.id = "p_sidebar_first"
    preferredProject.name = "Dieter"
    var preferredBoard = Dieter_V1_Board()
    preferredBoard.id = "b_preferred"
    preferredBoard.projectID = preferredProject.id
    preferredBoard.name = "Main"
    store.foldNavigation(
        .with { $0.projects = .with { $0.order = [preferredProject.id, firstProject.id] } })

    // The core restores every cached machine's view as one merged workspace.
    var state = Dieter_V1_State()
    state.projects = [firstProject, preferredProject]
    state.boards = [preferredBoard]
    store.foldFixture(state)

    #expect(store.projects.map(\.id).sorted() == [firstProject.id, preferredProject.id].sorted())
    #expect(store.selectedProjectID == preferredProject.id)
    #expect(store.selectedBoardID == preferredBoard.id)
    #expect(store.state.project.id == preferredProject.id)
    #expect(store.selectedBoard?.id == preferredBoard.id)
}
