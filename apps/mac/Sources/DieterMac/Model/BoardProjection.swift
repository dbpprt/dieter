import DieterAPI
import Foundation

/// A single derivation of the visible board state. SwiftUI consumers reuse the
/// lane and label indexes instead of repeatedly filtering the full card list.
struct BoardProjection: Equatable, Sendable {
    let cards: [Dieter_V1_Card]
    let displayedCards: [Dieter_V1_Card]
    let displayedCardsByLane: [String: [Dieter_V1_Card]]
    let labelCounts: [String: Int]

    static let empty = BoardProjection(
        cards: [],
        displayedCards: [],
        displayedCardsByLane: [:],
        labelCounts: [:]
    )

    static func resolve(
        cards: [Dieter_V1_Card],
        boardID: String,
        runtimeFilter: String,
        labelFilter: String,
        query: String
    ) -> BoardProjection {
        let boardCards = boardID.isEmpty ? cards : cards.filter { $0.boardID == boardID }
        var labelCounts: [String: Int] = [:]
        for card in boardCards {
            for labelID in card.labelIds { labelCounts[labelID, default: 0] += 1 }
        }
        let displayed = boardCards.filter { card in
            (runtimeFilter.isEmpty || card.runtime == runtimeFilter) &&
                (labelFilter.isEmpty || card.labelIds.contains(labelFilter)) &&
                (query.isEmpty ||
                    card.title.localizedCaseInsensitiveContains(query) ||
                    card.summary.localizedCaseInsensitiveContains(query))
        }
        return BoardProjection(
            cards: boardCards,
            displayedCards: displayed,
            displayedCardsByLane: Dictionary(grouping: displayed, by: \.lane),
            labelCounts: labelCounts
        )
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
