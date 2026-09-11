import DieterAPI
import SwiftUI

/// Native List recycles offscreen cards and measures each row from its SwiftUI
/// content, including wrapped labels and the optional merged-task footer.
struct BoardLaneList: View {
    @Environment(DieterStore.self) private var store
    let laneID: String
    let cards: [Dieter_V1_Card]
    let sortDirection: BoardCardSortDirection

    var body: some View {
        List {
            ForEach(cards, id: \.id) { card in
                BoardLaneRow(card: card, laneID: laneID, isLast: card.id == cards.last?.id)
                    .listRowInsets(.all, 0)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Plain List retains 8/9 points of native cell padding even with zero
        // row insets. Offset that here so LaneColumn owns the visible inset.
        .padding(.leading, -8)
        .padding(.trailing, -9)
        // Keep the first insertion target in the header gap, so the first
        // card starts at the same height as an empty lane's drop placeholder.
        .padding(.top, -LaneInsertionTarget.beforeCardHeight)
        .foregroundStyle(DieterTheme.text)
        .accessibilityIdentifier("board.lane.\(laneID)")
        .id(
            LaneIdentity(
                boardID: store.selectedBoardID, laneID: laneID, newestFirst: sortDirection == .descending))
    }

    private struct LaneIdentity: Hashable {
        let boardID: String
        let laneID: String
        let newestFirst: Bool
    }
}

struct BoardLaneRow: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    let laneID: String
    let isLast: Bool
    var body: some View {
        VStack(spacing: 0) {
            LaneInsertionTarget(laneID: laneID, beforeCardID: card.id)
            BoardCardView(card: card)
                .opacity(store.movingCardIDs.contains(card.id) ? 0.48 : 1)
            if isLast {
                LaneInsertionTarget(laneID: laneID, beforeCardID: nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
