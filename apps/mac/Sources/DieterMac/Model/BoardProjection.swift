import DieterAPI
import DieterShared
import Foundation

/// The selected board as the shared core's board view shows it: its lanes
/// with their shown cards top to bottom, counts, and filter chrome. Each
/// shown card's data is looked up once from the workspace.
struct BoardProjection: Equatable {
    var view = ClientBoardViewSlice()
    /// The lanes drawn: the core's, or the board's own without cards until
    /// the core shows the board.
    var lanes: [ClientBoardLaneView] = []
    /// Lane ID → its shown cards, top to bottom.
    var cardsByLane: [String: [Dieter_V1_Card]] = [:]

    static let empty = BoardProjection()

    static func resolve(view: ClientBoardViewSlice, board: Dieter_V1_Board?, cards: [Dieter_V1_Card])
        -> BoardProjection
    {
        guard let board else { return .empty }
        guard view.target.boardID == board.id, !view.lanes.isEmpty else {
            return BoardProjection(
                lanes: board.lanes.map { lane in
                    .with {
                        $0.laneID = lane.id
                        $0.name = lane.name
                        $0.kind = ClientBoardLaneKind(laneID: lane.id, name: lane.name)
                        $0.descending = true
                    }
                })
        }
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var cardsByLane: [String: [Dieter_V1_Card]] = [:]
        for lane in view.lanes { cardsByLane[lane.laneID] = lane.cardIds.compactMap { byID[$0] } }
        return BoardProjection(view: view, lanes: view.lanes, cardsByLane: cardsByLane)
    }

    /// Every shown card, lane by lane.
    var displayedCards: [Dieter_V1_Card] { lanes.flatMap { cardsByLane[$0.laneID] ?? [] } }
}

extension ClientBoardLaneKind {
    /// A lane's kind as the shared core reads it from the lane's ID, else its name.
    init(laneID: String, name: String) {
        self = ClientBoardLaneKind(rawValue: Int(SharedRules.shared.laneKind(laneId: laneID, laneName: name))) ?? .other
    }
}

/// Bounds the number of heavyweight card views mounted in a lane while keeping
/// every card reachable. This is deliberately page-based because macOS lazy
/// stacks can loop while resolving anchors for variable-height drop targets.
struct LaneCardPage: Equatable, Sendable {
    static let defaultSize = 40

    let page: Int
    let pageCount: Int
    let lowerBound: Int
    let upperBound: Int
    let total: Int

    var canGoBackward: Bool { page > 0 }
    var canGoForward: Bool { page + 1 < pageCount }
    var rangeLabel: String {
        total == 0 ? "0 of 0" : "\(lowerBound + 1)–\(upperBound) of \(total)"
    }

    static func resolve(total: Int, requestedPage: Int, pageSize: Int = defaultSize) -> LaneCardPage {
        let safeTotal = max(0, total)
        let safeSize = max(1, pageSize)
        let pageCount = max(1, (safeTotal + safeSize - 1) / safeSize)
        let page = min(max(0, requestedPage), pageCount - 1)
        let lowerBound = min(safeTotal, page * safeSize)
        let upperBound = min(safeTotal, lowerBound + safeSize)
        return LaneCardPage(
            page: page,
            pageCount: pageCount,
            lowerBound: lowerBound,
            upperBound: upperBound,
            total: safeTotal
        )
    }
}
