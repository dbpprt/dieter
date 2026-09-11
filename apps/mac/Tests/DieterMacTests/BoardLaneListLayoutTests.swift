import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func boardLaneListMeasuresWrappedCardsAndMergedFootersAtEveryWidth() async throws {
    let store = boardLaneFixtureStore()
    var cards = boardLaneFixtureCards(count: 3)
    cards[1].title = String(repeating: "A long task title with several words ", count: 8)
    cards[1].summary = String(repeating: "Detailed summary with Unicode 👋🏼 and multiple lines. ", count: 6)
    cards[1].labelIds = ["label-one", "label-two"]
    cards[1].model = "gpt-5.6-sol"
    cards[1].workspaceMode = "worktree"
    store.state.cards = cards
    let root = NSHostingView(rootView: AnyView(boardLaneFixtureView(cards: cards, store: store)))
    root.sizingOptions = []
    let window = boardLaneFixtureWindow(root: root, width: 264, height: 1000)
    defer { window.close() }

    for width in [CGFloat(264), 440, 264] {
        window.setContentSize(NSSize(width: width, height: 1000))
        await settleBoardLane(root)
        let table = try #require(boardLaneNativeTable(in: root))
        try #require(table.numberOfRows == cards.count)
        try assertBoardLaneRowsFitContent(table: table, root: root, cards: cards, store: store)

        // Adding a footer to an existing card must resize its native row and
        // move the following card without a scroll or a selection to repair it.
        let previousHeight = table.rect(ofRow: 1).height
        cards[1].mergedIntoCardID = "target-card"
        store.state.cards = cards
        root.rootView = AnyView(boardLaneFixtureView(cards: cards, store: store))
        await settleBoardLane(root)
        let updatedTable = try #require(boardLaneNativeTable(in: root))
        try assertBoardLaneRowsFitContent(table: updatedTable, root: root, cards: cards, store: store)
        #expect(updatedTable.rect(ofRow: 1).height > previousHeight)

        cards[1].mergedIntoCardID = ""
        store.state.cards = cards
        root.rootView = AnyView(boardLaneFixtureView(cards: cards, store: store))
        await settleBoardLane(root)
    }
}

@Test @MainActor func boardLaneListRecyclesOffscreenRowsAndScrollsToTheLastCard() async throws {
    let store = boardLaneFixtureStore()
    let cards = boardLaneFixtureCards(count: 1000)
    store.state.cards = cards
    let root = NSHostingView(rootView: AnyView(boardLaneFixtureView(cards: cards, store: store)))
    root.sizingOptions = []
    let window = boardLaneFixtureWindow(root: root, width: 300, height: 600)
    defer { window.close() }
    await settleBoardLane(root)
    let table = try #require(boardLaneNativeTable(in: root))
    #expect(table.numberOfRows == cards.count)
    let scrollView = try #require(table.enclosingScrollView)

    var instantiatedRows = 0
    table.enumerateAvailableRowViews { _, _ in instantiatedRows += 1 }
    #expect(instantiatedRows > 0)
    #expect(instantiatedRows < cards.count / 2)

    // Model dragging the scrollbar to the bottom while native List replaces
    // estimated heights with measured rows. Continue only when that scroll has
    // changed document geometry; a stable but unreachable last card is a failure.
    for _ in 0..<8 {
        let documentBounds = table.bounds
        let viewportSize = scrollView.contentView.bounds.size
        let bottom =
            table.isFlipped
            ? max(documentBounds.minY, documentBounds.maxY - viewportSize.height)
            : documentBounds.minY
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: bottom))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settleBoardLane(root)
        let lastRow = table.rect(ofRow: cards.count - 1)
        if table.visibleRect.maxY >= lastRow.maxY - 1,
            table.rowView(atRow: cards.count - 1, makeIfNecessary: false) != nil
        {
            break
        }
        try #require(
            table.bounds != documentBounds || scrollView.contentView.bounds.size != viewportSize,
            "The document stopped changing before its final card was reachable")
    }
    let visibleRows = table.rows(in: table.visibleRect)
    #expect(NSLocationInRange(cards.count - 1, visibleRows))
    #expect(table.rowView(atRow: cards.count - 1, makeIfNecessary: false) != nil)
    #expect(table.visibleRect.maxY >= table.rect(ofRow: cards.count - 1).maxY - 1)
}

@MainActor private func assertBoardLaneRowsFitContent(
    table: NSTableView, root: NSView, cards: [Dieter_V1_Card], store: DieterStore
) throws {
    for (index, card) in cards.enumerated() {
        let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: false))
        let cellFrame = cell.convert(cell.bounds, to: root)
        #expect(abs(cellFrame.minX - root.bounds.minX) < 1)
        #expect(abs(cellFrame.maxX - root.bounds.maxX) < 1)
        if index == 0 {
            // The insertion area uses the header gap; the card itself must
            // align with the empty placeholder at the lane content origin.
            #expect(abs(cellFrame.minY + LaneInsertionTarget.beforeCardHeight - root.bounds.minY) < 1)
        }
        let rowFrame = table.rect(ofRow: index)
        let content = NSHostingView(
            rootView: BoardLaneRow(card: card, laneID: "todo", isLast: index == cards.count - 1)
                .environment(store)
                .frame(width: max(1, cell.bounds.width)))
        content.layoutSubtreeIfNeeded()
        #expect(
            rowFrame.height >= content.fittingSize.height - 1,
            "Native row \(card.id) must include its entire SwiftUI content")
        if index > 0 {
            #expect(rowFrame.minY >= table.rect(ofRow: index - 1).maxY)
        }
    }
}

@MainActor private func boardLaneFixtureStore() -> DieterStore {
    let store = DieterStore(restoreSync: false)
    var project = Dieter_V1_Project()
    project.id = "layout-project"
    project.name = "Layout fixture"
    var board = Dieter_V1_Board()
    board.id = "layout-board"
    board.projectID = project.id
    var first = Dieter_V1_Label()
    first.id = "label-one"
    first.name = "A label that takes space"
    var second = Dieter_V1_Label()
    second.id = "label-two"
    second.name = "Another longer label"
    board.labels = [first, second]
    store.state.project = project
    store.state.projects = [project]
    store.state.boards = [board]
    store.selectedProjectID = project.id
    store.selectedBoardID = board.id
    return store
}

private func boardLaneFixtureCards(count: Int) -> [Dieter_V1_Card] {
    (0..<count).map { index in
        var card = Dieter_V1_Card()
        card.id = "layout-card-\(index)"
        card.title = "Task \(index)"
        card.projectID = "layout-project"
        card.boardID = "layout-board"
        card.lane = "todo"
        card.runtime = "idle"
        return card
    }
}

@MainActor private func boardLaneFixtureView(cards: [Dieter_V1_Card], store: DieterStore) -> some View {
    BoardLaneList(laneID: "todo", cards: cards, sortDirection: .descending)
        .environment(store)
}

@MainActor private func boardLaneFixtureWindow(root: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.setContentSize(NSSize(width: width, height: height))
    return window
}

@MainActor private func settleBoardLane(_ root: NSView) async {
    root.layoutSubtreeIfNeeded()
    try? await DieterTaskSleep.milliseconds(160)
    root.layoutSubtreeIfNeeded()
}

@MainActor private func boardLaneNativeTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for child in view.subviews {
        if let table = boardLaneNativeTable(in: child) { return table }
    }
    return nil
}
