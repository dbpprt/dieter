import DieterAPI
import DieterCore
import Foundation
import Testing
@testable import DieterMac

@Test func sharedBoardLifecycleFixture() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let contents = try String(
        contentsOf: root.appendingPathComponent("tests/fixtures/board-lifecycle.tsv"), encoding: .utf8)
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
        let columns = line.split(separator: "\t").map(String.init)
        var current: Dieter_V1_Board?
        for observation in columns[1].split(separator: ";") {
            var board = Dieter_V1_Board(); board.id = "b_fixture"; board.projectID = "project"
            if observation != "-" {
                let pair = observation.split(separator: "=")
                var version = Dieter_V1_BoardRetirementVersion()
                for entry in pair[0].split(separator: ",") {
                    let clock = entry.split(separator: ":")
                    version.clock[String(clock[0])] = UInt64(clock[1])!
                }
                version.rank = String(observation); version.retired = pair[1] == "true"
                board.retirementVersions = [version]; board.retired = version.retired
                board.retirementRevision = String(observation)
            }
            current = BoardLifecycleProjection.merge(board, with: current)
        }
        var project = Dieter_V1_Project(); project.id = "project"
        var card = Dieter_V1_Card(); card.id = "card"; card.boardID = "b_fixture"; card.projectID = project.id
        let initial = MachineDirectoryProjection(
            projects: [project.id: project], projectReplicaEndpointIDs: [:],
            boards: [project.id: [current!]], cards: [project.id: columns[2] == "true" ? [card] : []], chats: [])
        let endpoint = DieterEndpoint(name: "Peer", host: "test", port: 443, daemonID: "peer")
        let result = MachineDirectoryReducer.merging(
            initial,
            snapshots: [
                MachineSnapshot(
                    endpoint: endpoint, connection: .init(route: .gateway, latencyMilliseconds: 0),
                    projects: [project], boards: [], cards: [], chats: [])
            ])
        let board = result.retiredBoards["b_fixture"] ?? result.boards[project.id]!.first!
        #expect(board.retired == (columns[3] == "true"), "\(columns[0])")
        #expect(board.retirementBlocked == (columns[4] == "true"), "\(columns[0])")
        #expect(result.projects[project.id]?.boardCount == (board.retired ? 0 : 1))
    }
}

@Test func laterRetirementCannotEraseKnownBlockingReferences() {
    var known = Dieter_V1_Board(); known.id = "board"
    var version = Dieter_V1_BoardRetirementVersion(); version.clock = ["a": 1]; version.rank = "a";
    version.retired = true
    known.retirementVersions = [version]; known.retirementBlocked = true; known.retirementReferences = ["item/offline"]
    var later = known; later.retirementVersions[0].clock = ["a": 2]; later.retirementVersions[0].rank = "b"
    later.retirementBlocked = false; later.retired = true; later.retirementReferences = []
    let merged = BoardLifecycleProjection.merge(later, with: known)
    #expect(!merged.retired && merged.retirementBlocked)
    #expect(merged.retirementReferences == ["item/offline"])
}

@Test @MainActor func selectedRetiredBoardStaysSelectedUntilRestored() {
    let store = DieterStore(restoreSync: false)
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
