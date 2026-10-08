import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct KanbanView: View {
    @Environment(DieterStore.self) private var store
    let board: Dieter_V1_Board

    var body: some View {
        let projection = store.boardProjection
        let lanes = projection.lanes
        GeometryReader { geometry in
            let laneWidth = KanbanLaneSizing.laneWidth(
                availableWidth: geometry.size.width, laneCount: lanes.count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: KanbanLaneSizing.spacing) {
                    ForEach(lanes, id: \.laneID) { lane in
                        LaneColumn(
                            lane: lane,
                            cards: projection.cardsByLane[lane.laneID] ?? [],
                            onToggleSort: { store.toggleLaneSort(board: board.id, lane: lane) }
                        )
                        .frame(width: laneWidth, height: max(0, geometry.size.height - 4))
                    }
                }
                .padding(.horizontal, KanbanLaneSizing.horizontalPadding).padding(.top, 0).padding(.bottom, 4)
                .frame(
                    minWidth: geometry.size.width, alignment: .topLeading
                )
                .frame(height: geometry.size.height, alignment: .top)
            }
        }
    }
}

struct LaneColumn: View {
    @Environment(DieterStore.self) private var store
    let lane: ClientBoardLaneView
    let cards: [Dieter_V1_Card]
    let onToggleSort: () -> Void
    @State private var isDropTargeted = false

    private var sortDirection: BoardCardSortDirection { BoardCardSortDirection(descending: lane.descending) }

    /// New cards may start in any lane before review.
    private var acceptsNewCards: Bool { lane.kind != .review && lane.kind != .done }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Text(lane.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                DieterCountBadge(count: cards.count)
                Spacer(minLength: 4)
                Button(action: onToggleSort) {
                    Image(systemName: sortDirection.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .smokeTarget("lane-sort.\(lane.laneID).\(sortDirection.systemImage)")
                        .id(sortDirection.systemImage)
                }
                .buttonStyle(.plain)
                .quickHelp("Sort \(sortDirection.toggled.title.lowercased())")
                .accessibilityLabel("\(lane.name) lane sorted \(sortDirection.title.lowercased())")
                .accessibilityHint("Sort \(sortDirection.toggled.title.lowercased())")
                .accessibilityIdentifier("lane-sort.\(lane.laneID)")
                .smokeTarget("lane-sort.\(lane.laneID)")
                Button {
                    store.newCardLaneID = acceptsNewCards ? lane.laneID : ""
                    store.createConversationPresented = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 24))
                .quickHelp("New card")
                .accessibilityLabel("New card in \(lane.name)")
                .accessibilityIdentifier("board.lane.\(lane.laneID).new-card")
            }
            .padding(.leading, 4).padding(.trailing, 2)
            .frame(height: 30)
            if cards.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle").font(
                        .system(size: 17, weight: .light))
                    Text(isDropTargeted ? "Release to move" : "Drop cards here")
                }
                .font(.caption).foregroundStyle(isDropTargeted ? DieterTheme.text : DieterTheme.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
                .overlay(
                    RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
                        .strokeBorder(DieterTheme.tileRim, style: .init(lineWidth: 1, dash: [4, 4])))
                Spacer(minLength: 0)
            } else {
                BoardLaneList(laneID: lane.laneID, cards: cards, sortDirection: sortDirection)
            }
        }
        .padding(.horizontal, isDropTargeted ? 6 : 0).padding(.vertical, isDropTargeted ? 4 : 0)
        .background {
            // The lane sits on the canvas; only a drag in flight outlines it.
            RoundedRectangle(cornerRadius: DieterMetrics.cardRadius + 4, style: .continuous)
                .fill(isDropTargeted ? DieterTheme.tile : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: DieterMetrics.cardRadius + 4, style: .continuous)
                        .strokeBorder(isDropTargeted ? DieterTheme.tileRimSelected : .clear, lineWidth: 1)
                }
                .padding(.horizontal, isDropTargeted ? 0 : -6)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: isDropTargeted)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = BoardCardDragPayload(value),
                payload.boardID == store.selectedBoardID
            else { return false }
            let laneID = lane.laneID
            Task { await store.drop(cardID: payload.cardID, laneID: laneID) }
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }
}

struct LaneInsertionTarget: View {
    static let beforeCardHeight: CGFloat = 9

    @Environment(DieterStore.self) private var store
    let laneID: String
    let beforeCardID: String?
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            if targeted {
                HStack(spacing: 6) {
                    Circle().fill(DieterTheme.action).frame(width: 5, height: 5)
                    Capsule().fill(DieterTheme.action).frame(height: 2)
                }.padding(.horizontal, 2)
            }
        }
        .frame(height: beforeCardID == nil ? 12 : Self.beforeCardHeight)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = BoardCardDragPayload(value),
                payload.boardID == store.selectedBoardID
            else { return false }
            let laneID = laneID, beforeCardID = beforeCardID ?? ""
            Task { await store.drop(cardID: payload.cardID, laneID: laneID, beforeCardID: beforeCardID) }
            return true
        } isTargeted: {
            targeted = $0
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}
