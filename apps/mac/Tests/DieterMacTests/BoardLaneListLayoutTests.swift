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
    // Check the first layout before yielding to deferred height corrections.
    // A fast first draw is not useful if cards are initially clipped or gapped.
    root.layoutSubtreeIfNeeded()
    let initialTable = try #require(boardLaneNativeTable(in: root))
    try assertBoardLaneRowsFitContent(table: initialTable, root: root, cards: cards, store: store)

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

@Test @MainActor func boardLaneResizeRetainsMountedCellsAndSelectionOnlyRedrawsDecoration() async throws {
    let store = boardLaneFixtureStore()
    let cards = boardLaneFixtureCards(count: 3)
    store.state.cards = cards
    let root = NSHostingView(rootView: AnyView(boardLaneFixtureView(cards: cards, store: store)))
    root.sizingOptions = []
    let window = boardLaneFixtureWindow(root: root, width: 440, height: 1000)
    defer { window.close() }
    await settleBoardLane(root)
    let table = try #require(boardLaneNativeTable(in: root))
    let originalCells = try cards.indices.map { index in
        try #require(table.view(atColumn: 0, row: index, makeIfNecessary: false))
    }
    BoardRenderingDiagnostics.start()
    window.setContentSize(NSSize(width: 264, height: 1000))
    await settleBoardLane(root)
    let resized = BoardRenderingDiagnostics.stop()
    #expect(resized["widthChanged", default: 0] > 0)
    #expect(resized["fullReload"] == 0)
    #expect(resized["rowConfigured"] == 0)
    for index in cards.indices {
        #expect(table.view(atColumn: 0, row: index, makeIfNecessary: false) === originalCells[index])
    }
    try assertBoardLaneRowsFitContent(table: table, root: root, cards: cards, store: store)

    BoardRenderingDiagnostics.start()
    store.selectedCardID = cards[0].id
    await settleBoardLane(root)
    store.selectedCardID = cards[1].id
    await settleBoardLane(root)
    store.selectedCardID = nil
    await settleBoardLane(root)
    let selected = BoardRenderingDiagnostics.stop()
    #expect(selected["fullReload"] == 0)
    #expect(selected["rowConfigured"] == 0)
    #expect(selected["cardBody"] == 0)
}

@Test @MainActor func boardLanePresenceRefreshDoesNotReevaluateRichCards() async throws {
    let store = boardLaneFixtureStore()
    var cards = boardLaneFixtureCards(count: 3)
    var machine = store.endpoint
    machine.daemonID = "board-machine"
    machine.online = true
    machine.lastSeenAt = "2026-09-22T12:00:00Z"
    store.endpoints = [machine]
    store.endpoint = machine
    for index in cards.indices { cards[index].ownerDaemonID = "board-machine" }
    store.state.cards = cards
    let root = NSHostingView(rootView: AnyView(boardLaneFixtureView(cards: cards, store: store)))
    root.sizingOptions = []
    let window = boardLaneFixtureWindow(root: root, width: 300, height: 1000)
    defer { window.close() }
    await settleBoardLane(root)
    BoardRenderingDiagnostics.start()
    machine.lastSeenAt = "2026-09-22T12:00:05Z"
    store.endpoints = [machine]
    store.endpoint = machine
    await settleBoardLane(root)
    machine.online = false
    store.endpoints = [machine]
    store.endpoint = machine
    await settleBoardLane(root)
    let updated = BoardRenderingDiagnostics.stop()
    #expect(updated["fullReload"] == 0)
    #expect(updated["rowConfigured"] == 0)
    #expect(updated["cardBody"] == 0)
    #expect(store.machine(for: cards[0])?.online == false)
}

