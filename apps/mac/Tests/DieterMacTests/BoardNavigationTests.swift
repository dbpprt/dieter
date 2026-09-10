import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test @MainActor func openingALiveSynchronizedBoardDoesNotIssueGetState() async throws {
    let store = DieterStore(restoreSync: false)
    var project = Dieter_V1_Project(); project.id = "project"
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = project.id
    var state = Dieter_V1_State(); state.projects = [project]; state.project = project; state.boards = [board]
    var snapshot = Dieter_V1_GlobalSnapshot(); snapshot.state = state
    store.state = state
    store.syncSnapshot = snapshot
    store.projectDirectory = [project.id: project]
    store.navigationBoards = [project.id: [board]]
    store.phase = .connected(version: "fixture")
    // This closed channel fails immediately if navigation mistakenly calls it.
    // No listener, live service, credentials, or network connection is used.
    let rpc = try DieterRPC(endpoint: store.endpoint)
    rpc.shutdown()
    store.rpc = rpc
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
    store.projectEndpointIDs[project.id] = "another-machine"
    #expect(!store.hasLiveBoardProjection(projectID: project.id))
    store.projectEndpointIDs.removeAll()
    store.syncSnapshot = nil
    #expect(!store.hasLiveBoardProjection(projectID: project.id))
}
