import DieterAPI
import Foundation
import SharedCore
import Testing
@testable import DieterMac

@Test @MainActor func selectedRetiredBoardStaysSelectedUntilRestored() {
    let store = DieterStore(liveEnvironment: false)
    var project = Dieter_V1_Project(); project.id = "project"
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = project.id
    var state = Dieter_V1_State(); state.projects = [project]; state.project = project; state.boards = [board]
    store.foldFixture(state)
    store.selectedBoardID = board.id
    var retired = board; retired.retired = true
    state.boards = []
    store.foldFixture(state, retiredBoards: [retired])
    #expect(store.selectedBoardID == board.id)
    #expect(store.selectedBoard?.retired == true)
    #expect(store.navigationBoards[project.id]?.isEmpty != false)
    state.boards = [board]
    store.foldFixture(state)
    #expect(store.selectedBoard?.retired == false)
    #expect(store.navigationBoards[project.id]?.map(\.id) == [board.id])
}

@Test @MainActor func restoringABoardRefreshesTheWorkspaceOnce() async {
    let core = ScriptedCoreClient()
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = "project"
    core.handler = { _ in .with { $0.board = board } }
    let store = DieterStore(core: core, liveEnvironment: false)
    store.phase = .connected(version: "fixture")
    store.workspaceIsLive = true
    let before = store.stateRefreshCount
    await store.restoreBoard(board.id)
    #expect(store.stateRefreshCount == before + 1)
}
