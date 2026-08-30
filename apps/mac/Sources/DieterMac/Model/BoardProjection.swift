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
