import AppKit
import DieterAPI
import Observation
import SwiftUI

/// A view-based native table asks SwiftUI to build only mounted rows. Native
/// measured visible heights retain wrapping and dynamic footers without measuring the
/// rich card graph for every item in every lane during the first layout.
struct BoardLaneList: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.boardRenderingActive) private var renderingActive
    let laneID: String
    let cards: [Dieter_V1_Card]
    let sortDirection: BoardCardSortDirection

    var body: some View {
        NativeBoardLaneList(
            store: store, laneID: laneID, cards: cards, board: store.selectedBoard,
            renderingActive: renderingActive
        )
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
    let board: Dieter_V1_Board?
    let renderingActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        BoardRenderingDiagnostics.record(.tableCreated)
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
            BoardRenderingDiagnostics.record(.widthChanged)
            coordinator.resize(to: table.bounds.width)
        }
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Hidden destination updates coalesce until the board is visible. Keep
        // the last rendered parent so reactivation diffs against those rows.
        guard renderingActive else { return }
        context.coordinator.update(to: self)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeBoardLaneList
        weak var table: NSTableView?
        var heights: [String: CGFloat] = [:]
        private var pendingHeightIDs: Set<String> = []
        private var heightUpdateScheduled = false
        init(parent: NativeBoardLaneList) { self.parent = parent }
        func update(to next: NativeBoardLaneList) {
            guard let table else { parent = next; return }
            let old = parent.cards
            let boardChanged = parent.board != next.board
            guard boardChanged || old != next.cards else { parent = next; return }
            let anchor = viewportAnchor()
            parent = next
            let ids = next.cards.map(\.id)
            let difference = ids.difference(from: old.map(\.id))
            let retainedIDs = Set(ids)
            heights = heights.filter { retainedIDs.contains($0.key) }
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            let changed = IndexSet(
                next.cards.indices.filter { index in
                    let card = next.cards[index]
                    return boardChanged || oldByID[card.id] != card
                        || (card.id == old.last?.id) != (index == next.cards.count - 1)
                })
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                if !difference.isEmpty {
                    // A new/moved card must not discard every visible sibling.
                    // Apply the identity diff with no insertion/removal fades.
                    var removed = IndexSet()
                    var inserted = IndexSet()
                    for change in difference {
                        switch change {
                        case .remove(let offset, _, _): removed.insert(offset)
                        case .insert(let offset, _, _): inserted.insert(offset)
                        }
                    }
                    BoardRenderingDiagnostics.record(.rowStructureChange)
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: [])
                    table.endUpdates()
                }
                for index in changed {
                    heights.removeValue(forKey: next.cards[index].id)
                    guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? BoardLaneCell
                    else { continue }
                    // Preserve the native cell and its SwiftUI identity during
                    // streaming metadata updates, selection and label changes.
                    configure(cell, row: index)
                }
                if !changed.isEmpty {
                    BoardRenderingDiagnostics.record(.updatedRows, count: changed.count)
                    table.noteHeightOfRows(withIndexesChanged: changed)
                }
            }
            restoreViewport(anchor)
        }

        func resize(to width: CGFloat) {
            guard let table else { return }
            let anchor = viewportAnchor()
            // Preserve mounted rows, focus, hover and drag state when opening
            // the inspector. Offscreen estimates are remeasured on reuse.
            heights.removeAll(keepingCapacity: true)
            table.enumerateAvailableRowViews { rowView, _ in
                guard let cell = rowView.view(atColumn: 0) as? BoardLaneCell else { return }
                cell.sizing.width = max(1, width)
                cell.measureContent()
                cell.needsLayout = true
            }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
            restoreViewport(anchor)
        }

        private struct ViewportAnchor {
            let cardID: String
            let offset: CGFloat
        }

        private func viewportAnchor() -> ViewportAnchor? {
            guard let table, let scroll = table.enclosingScrollView else { return nil }
            let origin = scroll.documentVisibleRect.minY
            let row = table.row(at: NSPoint(x: 0, y: origin))
            guard row >= 0, row < table.numberOfRows else { return nil }
            return ViewportAnchor(cardID: parent.cards[row].id, offset: origin - table.rect(ofRow: row).minY)
        }

        private func restoreViewport(_ anchor: ViewportAnchor?) {
            guard let anchor, let table, let index = parent.cards.firstIndex(where: { $0.id == anchor.cardID }),
                index < table.numberOfRows, let scroll = table.enclosingScrollView
            else { return }
            let row = table.rect(ofRow: index)
            let offset = min(anchor.offset, max(0, row.height - 1))
            let y = min(max(0, row.minY + offset), max(0, table.bounds.height - scroll.documentVisibleRect.height))
            let point = NSPoint(x: scroll.contentView.bounds.minX, y: y)
            guard abs(scroll.contentView.bounds.minY - y) > 0.5 else { return }
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

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
            BoardRenderingDiagnostics.record(.heightTransaction)
            let anchor = viewportAnchor()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
            restoreViewport(anchor)
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
            configure(cell, row: row)
            return cell
        }

        private func configure(_ cell: BoardLaneCell, row: Int) {
            BoardRenderingDiagnostics.record(.rowConfigured)
            let cardID = parent.cards[row].id
            cell.measured = { [weak self] height in
                self?.measured(height, cardID: cardID)
            }
            cell.needsMeasurement = true
            cell.sizing.width = max(1, table?.bounds.width ?? 1)
            cell.host.rootView = BoardLaneCellContent(
                sizing: cell.sizing,
                content: AnyView(
                    BoardLaneRow(
                        card: parent.cards[row], laneID: parent.laneID, isLast: row == parent.cards.count - 1,
                        board: parent.board
                    )
                    .id(cardID)
                    .environment(parent.store)
                    .foregroundStyle(DieterTheme.text)
                ))
            // Prime the height while the native table constructs this visible
            // cell. Deferring the first measurement to a later layout leaves
            // a briefly clipped card at the estimated height on first draw.
            cell.measureContent()
            cell.needsLayout = true
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

@MainActor @Observable private final class BoardLaneCellSizing {
    var width: CGFloat = 1
}

private struct BoardLaneCellContent: View {
    let sizing: BoardLaneCellSizing
    let content: AnyView

    var body: some View { content.frame(width: sizing.width) }
}

@MainActor private final class BoardLaneHostingView: NSHostingView<BoardLaneCellContent> {
    var measurementInvalidated: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        measurementInvalidated?()
    }
}

