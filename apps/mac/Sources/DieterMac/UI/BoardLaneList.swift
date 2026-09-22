import AppKit
import DieterAPI
import SwiftUI

/// A view-based native table asks SwiftUI to build only mounted rows. Native
/// measured visible heights retain wrapping and dynamic footers without measuring the
/// rich card graph for every item in every lane during the first layout.
struct BoardLaneList: View {
    @Environment(DieterStore.self) private var store
    let laneID: String
    let cards: [Dieter_V1_Card]
    let sortDirection: BoardCardSortDirection

    var body: some View {
        NativeBoardLaneList(store: store, laneID: laneID, cards: cards)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, -LaneInsertionTarget.beforeCardHeight)
            .foregroundStyle(DieterTheme.text)
            .accessibilityIdentifier("board.lane.\(laneID)")
            .id("\(store.selectedBoardID):\(laneID):\(sortDirection == .descending)")
    }
}

private struct NativeBoardLaneList: NSViewRepresentable {
    let store: DieterStore
    let laneID: String
    let cards: [Dieter_V1_Card]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = BoardLaneTable()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 140
        let column = NSTableColumn(identifier: .init("card"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.applyMeasuredHeights = { [weak coordinator = context.coordinator] in
            coordinator?.applyMeasuredHeights() ?? false
        }
        table.widthDidChange = { [weak table, weak coordinator = context.coordinator] in
            guard let table, let coordinator else { return }
            coordinator.heights.removeAll()
            table.reloadData()
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent.cards
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        if old.map(\.id) != cards.map(\.id) {
            coordinator.heights = coordinator.heights.filter { entry in cards.contains { $0.id == entry.key } }
            table.reloadData()
        } else if old != cards {
            let changed = IndexSet(cards.indices.filter { old[$0] != cards[$0] })
            for index in changed { coordinator.heights.removeValue(forKey: cards[index].id) }
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeBoardLaneList
        weak var table: NSTableView?
        var heights: [String: CGFloat] = [:]
        private var pendingHeightIDs: Set<String> = []
        private var heightUpdateScheduled = false
        init(parent: NativeBoardLaneList) { self.parent = parent }
        private func measured(_ height: CGFloat, cardID: String) {
            guard abs((heights[cardID] ?? 140) - height) > 0.5 else { return }
            heights[cardID] = height
            pendingHeightIDs.insert(cardID)
            guard !heightUpdateScheduled else { return }
            heightUpdateScheduled = true
            // Apply one native geometry transaction for the visible batch.
            // Updating each row separately repeatedly relaid out its peers.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightUpdateScheduled = false
                _ = self.applyMeasuredHeights()
            }
        }
        func applyMeasuredHeights() -> Bool {
            guard !pendingHeightIDs.isEmpty, let table else { return false }
            let ids = pendingHeightIDs
            pendingHeightIDs.removeAll(keepingCapacity: true)
            let changed = IndexSet(parent.cards.indices.filter { ids.contains(parent.cards[$0].id) })
            guard !changed.isEmpty else { return false }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
            return true
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.cards.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            heights[parent.cards[row].id] ?? 140
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("board-card")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? BoardLaneCell ?? BoardLaneCell()
            cell.identifier = id
            let cardID = parent.cards[row].id
            cell.measured = { [weak self] height in
                self?.measured(height, cardID: cardID)
            }
            cell.host.rootView = AnyView(
                BoardLaneRow(card: parent.cards[row], laneID: parent.laneID, isLast: row == parent.cards.count - 1)
                    .id(cardID)
                    .environment(parent.store)
                    .foregroundStyle(DieterTheme.text)
                    .frame(width: max(1, tableView.bounds.width))
            )
            // Prime the height while the native table constructs this visible
            // cell. Deferring the first measurement to a later layout leaves
            // a briefly clipped card at the estimated height on first draw.
            cell.measureContent()
            cell.needsLayout = true
            return cell
        }
    }
}

@MainActor private final class BoardLaneTable: NSTableView {
    var widthDidChange: (() -> Void)?
    var applyMeasuredHeights: (() -> Bool)?
    private var measuredWidth: CGFloat?
    override func layout() {
        let previous = measuredWidth
        measuredWidth = bounds.width
        // The initial rows already receive this width. Reloading after their
        // first layout discarded and constructed every visible graph twice.
        // Later width changes invalidate before AppKit lays out those rows.
        if let previous, abs(bounds.width - previous) > 0.5 { widthDidChange?() }
        // Finish visible geometry before drawing, including another row that
        // a shorter measured card may have uncovered. The async fallback only
        // handles subsequent content changes, never first-frame sizing.
        for _ in 0..<3 {
            super.layout()
            if applyMeasuredHeights?() != true { break }
        }
    }
}

@MainActor private final class BoardLaneCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    var measured: ((CGFloat) -> Void)?
    override func layout() {
        super.layout()
        measureContent()
    }
    func measureContent() {
        measured?(max(1, ceil(host.fittingSize.height)))
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
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
