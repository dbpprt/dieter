import AppKit
import DieterAPI
import SwiftUI

/// AppKit recycles offscreen rows while retaining variable card heights. Each
/// visible row hosts the existing SwiftUI card, including menus and drag/drop.
/// This avoids both eager offscreen card graphs and SwiftUI lazy anchor loops.
struct BoardLaneList: NSViewRepresentable {
    @Environment(DieterStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let laneID: String
    let cards: [Dieter_V1_Card]
    let sortDirection: BoardCardSortDirection

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.rowSizeStyle = .custom
        table.rowHeight = 120
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("card"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityIdentifier("board.lane.\(laneID)")
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.update(self, store: store, colorScheme: colorScheme, table: table)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTableView)?.delegate = nil
        (scroll.documentView as? NSTableView)?.dataSource = nil
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var cards: [Dieter_V1_Card] = []
        private var store: DieterStore?
        private var laneID = ""
        private var scheme = ColorScheme.light
        private var direction = BoardCardSortDirection.descending
        private var boardID = ""
        private var labels: [Dieter_V1_Label] = []
        private var heights: [Int: CGFloat] = [:]
        private var measuredWidth: CGFloat = 0

        func update(_ value: BoardLaneList, store: DieterStore, colorScheme: ColorScheme, table: NSTableView) {
            let identityChanged = laneID != value.laneID || direction != value.sortDirection || boardID != store.selectedBoardID
            let nextLabels = store.selectedBoard?.labels ?? []
            let appearanceChanged = self.store !== store || scheme != colorScheme || labels != nextLabels
            let changed = cards != value.cards || appearanceChanged || identityChanged
            guard changed else { return }
            let sameOrder = cards.map(\.id) == value.cards.map(\.id)
            let changedRows = sameOrder ? IndexSet(cards.indices.filter { cards[$0] != value.cards[$0] }) : IndexSet()
            self.store = store
            laneID = value.laneID
            boardID = store.selectedBoardID
            labels = nextLabels
            direction = value.sortDirection
            cards = value.cards
            scheme = colorScheme
            heights.removeAll(keepingCapacity: true)
            if sameOrder, !identityChanged, !appearanceChanged {
                table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
                table.noteHeightOfRows(withIndexesChanged: changedRows)
            } else {
                table.reloadData()
            }
            if identityChanged, !cards.isEmpty { table.scrollRowToVisible(0) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { cards.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
            if measuredWidth != width {
                measuredWidth = width
                heights.removeAll(keepingCapacity: true)
            }
            if let height = heights[row] { return height }
            guard cards.indices.contains(row) else { return 120 }
            let height = BoardCardRowSizing.height(card: cards[row], width: width,
                hasLabels: labels.contains { cards[row].labelIds.contains($0.id) }, last: row == cards.count - 1)
            heights[row] = height
            return height
        }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            heights.removeAll(keepingCapacity: true)
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<cards.count))
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard cards.indices.contains(row), let store else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("board.card.cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? Cell ?? Cell()
            cell.identifier = identifier
            cell.host.rootView = AnyView(BoardLaneRow(card: cards[row], laneID: laneID, isLast: row == cards.count - 1)
                .id(cards[row].id).environment(store).environment(\.colorScheme, scheme)
                .foregroundStyle(DieterTheme.text).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            return cell
        }
    }

    @MainActor final class Cell: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }
        override func layout() { super.layout(); host.frame = bounds }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    }
}

/// Measure bounded text without constructing an offscreen SwiftUI card graph.
/// Font sizes, padding, and line limits match BoardCardView's compact layout.
enum BoardCardRowSizing {
    static func height(card: Dieter_V1_Card, width: CGFloat, hasLabels: Bool, last: Bool) -> CGFloat {
        let contentWidth = max(1, width - 24)
        let title = card.title.isEmpty ? "Untitled card" : card.title
        var result: CGFloat = 9 + 24 + textHeight(title, width: contentWidth - 18, size: 13, weight: .semibold) + 9 + 21
        if !card.summary.isEmpty { result += 9 + textHeight(card.summary, width: contentWidth, size: 11, weight: .regular) }
        if hasLabels { result += 9 + 18 }
        return ceil(result) + 4 + (last ? 12 : 0)
    }

    private static func textHeight(_ text: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let line = ceil(font.ascender - font.descender + font.leading)
        let rect = (text as NSString).boundingRect(with: NSSize(width: max(1, width), height: line * 3),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(line * 3, max(line, ceil(rect.height)))
    }
}

private struct BoardLaneRow: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    let laneID: String
    let isLast: Bool
    var body: some View {
        VStack(spacing: 0) {
            LaneInsertionTarget(laneID: laneID, beforeCardID: card.id)
            BoardCardView(card: card)
                .opacity(store.movingCardIDs.contains(card.id) ? 0.48 : 1)
                .help("Drag to move \(card.title) to another lane")
            if isLast {
                LaneInsertionTarget(laneID: laneID, beforeCardID: nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
