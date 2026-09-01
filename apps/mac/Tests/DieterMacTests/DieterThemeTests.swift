import AppKit
import Darwin
import DieterAPI
import Foundation
import Observation
import SwiftUI
import Testing
@testable import DieterMac

private let macPackageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite(.serialized)
struct DieterThemePerformanceTests {
    @Test func productionThemeAndStatusViewsAvoidContinuousSwiftUIDrivers() throws {
        let sourceRoot = macPackageRoot.appendingPathComponent("Sources/DieterMac")
        let sourceURLs = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )?.allObjects as? [URL])
            .filter { $0.pathExtension == "swift" }
        let productionSource = try sourceURLs.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let themeSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("UI/DieterTheme.swift"),
            encoding: .utf8
        )

        #expect(!productionSource.contains("TimelineView"))
        #expect(!productionSource.contains("NSColor(name:"))
        #expect(!themeSource.contains("NSAppearance"))
    }

    @Test func activityIndicatorIsEntirelyStatic() throws {
        let sourceURL = macPackageRoot.appendingPathComponent("Sources/DieterMac/UI/DieterTheme.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "struct DieterActivityIndicator: View"))
        let end = try #require(source.range(
            of: "struct DieterIconButtonStyle: ButtonStyle",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(!implementation.contains("TimelineView"))
        #expect(!implementation.contains("ProgressView"))
        #expect(implementation.contains("Circle"))
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
            .background(DieterTheme.background)
            .preferredColorScheme(scheme)
            let renderer = ImageRenderer(content: fixture)
            renderer.proposedSize = .init(width: 166, height: 166)

            #expect(renderer.nsImage != nil)
        }
    }

    @Test @MainActor func installingANewThemeInvalidatesExistingColorConsumers() async {
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        DieterTheme.install(palette: .monochrome, colorScheme: .light)
        let (changes, continuation) = AsyncStream<Void>.makeStream()

        withObservationTracking {
            _ = DieterTheme.background
        } onChange: {
            continuation.yield()
        }
        DieterTheme.install(palette: .coralSignal, colorScheme: .dark)

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        continuation.finish()
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

        #expect(fixture.running == 13)
        #expect(fixture.total == 100)
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

    @Test func productionBoardLaneRetainsTheEagerStackWorkaround() throws {
        let sourceURL = macPackageRoot.appendingPathComponent("Sources/DieterMac/UI/BoardView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "struct LaneColumn: View"))
        let end = try #require(source.range(
            of: "private struct LaneInsertionTarget: View",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(implementation.contains("VStack(spacing: 0)"))
        #expect(!implementation.contains("LazyVStack"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_RUN_LIVE_WINDOW_SMOKE"] == "1"))
    @MainActor func productionChatListLiveWindowSmokeTest() {
        let fixture = makeProductionChatListFixture()
        let rootController = NSHostingController(rootView: DieterRootView()
            .environment(fixture.store)
            .dieterThemeRoot(palette: .monochrome)
            .preferredColorScheme(.dark))
        let islandController = NSHostingController(rootView: DieterIslandView(
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

        #expect(fixture.running == 13)
        #expect(fixture.total == 100)
        #expect(rootWindow.isVisible)
        #expect(islandWindow.isVisible)

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
        print(String(
            format: "Dieter live-window result: CPU %.2f%%, footprint growth %.1f MiB",
            cpuPercent,
            Double(footprintGrowth) / 1_048_576
        ))
        #expect(cpuPercent <= 5)
        #expect(footprintGrowth <= 10 * 1_048_576)
    }

    @MainActor
    private func makeProductionChatListFixture() -> (store: DieterStore, running: Int, total: Int) {
        let store = DieterStore()
        var chats: [Dieter_V1_Card] = []
        var running = 0
        for projectIndex in 0..<20 {
            var project = Dieter_V1_Project()
            project.id = "project-\(projectIndex)"
            project.name = "Project \(projectIndex)"
            store.projectDirectory[project.id] = project

            for chatIndex in 0..<5 {
                var chat = Dieter_V1_Card()
                chat.id = "chat-\(projectIndex)-\(chatIndex)"
                chat.projectID = project.id
                chat.scope = "chat"
                chat.title = "Conversation \(projectIndex)-\(chatIndex)"
                if running < 13 {
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
    private func makeProductionBoardFixture() -> (
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
        let laneCounts = [65, 5, 4, 4]
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
                card.title = globalIndex.isMultiple(of: 3)
                    ? "Variable-height board card \(globalIndex) with a title that wraps across multiple lines"
                    : "Board card \(globalIndex)"
                card.summary = globalIndex.isMultiple(of: 2)
                    ? "A mixed-content summary exercises the production card's variable-height text and menu graph."
                    : ""
                card.runtime = globalIndex.isMultiple(of: 7) ? "running" : "idle"
                card.model = globalIndex.isMultiple(of: 4) ? "gpt-5" : ""
                card.workspaceMode = globalIndex.isMultiple(of: 5) ? "worktree" : "project"
                card.commentCount = globalIndex.isMultiple(of: 6) ? 2 : 0
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
}
