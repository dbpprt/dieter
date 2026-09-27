import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct BoardCardDragPayload: Sendable {
    let cardID: String
    let boardID: String
    let sourceLane: String

    var encoded: String { "board-card|\(boardID)|\(sourceLane)|\(cardID)" }

    init(cardID: String, boardID: String, sourceLane: String) {
        self.cardID = cardID
        self.boardID = boardID
        self.sourceLane = sourceLane
    }

    init?(_ encoded: String) {
        let values = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard values.count == 4, values[0] == "board-card", !values[1].isEmpty, !values[3].isEmpty
        else { return nil }
        boardID = values[1]
        sourceLane = values[2]
        cardID = values[3]
    }
}

struct BoardLabelDragPayload: Sendable {
    let labelID: String
    let boardID: String

    var encoded: String { "board-label|\(boardID)|\(labelID)" }

    init(labelID: String, boardID: String) {
        self.labelID = labelID
        self.boardID = boardID
    }

    init?(_ encoded: String) {
        let values = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard values.count == 3, values[0] == "board-label", !values[1].isEmpty, !values[2].isEmpty
        else { return nil }
        boardID = values[1]
        labelID = values[2]
    }
}

enum BoardLabelAssignment {
    static func adding(_ labelID: String, to ids: [String]) -> [String] {
        ids.contains(labelID) ? ids : ids + [labelID]
    }
}

enum BoardCardEditingPolicy {
    static func canEditDraft(_ card: Dieter_V1_Card) -> Bool {
        card.lane.caseInsensitiveCompare("todo") == .orderedSame && card.mergedIntoCardID.isEmpty
            && card.initialPromptSentAt.isEmpty
            && !card.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BoardCardStartPolicy {
    static func runningLaneID(in board: Dieter_V1_Board?) -> String? {
        guard let board else { return nil }
        return board.lanes.first { $0.id.caseInsensitiveCompare("running") == .orderedSame }?.id
            ?? board.lanes.first { $0.name.caseInsensitiveCompare("running") == .orderedSame }?.id
    }

    static func canStart(
        _ card: Dieter_V1_Card,
        board: Dieter_V1_Board?,
        hasDraftAttachments: Bool = false
    ) -> Bool {
        card.scope == "board" && card.lane.caseInsensitiveCompare("todo") == .orderedSame
            && card.mergedIntoCardID.isEmpty && card.initialPromptSentAt.isEmpty
            && (!card.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasDraftAttachments)
            && runningLaneID(in: board) != nil
    }

    static func optimisticCard(
        _ card: Dieter_V1_Card,
        board: Dieter_V1_Board?,
        hasDraftAttachments: Bool = false
    ) -> Dieter_V1_Card? {
        guard canStart(card, board: board, hasDraftAttachments: hasDraftAttachments),
            let runningLaneID = runningLaneID(in: board)
        else { return nil }
        var card = card
        card.lane = runningLaneID
        card.runtime = "starting"
        return card
    }
}

enum BoardDropOrdering {
    static func neighbors(
        before target: String?, movingCardID: String, cards: [Dieter_V1_Card],
        direction: BoardCardSortDirection, moves: [String: OptimisticCardMove] = [:]
    ) -> (after: String, before: String) {
        let visible = BoardCardOrdering.sorted(
            cards.filter { $0.id != movingCardID }, direction: direction, moves: moves)
        let index = target.flatMap { id in visible.firstIndex { $0.id == id } } ?? visible.count
        let preceding = index > 0 ? visible[index - 1].id : ""
        let following = index < visible.count ? visible[index].id : ""
        return direction == .ascending ? (preceding, following) : (following, preceding)
    }

}

enum BoardCardSortDirection {
    case descending
    case ascending

    var toggled: Self { self == .descending ? .ascending : .descending }
    var title: String { self == .descending ? "Reverse board order" : "Board order" }
    var systemImage: String { self == .descending ? "arrow.down" : "arrow.up" }
}

enum BoardCardOrdering {
    static func sorted(
        _ cards: [Dieter_V1_Card],
        direction: BoardCardSortDirection = .descending,
        moves: [String: OptimisticCardMove] = [:]
    ) -> [Dieter_V1_Card] {
        var ordered = cards.sorted { left, right in
            if left.orderKey != right.orderKey { return left.orderKey < right.orderKey }
            if left.orderKey.isEmpty, left.position != right.position { return left.position < right.position }
            return left.id < right.id
        }
        for (id, move) in moves.sorted(by: { $0.key < $1.key }) {
            guard let index = ordered.firstIndex(where: { $0.id == id && $0.lane == move.lane }) else { continue }
            let card = ordered.remove(at: index)
            let insertion =
                ordered.firstIndex { $0.id == move.beforeCardID }
                ?? ordered.firstIndex { $0.id == move.afterCardID }.map { $0 + 1 }
                ?? ordered.count
            ordered.insert(card, at: insertion)
        }
        return direction == .ascending ? ordered : ordered.reversed()
    }
}

enum KanbanLaneSizing {
    static let horizontalPadding: CGFloat = 14
    static let spacing: CGFloat = 9
    // Lanes never squeeze below a readable card width; the board falls back to
    // horizontal scrolling instead.
    static let minimumWidth: CGFloat = 264

    static func laneWidth(availableWidth: CGFloat, laneCount: Int) -> CGFloat {
        guard laneCount > 0 else { return 0 }
        let gaps = spacing * CGFloat(max(0, laneCount - 1))
        let fittedWidth = (availableWidth - (horizontalPadding * 2) - gaps) / CGFloat(laneCount)
        return max(minimumWidth, fittedWidth)
    }

    static func contentWidth(availableWidth: CGFloat, laneCount: Int) -> CGFloat {
        guard laneCount > 0 else { return availableWidth }
        return (horizontalPadding * 2)
            + (laneWidth(availableWidth: availableWidth, laneCount: laneCount) * CGFloat(laneCount))
            + (spacing * CGFloat(max(0, laneCount - 1)))
    }
}

enum BoardPresentationState: Equatable {
    case loading
    case empty
    case loaded

    static func resolve(
        hasLoadedWorkspace: Bool,
        selectedBoardID: String,
        hasSelectedBoard: Bool
    ) -> Self {
        if hasSelectedBoard { return .loaded }
        if !hasLoadedWorkspace || !selectedBoardID.isEmpty { return .loading }
        return .empty
    }
}
