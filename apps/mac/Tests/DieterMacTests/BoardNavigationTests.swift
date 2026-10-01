import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test @MainActor func openingALiveSynchronizedBoardDoesNotIssueGetState() async throws {
    let store = DieterStore(restoreSync: false)
    var project = Dieter_V1_Project(); project.id = "project"
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = project.id
    var state = Dieter_V1_State(); state.projects = [project]; state.project = project; state.boards = [board]
    store.foldFixture(state)
    store.phase = .connected(version: "fixture")
    let generation = store.stateRequestGeneration
    await store.openBoard(board.id, projectID: project.id)
    await store.selectBoard(board.id)
    #expect(store.selectedBoardID == board.id)
    #expect(store.stateRequestGeneration == generation)
    #expect(store.phase.isConnected)
    #expect(store.hasLiveBoardProjection(projectID: project.id))
    store.globalSyncing = true
    #expect(!store.hasLiveBoardProjection(projectID: project.id))
    store.globalSyncing = false
    store.projectReplicaEndpointIDs[project.id] = "another-machine"
    #expect(store.hasLiveBoardProjection(projectID: project.id))
    #expect(!store.hasLiveBoardProjection(projectID: "unknown"))
}