@Test @MainActor func boardLaneMetadataUpdateOnlyReconfiguresTheChangedCard() async throws {
    let store = boardLaneFixtureStore()
    var cards = boardLaneFixtureCards(count: 3)
    store.state.cards = cards
    let root = NSHostingView(rootView: AnyView(boardLaneFixtureView(cards: cards, store: store)))
    root.sizingOptions = []
    let window = boardLaneFixtureWindow(root: root, width: 300, height: 1000)
    defer { window.close() }
    await settleBoardLane(root)
    BoardRenderingDiagnostics.start()
    cards[1].summary = "New streaming activity on one card"
    store.state.cards = cards
    root.rootView = AnyView(boardLaneFixtureView(cards: cards, store: store))
    await settleBoardLane(root)
    let updated = BoardRenderingDiagnostics.stop()
    #expect(updated["fullReload"] == 0)
    #expect(updated["rowConfigured"] == 1)
    #expect(updated["cardBody"] == 1)

    // Board configuration remains live despite removing the per-card broad
    // state dependency. A label rename must reach all affected mounted cards.
    cards[0].labelIds = ["label-one"]
    store.state.cards = cards
    root.rootView = AnyView(boardLaneFixtureView(cards: cards, store: store))
    await settleBoardLane(root)
    BoardRenderingDiagnostics.start()
    store.state.boards[0].labels[0].name = "Renamed label with more words"
    await settleBoardLane(root)
    let renamed = BoardRenderingDiagnostics.stop()
    #expect(renamed["updatedRows"] == cards.count)
    let table = try #require(boardLaneNativeTable(in: root))
    try assertBoardLaneRowsFitContent(table: table, root: root, cards: cards, store: store)
}

