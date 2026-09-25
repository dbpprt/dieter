import AppKit
import Darwin
import DieterAPI
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import DieterMac

private let macPackageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite(.serialized)
struct DieterThemePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_BOARD_PROFILE"] == "1"))
    @MainActor func boardOpeningStageDiagnostic() async throws {
        for counts in [[10, 0, 0, 0], [100, 0, 0, 0], [25, 25, 25, 25]] {
            for sample in 1...3 {
                let start = Date()
                let fixture = makeProductionBoardFixture(laneCounts: counts)
                let projected = Date()
                let view = NSHostingView(rootView: productionBoard(store: fixture.store, board: fixture.board))
                view.sizingOptions = []
                let hosted = Date()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1_140, height: 710),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                defer { window.close() }
                view.layoutSubtreeIfNeeded()
                let laidOut = Date()
                func mountedRowCount() -> Int {
                    var pending: [NSView] = [view]
                    var count = 0
                    while let next = pending.popLast() {
                        pending.append(contentsOf: next.subviews)
                        if let table = next as? NSTableView {
                            table.enumerateAvailableRowViews { _, _ in count += 1 }
                        }
                    }
                    return count
                }
                // Native List needs a window and a deferred layout pass. A
                // windowless host measures empty chrome and reports zero rows.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while mountedRowCount() == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                    view.layoutSubtreeIfNeeded()
                }
                let ready = Date()
                let mountedRows = mountedRowCount()
                try #require(mountedRows > 0, "Performance evidence requires actual card rows")
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let drawn = Date()
                print(
                    "BOARD_PROFILE counts=\(counts) sample=\(sample) projection_ms=\(projected.timeIntervalSince(start)*1000) host_ms=\(hosted.timeIntervalSince(projected)*1000) initial_layout_ms=\(laidOut.timeIntervalSince(hosted)*1000) rows_ready_ms=\(ready.timeIntervalSince(hosted)*1000) draw_ms=\(drawn.timeIntervalSince(ready)*1000)"
                )
                print("BOARD_PROFILE mounted_rows=\(mountedRows)")
                if sample == 3, counts == [25, 25, 25, 25] {
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: macPackageRoot.appendingPathComponent(".build/board-profile.png"))
                }
            }
        }
    }

    @Test @MainActor func aLargeRunningIndicatorFixtureRendersInBothAppearances() {
        let columns = Array(repeating: GridItem(.fixed(12), spacing: 3), count: 10)
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }

        for scheme in [ColorScheme.light, .dark] {
            DieterTheme.install(palette: .monochrome, colorScheme: scheme)
            let fixture = LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<100, id: \.self) { _ in
                    DieterActivityIndicator()
                }
            }
            .padding(8)
            .background(DieterTheme.surface)
            .preferredColorScheme(scheme)
            let renderer = ImageRenderer(content: fixture)
            renderer.proposedSize = .init(width: 166, height: 166)

            #expect(renderer.nsImage != nil)
        }
    }

    @Test @MainActor func installingANewThemeInvalidatesExistingColorConsumers() {
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        DieterTheme.install(palette: .monochrome, colorScheme: .light)
        let changed = Mutex(false)

        withObservationTracking {
            _ = DieterTheme.surface
        } onChange: {
            changed.withLock { $0 = true }
        }
        DieterTheme.install(palette: .coralSignal, colorScheme: .dark)

        #expect(changed.withLock { $0 })
    }

    @Test @MainActor func renderingAStaleAuxiliaryRootCannotReinstallThePreviousTheme() {
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        DieterTheme.install(selection: .init(appearance: .light, palette: .coralSignal))
        let expectedBackground = DieterTheme.surface
        let expectedAddition = DieterTheme.diffAddition
        let changedDuringLayout = Mutex(false)
        withObservationTracking {
            _ = DieterTheme.surface
            _ = DieterTheme.diffAddition
        } onChange: {
            changedDuringLayout.withLock { $0 = true }
        }

        // Auxiliary windows can render their old root before observing the
        // store's new selection. This used to mutate global theme state from
        // body and invalidate other NSHostingViews during window layout.
        let host = NSHostingView(
            rootView: Text("Existing auxiliary window")
                .foregroundStyle(DieterTheme.text)
                .dieterThemeRoot(palette: .monochrome, appearance: .dark))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        host.layoutSubtreeIfNeeded()

        #expect(!changedDuringLayout.withLock { $0 })
        #expect(DieterTheme.surface == expectedBackground)
        #expect(DieterTheme.diffAddition == expectedAddition)
    }

    @Test @MainActor func cachedSystemThemeTracksOSChangesWithoutOverridingExplicitAppearance() {
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        for palette in [DieterPalette.monochrome, .coralSignal] {
            DieterTheme.install(palette: palette, colorScheme: .dark)
            let darkBackground = DieterTheme.surface
            let darkAddition = DieterTheme.diffAddition
            DieterTheme.install(palette: palette, colorScheme: .light)
            let lightBackground = DieterTheme.surface
            let lightAddition = DieterTheme.diffAddition

            // The initial colors are unchanged when switching Light to System.
            // The following system change must still update every cached token.
            DieterTheme.install(selection: .init(appearance: .system, palette: palette), systemColorScheme: .light)
            DieterTheme.systemColorSchemeDidChange(.dark)
            #expect(DieterTheme.surface == darkBackground)
            #expect(DieterTheme.diffAddition == darkAddition)
            DieterTheme.systemColorSchemeDidChange(.light)
            #expect(DieterTheme.surface == lightBackground)
            #expect(DieterTheme.diffAddition == lightAddition)

            DieterTheme.install(selection: .init(appearance: .light, palette: palette))
            DieterTheme.systemColorSchemeDidChange(.dark)
            #expect(DieterTheme.surface == lightBackground)
            DieterTheme.install(selection: .init(appearance: .dark, palette: palette))
            DieterTheme.systemColorSchemeDidChange(.light)
            #expect(DieterTheme.surface == darkBackground)
        }
    }

    @Test @MainActor func outgoingMessagesKeepEnhancedContrastInEveryTheme() throws {
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }

        for palette in DieterPalette.allCases {
            for scheme in [ColorScheme.light, .dark] {
                DieterTheme.install(palette: palette, colorScheme: scheme)
                let foreground = try #require(NSColor(DieterTheme.userMessageForeground).usingColorSpace(.sRGB))
                let background = try #require(NSColor(DieterTheme.userMessageBackground).usingColorSpace(.sRGB))
                let ratio = contrastRatio(foreground, background)

                #expect(
                    ratio >= 7,
                    "\(palette.rawValue) \(scheme) outgoing-message contrast was only \(ratio):1"
                )
            }
        }
    }

    @Test @MainActor func machinePresenceColorsRemainGreenAndRedAcrossThemes() throws {
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }

        for palette in DieterPalette.allCases {
            for scheme in [ColorScheme.light, .dark] {
                DieterTheme.install(palette: palette, colorScheme: scheme)
                let online = try #require(NSColor(DieterTheme.machineOnline).usingColorSpace(.sRGB))
                let offline = try #require(NSColor(DieterTheme.machineOffline).usingColorSpace(.sRGB))

                #expect(online.greenComponent > online.redComponent)
                #expect(online.greenComponent > online.blueComponent)
                #expect(offline.redComponent > offline.greenComponent)
                #expect(offline.redComponent > offline.blueComponent)
            }
        }
    }

    @Test @MainActor func productionChatListWithManyRunningRowsSettlesInAHostedView() throws {
        let fixture = makeProductionChatListFixture()
        let view = NSHostingView(rootView: productionChatList(store: fixture.store))
        view.frame = NSRect(x: 0, y: 0, width: 1_080, height: 760)
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }

        let start = ContinuousClock.now
        for _ in 0..<60 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        let elapsed = start.duration(to: .now)

        #expect(fixture.running == 25)
        #expect(fixture.total == 58)
        #expect(elapsed < .seconds(5))
        let accessibilityStart = ContinuousClock.now
        _ = view.accessibilityChildren()
        #expect(accessibilityStart.duration(to: .now) < .seconds(2))
    }

    @Test @MainActor func productionBoardWithSixtyFiveCardLaneSettlesInAHostedView() throws {
        let fixture = makeProductionBoardFixture()
        let view = NSHostingView(rootView: productionBoard(store: fixture.store, board: fixture.board))
        view.frame = NSRect(x: 0, y: 0, width: 1_380, height: 870)
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }

        let start = ContinuousClock.now
        for _ in 0..<20 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        let elapsed = start.duration(to: .now)

        #expect(fixture.total == 78)
        #expect(fixture.largestLane == 65)
        #expect(elapsed < .seconds(5))
        let accessibilityStart = ContinuousClock.now
        _ = view.accessibilityChildren()
        #expect(accessibilityStart.duration(to: .now) < .seconds(2))
    }

    @Test @MainActor func boardOnlyMountsVisibleCardsAndScrollsBeyondTheOldPageLimit() async throws {
        let fixture = makeProductionBoardFixture(laneCounts: [100, 0, 0, 0])
        let view = NSHostingView(rootView: productionBoard(store: fixture.store, board: fixture.board))
        view.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_140, height: 710),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        // Native List installs its scroll view and visible rows after receiving
        // a window and the first deferred SwiftUI layout pass.
        view.layoutSubtreeIfNeeded()
        try await DieterTaskSleep.milliseconds(160)
        view.layoutSubtreeIfNeeded()
        var pending: [NSView] = [view]
        var tables: [NSTableView] = []
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            if let table = next as? NSTableView { tables.append(table) }
        }
        let table = try #require(tables.first(where: { $0.numberOfRows == 100 }))
        #expect(table.numberOfRows == 100)
        var mounted = 0
        table.enumerateAvailableRowViews { _, _ in mounted += 1 }
        let visibleRows = table.rows(in: table.visibleRect)
        let preparedRows = table.rows(in: table.preparedContentRect.union(table.visibleRect))
        // Native List prefetches beyond the viewport for responsive scrolling.
        // Its prepared region grows while idle, so the old custom table's fixed
        // visible-row limit is not a contract. Bound mounting by AppKit's actual
        // prefetch region and verify that the far end remains virtualized.
        try #require(visibleRows.length > 0)
        #expect(mounted >= visibleRows.length)
        #expect(mounted <= preparedRows.length)
        #expect(mounted < table.numberOfRows)
        #expect(table.rowView(atRow: 99, makeIfNecessary: false) == nil)
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            #expect(table.rowView(atRow: row, makeIfNecessary: false) != nil)
        }
        let scrollView = try #require(table.enclosingScrollView)
        for _ in 0..<8 {
            let documentBounds = table.bounds
            let viewportSize = scrollView.contentView.bounds.size
            let bottom =
                table.isFlipped
                ? max(documentBounds.minY, documentBounds.maxY - viewportSize.height) : documentBounds.minY
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: bottom))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            view.layoutSubtreeIfNeeded()
            try await DieterTaskSleep.milliseconds(160)
            view.layoutSubtreeIfNeeded()
            if table.visibleRect.maxY >= table.rect(ofRow: 99).maxY - 1,
                table.rowView(atRow: 99, makeIfNecessary: false) != nil
            {
                break
            }
            try #require(
                table.bounds != documentBounds || scrollView.contentView.bounds.size != viewportSize,
                "Native List stopped updating before the final card was reachable")
        }
        #expect(NSLocationInRange(99, table.rows(in: table.visibleRect)))
        #expect(table.rowView(atRow: 99, makeIfNecessary: false) != nil)
        #expect(table.visibleRect.maxY >= table.rect(ofRow: 99).maxY - 1)
    }

    @Test @MainActor func fourPopulatedBoardLanesKeepOffscreenCardGraphsUnmounted() async throws {
        // The original regression mounted all 100 cards across four short
        // lanes, even though a single long lane still appeared virtualized.
        let fixture = makeProductionBoardFixture(laneCounts: [25, 25, 25, 25])
        let view = NSHostingView(rootView: productionBoard(store: fixture.store, board: fixture.board))
        view.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_140, height: 710),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await DieterTaskSleep.milliseconds(160)
        view.layoutSubtreeIfNeeded()
        var pending: [NSView] = [view]
        var tables: [NSTableView] = []
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            if let table = next as? NSTableView, table.numberOfRows == 25 { tables.append(table) }
        }
        try #require(tables.count == 4)
        var mounted = 0
        for table in tables {
            try #require(table.rows(in: table.visibleRect).length > 0)
            table.enumerateAvailableRowViews { _, _ in mounted += 1 }
            #expect(table.rowView(atRow: 24, makeIfNecessary: false) == nil)
        }
        #expect(mounted > 0 && mounted < 50)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_RUN_LIVE_WINDOW_SMOKE"] == "1"))
    @MainActor func productionChatListLiveWindowSmokeTest() {
        let fixture = makeProductionChatListFixture()
        let rootController = NSHostingController(
            rootView: DieterRootView()
                .environment(fixture.store)
                .dieterThemeRoot(palette: .monochrome)
                .preferredColorScheme(.dark))
        let islandController = NSHostingController(
            rootView: DieterIslandView(
                presentation: DieterIslandPresentation(),
                onRequestExpansion: { _ in }
            )
            .environment(fixture.store)
            .dieterThemeRoot(palette: .monochrome)
            .preferredColorScheme(.dark))
        let rootWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1_080, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let islandWindow = NSWindow(
            contentRect: NSRect(x: 1_200, y: 100, width: 360, height: 112),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        rootWindow.contentViewController = rootController
        islandWindow.contentViewController = islandController
        rootWindow.orderBack(nil)
        islandWindow.orderBack(nil)
        defer {
            rootWindow.contentViewController = nil
            islandWindow.contentViewController = nil
            rootWindow.close()
            islandWindow.close()
            DieterTheme.install(palette: .monochrome, colorScheme: .light)
        }

        for _ in 0..<60 {
            rootController.view.needsLayout = true
            islandController.view.needsLayout = true
            rootController.view.layoutSubtreeIfNeeded()
            islandController.view.layoutSubtreeIfNeeded()
        }

        #expect(fixture.running == 25)
        #expect(fixture.total == 58)
        #expect(rootWindow.isVisible)
        #expect(islandWindow.isVisible)

        // Let deferred window, font, and accessibility work finish before the
        // steady-state footprint baseline. A non-returning layout transaction
        // still traps this run-loop turn and fails the test timeout.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        _ = rootController.view.accessibilityChildren()
        _ = islandController.view.accessibilityChildren()

        let measurementSeconds = max(
            0,
            Double(ProcessInfo.processInfo.environment["DIETER_LIVE_WINDOW_SMOKE_SECONDS"] ?? "0") ?? 0
        )
        guard measurementSeconds > 0 else { return }

        let baselineFootprint = physicalFootprint()
        let baselineCPU = processCPUTime()
        let measurementStart = Date()
        let deadline = measurementStart.addingTimeInterval(measurementSeconds)
        var nextSnapshot = measurementStart.addingTimeInterval(60)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, nextSnapshot))
            guard Date() >= nextSnapshot else { continue }
            let accessibilityStart = ContinuousClock.now
            _ = rootController.view.accessibilityChildren()
            _ = islandController.view.accessibilityChildren()
            #expect(accessibilityStart.duration(to: .now) < .seconds(2))
            let elapsed = Date().timeIntervalSince(measurementStart)
            let footprintMiB = Double(physicalFootprint()) / 1_048_576
            print(String(format: "Dieter live-window sample: %.0fs, footprint %.1f MiB", elapsed, footprintMiB))
            nextSnapshot = nextSnapshot.addingTimeInterval(60)
        }

        let wallTime = Date().timeIntervalSince(measurementStart)
        let cpuPercent = (processCPUTime() - baselineCPU) / wallTime * 100
        let finalFootprint = physicalFootprint()
        let footprintGrowth = finalFootprint > baselineFootprint ? finalFootprint - baselineFootprint : 0
        print(
            String(
                format: "Dieter live-window result: CPU %.2f%%, footprint growth %.1f MiB",
                cpuPercent,
                Double(footprintGrowth) / 1_048_576
            ))
        #expect(cpuPercent <= 5)
        #expect(footprintGrowth <= 10 * 1_048_576)
    }

    @MainActor
    private func makeProductionChatListFixture() -> (store: DieterStore, running: Int, total: Int) {
        let store = DieterStore(restoreSync: false)
        var chats: [Dieter_V1_Card] = []
        var running = 0
        for pinnedIndex in 0..<8 {
            var chat = Dieter_V1_Card()
            chat.id = "pinned-chat-\(pinnedIndex)"
            chat.projectID = "project-\(pinnedIndex % 10)"
            chat.scope = "chat"
            chat.title = "Pinned conversation \(pinnedIndex)"
            chat.pinned = true
            chat.runtime = "running"
            running += 1
            chats.append(chat)
        }
        for projectIndex in 0..<10 {
            var project = Dieter_V1_Project()
            project.id = "project-\(projectIndex)"
            project.name = "Project \(projectIndex)"
            store.projectDirectory[project.id] = project
            store.projectReplicaEndpointIDs[project.id] = store.endpoint.id

            for chatIndex in 0..<5 {
                var chat = Dieter_V1_Card()
                chat.id = "chat-\(projectIndex)-\(chatIndex)"
                chat.projectID = project.id
                chat.scope = "chat"
                chat.title = "Conversation \(projectIndex)-\(chatIndex)"
                if running < 25 {
                    chat.runtime = "running"
                    running += 1
                } else {
                    chat.runtime = "idle"
                }
                chats.append(chat)
            }
        }
        store.chats = chats
        store.phase = .connected(version: "theme-performance-fixture")
        store.section = .chats
        return (store, running, chats.count)
    }

    @MainActor
    private func makeProductionBoardFixture(laneCounts: [Int] = [65, 5, 4, 4]) -> (
        store: DieterStore,
        board: Dieter_V1_Board,
        total: Int,
        largestLane: Int
    ) {
        let store = DieterStore(restoreSync: false)
        var project = Dieter_V1_Project()
        project.id = "project-board-performance"
        project.name = "Board performance fixture"

        var board = Dieter_V1_Board()
        board.id = "board-performance"
        board.projectID = project.id
        board.name = "Board performance fixture"
        let laneIDs = ["todo", "running", "review", "done"]
        board.lanes = zip(laneIDs, ["Todo", "Running", "Review", "Done"]).map { id, name in
            var lane = Dieter_V1_Lane()
            lane.id = id
            lane.name = name
            return lane
        }
        board.labels = (0..<3).map { index in
            var label = Dieter_V1_Label()
            label.id = "label-\(index)"
            label.name = ["Mac", "Performance", "Gateway"][index]
            label.color = ["#6558df", "#3b82f6", "#16a34a"][index]
            return label
        }

        var cards: [Dieter_V1_Card] = []
        for (laneIndex, laneID) in laneIDs.enumerated() {
            for cardIndex in 0..<laneCounts[laneIndex] {
                let globalIndex = cards.count
                var card = Dieter_V1_Card()
                card.id = "card-board-performance-\(globalIndex)"
                card.projectID = project.id
                card.boardID = board.id
                card.lane = laneID
                card.position = Int64(cardIndex + 1) * 1_024
                card.title =
                    globalIndex.isMultiple(of: 3)
                    ? "Variable-height board card \(globalIndex) with a title that wraps across multiple lines"
                    : "Board card \(globalIndex)"
                card.summary =
                    globalIndex.isMultiple(of: 2)
                    ? "A mixed-content summary exercises the production card's variable-height text and menu graph."
                    : ""
                card.runtime = globalIndex.isMultiple(of: 7) ? "running" : "idle"
                card.model = globalIndex.isMultiple(of: 4) ? "gpt-5" : ""
                card.workspaceMode = globalIndex.isMultiple(of: 5) ? "worktree" : "project"
                if globalIndex.isMultiple(of: 3) {
                    card.labelIds = [board.labels[globalIndex % board.labels.count].id]
                }
                if globalIndex.isMultiple(of: 11) {
                    var subagent = Dieter_V1_Subagent()
                    subagent.id = "subagent-\(globalIndex)"
                    subagent.status = "running"
                    subagent.name = "Fixture scout"
                    card.activeSubagents = [subagent]
                }
                cards.append(card)
            }
        }

        var state = Dieter_V1_State()
        state.project = project
        state.projects = [project]
        state.boards = [board]
        state.cards = cards
        store.state = state
        store.projectDirectory[project.id] = project
        store.navigationBoards[project.id] = [board]
        store.selectedProjectID = project.id
        store.selectedBoardID = board.id
        store.phase = .connected(version: "board-performance-fixture")
        store.section = .board
        return (store, board, cards.count, laneCounts.max() ?? 0)
    }

    @MainActor
    private func productionChatList(store: DieterStore) -> some View {
        ChatsView()
            .environment(store)
            .dieterThemeRoot(palette: .monochrome)
            .preferredColorScheme(.dark)
    }

    @MainActor
    private func productionBoard(store: DieterStore, board: Dieter_V1_Board) -> some View {
        KanbanView(board: board)
            .environment(store)
            .dieterThemeRoot(palette: .monochrome)
            .preferredColorScheme(.dark)
    }

    private func processCPUTime() -> TimeInterval {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
        return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    private func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * linearize(color.redComponent)) + (0.7152 * linearize(color.greenComponent))
            + (0.0722 * linearize(color.blueComponent))
    }
}
