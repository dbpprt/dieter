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

/// A lane's shared sort as its button shows it.
enum BoardCardSortDirection {
    case descending
    case ascending

    init(descending: Bool) { self = descending ? .descending : .ascending }

    var toggled: Self { self == .descending ? .ascending : .descending }
    var title: String { self == .descending ? "Reverse board order" : "Board order" }
    var systemImage: String { self == .descending ? "arrow.down" : "arrow.up" }
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
