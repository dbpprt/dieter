import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct KanbanView: View {
    @Environment(DieterStore.self) private var store
    var usesTitlebarSpace = false
    var active = true
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
                        .frame(width: laneWidth, height: max(0, geometry.size.height - 24))
                    }
                }
                .padding(.horizontal, KanbanLaneSizing.horizontalPadding).padding(.vertical, 12)
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
    var usesTitlebarSpace = false
    var active = true
    let lane: ClientBoardLaneView
    let cards: [Dieter_V1_Card]
    let onToggleSort: () -> Void
    @State private var isDropTargeted = false

    private var sortDirection: BoardCardSortDirection { BoardCardSortDirection(descending: lane.descending) }

    private var laneTint: Color {
        switch lane.kind {
        case .running: DieterTheme.primary
        case .review: DieterTheme.amber
        case .done: DieterTheme.eyes
        default: DieterTheme.tertiary
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(laneTint).frame(width: 6, height: 6)
                Text(lane.name).font(.system(size: 12, weight: .semibold))
                Text("\(cards.count)").font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Button(action: onToggleSort) {
                    Image(systemName: sortDirection.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(width: 20, height: 20)
                        .smokeTarget("lane-sort.\(lane.laneID).\(sortDirection.systemImage)")
                        .id(sortDirection.systemImage)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .quickHelp("Sort \(sortDirection.toggled.title.lowercased())")
                .accessibilityLabel("\(lane.name) lane sorted \(sortDirection.title.lowercased())")
                .accessibilityHint("Sort \(sortDirection.toggled.title.lowercased())")
                .accessibilityIdentifier("lane-sort.\(lane.laneID)")
                .smokeTarget("lane-sort.\(lane.laneID)")
                Button {
                    store.createConversationPresented = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .quickHelp("New card")
                .accessibilityLabel("New card")
            }.padding(.horizontal, 6).padding(.top, 2)
            if cards.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle").font(
                        .system(size: 17))
                    Text(isDropTargeted ? "Release to move" : "Drop cards here")
                }
                .font(.caption).foregroundStyle(isDropTargeted ? DieterTheme.shell : DieterTheme.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border, style: .init(dash: [5])))
                Spacer(minLength: 0)
            } else {
                BoardLaneList(laneID: lane.laneID, cards: cards, sortDirection: sortDirection)
            }
        }
        .padding(10)
        .background(
            isDropTargeted ? DieterTheme.shellDeep.opacity(0.08) : DieterTheme.background.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
                isDropTargeted ? DieterTheme.shell.opacity(0.32) : DieterTheme.border)
        )
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
    var usesTitlebarSpace = false
    var active = true
    let laneID: String
    let beforeCardID: String?
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            if targeted {
                HStack(spacing: 6) {
                    Circle().fill(DieterTheme.shell).frame(width: 5, height: 5)
                    Capsule().fill(DieterTheme.shell).frame(height: 2)
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