@Test @MainActor func boardLaneLiveInsertionAndRemovalRetainUnchangedVisibleCells() async throws {
    let store = boardLaneFixtureStore()
    var cards = boardLaneFixtureCards(count: 3)
    store.state.cards = cards
    let root = NSHostingView(rootView: AnyView(boardLaneFixtureView(cards: cards, store: store)))
    root.sizingOptions = []
    let window = boardLaneFixtureWindow(root: root, width: 340, height: 1000)
    defer { window.close() }
    await settleBoardLane(root)
    let table = try #require(boardLaneNativeTable(in: root))
    let cells = try cards.indices.map { try #require(table.view(atColumn: 0, row: $0, makeIfNecessary: false)) }
    store.selectedCardID = cards[1].id
    BoardRenderingDiagnostics.start()
    var inserted = cards[0]
    inserted.id = "live-insert"
    inserted.title = "Another card arrived while opening the inspector"
    cards.insert(inserted, at: 0)
    store.state.cards = cards
    root.rootView = AnyView(boardLaneFixtureView(cards: cards, store: store))
    await settleBoardLane(root)
    #expect(table.numberOfRows == 4)
    for index in cells.indices {
        #expect(table.view(atColumn: 0, row: index + 1, makeIfNecessary: false) === cells[index])
    }
    cards[2].summary = "A live status update on the selected card"
    cards.removeFirst()
    store.state.cards = cards
    root.rootView = AnyView(boardLaneFixtureView(cards: cards, store: store))
    await settleBoardLane(root)
    #expect(table.numberOfRows == 3)
    for index in cells.indices {
        #expect(table.view(atColumn: 0, row: index, makeIfNecessary: false) === cells[index])
    }
    let counts = BoardRenderingDiagnostics.stop()
    #expect(counts["fullReload"] == 0)
    #expect(counts["reloadedRows"] == 0)
    #expect(counts["rowStructureChange"] == 2)
    #expect(store.selectedCardID == cards[1].id)
    try assertBoardLaneRowsFitContent(table: table, root: root, cards: cards, store: store)
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

    // Opening an inspector must retain the same visible conversation even
    // when old offscreen measurements are discarded for a different width.
    table.scrollRowToVisible(500)
    await settleBoardLane(root)
    let anchorRow = table.rows(in: table.visibleRect).location
    let anchorOffset = table.visibleRect.minY - table.rect(ofRow: anchorRow).minY
    window.setContentSize(NSSize(width: 440, height: 600))
    await settleBoardLane(root)
    #expect(table.rows(in: table.visibleRect).location == anchorRow)
    #expect(abs(table.visibleRect.minY - table.rect(ofRow: anchorRow).minY - anchorOffset) < 1)
}

@Test @MainActor func boardNavigationRetainsRowsWithoutRenderingWhileHidden() async throws {
    let store = boardLaneFixtureStore()
    store.state.cards = boardLaneFixtureCards(count: 100)
    func board(active: Bool = true) -> AnyView {
        AnyView(
            BoardConversationOverlay(
                board: AnyView(BoardLaneNavigationFixture().environment(store)),
                conversation: AnyView(Text("Conversation")),
                presented: false, maximized: false, active: active))
    }
    let root = NSHostingView(rootView: board())
    root.sizingOptions = []
    let window = boardLaneFixtureWindow(root: root, width: 440, height: 600)
    defer { window.close() }
    await settleBoardLane(root)
    let table = try #require(boardLaneNativeTable(in: root))
    table.scrollRowToVisible(50)
    await settleBoardLane(root)
    let anchorRow = table.rows(in: table.visibleRect).location
    let anchorOffset = table.visibleRect.minY - table.rect(ofRow: anchorRow).minY
    let originalCell = try #require(table.view(atColumn: 0, row: anchorRow, makeIfNecessary: false))

    root.rootView = board(active: false)
    await settleBoardLane(root)
    #expect(table.window === window)
    #expect(table.isHiddenOrHasHiddenAncestor)
    BoardRenderingDiagnostics.start()
    store.state.cards[50].summary = "Updated while away"
    store.endpoint.name = "Updated machine"
    try? await Task.sleep(for: .milliseconds(200))
    let hidden = BoardRenderingDiagnostics.stop()
    #expect(hidden["cardBody"] == 0)
    #expect(hidden["rowConfigured"] == 0)
    #expect(hidden["heightMeasured"] == 0)

    BoardRenderingDiagnostics.start()
    root.rootView = board()
    await settleBoardLane(root)
    let returned = BoardRenderingDiagnostics.stop()
    #expect(boardLaneNativeTable(in: root) === table)
    #expect(!table.isHiddenOrHasHiddenAncestor)
    #expect(returned["tableCreated"] == 0)
    #expect(returned["fullReload"] == 0)
    #expect(returned["updatedRows"] == 1)
    #expect(table.rows(in: table.visibleRect).location == anchorRow)
    #expect(abs(table.visibleRect.minY - table.rect(ofRow: anchorRow).minY - anchorOffset) < 1)
    // A separate unchanged row also retains its native identity across trips.
    let updatedCell = try #require(table.view(atColumn: 0, row: anchorRow, makeIfNecessary: false))
    #expect(updatedCell === originalCell)

    // Switching boards while away must replace the old board's identity and
    // content, rather than returning a stale retained table.
    root.rootView = board(active: false)
    await settleBoardLane(root)
    store.selectedBoardID = "another-board"
    store.state.cards = boardLaneFixtureCards(count: 2)
    for index in store.state.cards.indices { store.state.cards[index].boardID = "another-board" }
    root.rootView = board()
    await settleBoardLane(root)
    let nextBoard = try #require(boardLaneNativeTable(in: root))
    #expect(nextBoard !== table)
    #expect(nextBoard.numberOfRows == 2)
}

@Test @MainActor func boardNavigationReleasesNativeRowsWhenItsWindowContentIsRemoved() async throws {
    let store = boardLaneFixtureStore()
    store.state.cards = boardLaneFixtureCards(count: 10)
    var root: NSHostingView<AnyView>? = NSHostingView(
        rootView: AnyView(
            BoardConversationOverlay(
                board: AnyView(BoardLaneNavigationFixture().environment(store)),
                conversation: AnyView(EmptyView()), presented: false, maximized: false)))
    let window = boardLaneFixtureWindow(root: root!, width: 440, height: 600)
    defer { window.close() }
    await settleBoardLane(root!)
    weak var table = boardLaneNativeTable(in: root!)
    #expect(table != nil)
    window.contentView = nil
    root = nil
    try? await Task.sleep(for: .milliseconds(200))
    #expect(table == nil)
}

private struct BoardLaneNavigationFixture: View {
    @Environment(DieterStore.self) private var store
    var body: some View {
        BoardLaneList(laneID: "todo", cards: store.state.cards, sortDirection: .descending)
    }
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
            abs(cell.bounds.height - rowFrame.height) < 1,
            "Mounted cell geometry must match the measured row before first draw")
        #expect(
            cell.bounds.height >= content.fittingSize.height - 1,
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
