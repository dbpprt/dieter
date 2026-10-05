import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test @MainActor func openingABoardNeverRefreshesTheWorkspace() async throws {
    let store = DieterStore(liveEnvironment: false)
    var project = Dieter_V1_Project(); project.id = "project"
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = project.id
    var state = Dieter_V1_State(); state.projects = [project]; state.project = project; state.boards = [board]
    store.foldFixture(state)
    store.phase = .connected
    let generation = store.stateRefreshCount
    // Every machine's stream keeps the workspace live, caught up or not.
    for synced in [true, false] {
        store.workspaceIsLive = synced
        store.openBoard(board.id, projectID: project.id)
        store.selectBoard(board.id)
        #expect(store.selectedBoardID == board.id)
    }
    #expect(store.stateRefreshCount == generation)
    #expect(store.phase.isConnected)
}
