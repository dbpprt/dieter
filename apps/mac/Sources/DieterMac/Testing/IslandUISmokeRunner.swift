import AppKit
import DieterAPI
import Foundation

@MainActor
enum IslandUISmokeRunner {
    static func run(store: DieterStore, controller: DieterIslandController) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        installFixture(in: store)

        let defaults = DieterAppearance.applicationDefaults()
        DieterIslandPreferences.setEnabled(true, in: defaults)
        controller.setEnabled(true)
        let appeared = await waitUntil { controller.isVisible }
        if appeared, let window = controller.islandWindow {
            capture(window, to: output.appending(path: "island-collapsed.png"))
        }

        controller.setExpanded(true, animated: false)
        try? await DieterTaskSleep.milliseconds(450)
        let expandedSize = controller.islandWindow?.frame.size ?? .zero
        let expanded = controller.isExpanded && expandedSize.width == 600 && expandedSize.height >= 300
        if let window = controller.islandWindow {
            capture(window, to: output.appending(path: "island-expanded.png"))
        }

        store.state.cards = Array(store.state.cards.prefix(1))
        try? await DieterTaskSleep.milliseconds(600)
        let singleItemSize = controller.islandWindow?.frame.size ?? .zero
        let singleItemExpanded = controller.isExpanded && singleItemSize == CGSize(width: 600, height: 302)
        if let window = controller.islandWindow {
            capture(window, to: output.appending(path: "island-expanded-single.png"))
        }

        store.state.cards = []
        try? await DieterTaskSleep.milliseconds(600)
        let emptySize = controller.islandWindow?.frame.size ?? .zero
        let emptyExpanded = controller.isExpanded && emptySize == CGSize(width: 600, height: 324)
        if let window = controller.islandWindow {
            capture(window, to: output.appending(path: "island-expanded-empty.png"))
        }

        DieterIslandPreferences.setEnabled(false, in: defaults)
        controller.setEnabled(false)
        try? await DieterTaskSleep.milliseconds(150)
        let hidden = !controller.isVisible

        DieterIslandPreferences.setEnabled(true, in: defaults)
        controller.setEnabled(true)
        let restored = await waitUntil { controller.isVisible }

        let navigation = installNavigationFixture(in: store)
        await store.openConversation(cardID: navigation.cardID)
        let boardCardOpened = store.section == .board &&
            store.selectedProjectID == navigation.projectID &&
            store.selectedBoardID == navigation.boardID &&
            store.selectedCardID == navigation.cardID &&
            store.selectedChatID == nil
        await store.openConversation(cardID: navigation.chatID)
        let chatOpened = store.section == .chats &&
            store.selectedProjectID == navigation.projectID &&
            store.selectedCardID == nil &&
            store.selectedChatID == navigation.chatID

        store.openSettings(section: .island)
        try? await DieterTaskSleep.milliseconds(450)
        let settingsVisible = store.section == .settings && store.settingsSection == .island
        if let window = NSApp.windows.first(where: { $0.title == "Dieter" && $0.isVisible }) {
            capture(window, to: output.appending(path: "island-settings.png"))
        }

        writeReport([
            "collapsed-window": appeared ? "passed" : "failed: island window did not appear",
            "expanded-window": expanded ? "passed" : "failed: island did not expand to its activity panel",
            "single-activity-layout": singleItemExpanded ? "passed" : "failed: single activity did not use the roomy minimum layout",
            "empty-activity-layout": emptyExpanded ? "passed" : "failed: empty activity did not use the balanced minimum layout",
            "settings-toggle-off": hidden ? "passed" : "failed: disabling the preference left the island visible",
            "settings-toggle-on": restored ? "passed" : "failed: re-enabling the preference did not restore the island",
            "open-board-card": boardCardOpened ? "passed" : "failed: activity did not route to its project and board",
            "open-chat": chatOpened ? "passed" : "failed: activity did not route to Chats",
            "settings-page": settingsVisible ? "passed" : "failed: Island was not the active Settings destination",
        ], to: output)
        NSApp.terminate(nil)
    }

    private static func installFixture(in store: DieterStore) {
        let now = DieterTimestamp.string(from: Date())
        var board = Dieter_V1_Board(); board.id = "island-board"; board.name = "Mac polish"
        var running = Dieter_V1_Card()
        running.id = "island-running"; running.boardID = board.id; running.title = "Polish the Dieter Island"
        running.runtime = "running"; running.lane = "running"; running.provider = "codex"
        running.summary = "Building the native notch activity panel"; running.runtimeUpdatedAt = now
        var review = Dieter_V1_Card()
        review.id = "island-review"; review.boardID = board.id; review.title = "Verify Settings toggle"
        review.runtime = "waiting_for_user"; review.lane = "review"; review.provider = "codex"
        review.runtimeUpdatedAt = now
        var done = Dieter_V1_Card()
        done.id = "island-done"; done.boardID = board.id; done.title = "Detect the built-in display"
        done.runtime = "completed"; done.lane = "done"; done.provider = "codex"; done.runtimeUpdatedAt = now
        store.state.boards = [board]
        store.state.cards = [running, review, done]
        store.phase = .connected(version: "island-smoke")
    }

    private static func installNavigationFixture(
        in store: DieterStore
    ) -> (projectID: String, boardID: String, cardID: String, chatID: String) {
        var project = Dieter_V1_Project()
        project.id = "island-navigation-project"
        project.name = "Island navigation"
        var board = Dieter_V1_Board()
        board.id = "island-navigation-board"
        board.projectID = project.id
        board.name = "Activity"
        var card = Dieter_V1_Card()
        card.id = "island-navigation-card"
        card.projectID = project.id
        card.boardID = board.id
        card.title = "Open board card"
        var chat = Dieter_V1_Card()
        chat.id = "island-navigation-chat"
        chat.projectID = project.id
        chat.scope = "chat"
        chat.title = "Open chat"
        store.projectDirectory[project.id] = project
        store.navigationBoards[project.id] = [board]
        store.navigationCards[project.id] = [card]
        store.chats = [chat]
        return (project.id, board.id, card.id, chat.id)
    }

    private static func waitUntil(timeout: TimeInterval = 5, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await DieterTaskSleep.milliseconds(100)
        }
        return condition()
    }

    private static func outputDirectory() -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--island-ui-smoke-output"), arguments.indices.contains(index + 1) {
            return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        }
        return URL(filePath: NSTemporaryDirectory()).appending(path: "dieter-island-ui-smoke", directoryHint: .isDirectory)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func writeReport(_ values: [String: String], to directory: URL) {
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: directory.appending(path: "report.json"), options: .atomic)
    }
}