@MainActor private final class BoardLaneCell: NSTableCellView {
    let sizing = BoardLaneCellSizing()
    lazy var host = BoardLaneHostingView(rootView: BoardLaneCellContent(sizing: sizing, content: AnyView(EmptyView())))
    var needsMeasurement = true
    private var measuredWidth: CGFloat?
    var measured: ((CGFloat) -> Void)?
    override func layout() {
        super.layout()
        measureContent()
    }
    func measureContent() {
        guard needsMeasurement || measuredWidth != sizing.width else { return }
        needsMeasurement = false
        measuredWidth = sizing.width
        BoardRenderingDiagnostics.record(.heightMeasured)
        measured?(max(1, ceil(host.fittingSize.height)))
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = [.intrinsicContentSize]
        host.measurementInvalidated = { [weak self] in
            self?.needsMeasurement = true
            self?.needsLayout = true
        }
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
    var board: Dieter_V1_Board? = nil
    var body: some View {
        VStack(spacing: 0) {
            LaneInsertionTarget(laneID: laneID, beforeCardID: card.id)
            BoardCardView(card: card, board: board)
                .opacity(store.movingCardIDs.contains(card.id) ? 0.48 : 1)
            if isLast {
                LaneInsertionTarget(laneID: laneID, beforeCardID: nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}
