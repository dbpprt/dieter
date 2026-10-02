import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test @MainActor func openingALiveSynchronizedBoardDoesNotRefreshTheWorkspace() async throws {
    let store = DieterStore(liveEnvironment: false)
    var project = Dieter_V1_Project(); project.id = "project"
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = project.id
    var state = Dieter_V1_State(); state.projects = [project]; state.project = project; state.boards = [board]
    store.foldFixture(state)
    store.phase = .connected(version: "fixture")
    store.workspaceIsLive = true
    let generation = store.stateRefreshCount
    await store.openBoard(board.id, projectID: project.id)
    await store.selectBoard(board.id)
    #expect(store.selectedBoardID == board.id)
    #expect(store.stateRefreshCount == generation)
    #expect(store.phase.isConnected)
    #expect(store.hasLiveBoardProjection(projectID: project.id))
    store.workspaceIsLive = false
    #expect(!store.hasLiveBoardProjection(projectID: project.id))
    store.workspaceIsLive = true
    store.projectReplicaEndpointIDs[project.id] = "another-machine"
    #expect(store.hasLiveBoardProjection(projectID: project.id))
    #expect(!store.hasLiveBoardProjection(projectID: "unknown"))
    // Without a live projection the board asks for a refresh, which the count records.
    store.workspaceIsLive = false
    await store.selectBoard(board.id)
    #expect(store.stateRefreshCount == generation + 1)
}
