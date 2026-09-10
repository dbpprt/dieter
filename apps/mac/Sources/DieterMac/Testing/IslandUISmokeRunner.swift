#if DIETER_UI_SMOKE
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
            let expandedSettled = await waitForExpandedLayout(controller: controller, activity: store.islandActivity)
            let expandedSize = controller.islandWindow?.frame.size ?? .zero
            let expanded =
                expandedSettled && controller.isExpanded
                && expandedSize == DieterIslandLayout.expandedSize(itemCount: store.islandActivity.items.count)
            let expandedInsets = sectionInsets(controller: controller, activity: store.islandActivity)
            if let window = controller.islandWindow {
                capture(window, to: output.appending(path: "island-expanded.png"))
            }

            store.state.cards = Array(store.state.cards.prefix(1))
            let singleItemSettled = await waitForExpandedLayout(controller: controller, activity: store.islandActivity)
            let singleItemSize = controller.islandWindow?.frame.size ?? .zero
            let singleItemExpanded =
                singleItemSettled && controller.isExpanded
                && singleItemSize == DieterIslandLayout.expandedSize(itemCount: 1)
            let singleItemInsets = sectionInsets(controller: controller, activity: store.islandActivity)
            if let window = controller.islandWindow {
                capture(window, to: output.appending(path: "island-expanded-single.png"))
            }

            store.state.cards = []
            let emptySettled = await waitForExpandedLayout(controller: controller, activity: store.islandActivity)
            let emptySize = controller.islandWindow?.frame.size ?? .zero
            let emptyExpanded =
                emptySettled && controller.isExpanded && emptySize == DieterIslandLayout.expandedSize(itemCount: 0)
            let emptyInsets = sectionInsets(controller: controller, activity: store.islandActivity)
            if let window = controller.islandWindow {
                capture(window, to: output.appending(path: "island-expanded-empty.png"))
            }

            let captureDestination = installNavigationFixture(in: store)
            store.projectDirectory[captureDestination.projectID]?.hostnames = []
            var captureBoards = store.navigationBoards[captureDestination.projectID] ?? []
            captureBoards[0].hostnames = ["127.0.0.1:4018"]
            var otherPort = captureBoards[0]
            otherPort.id = "island-other-port-board"
            otherPort.name = "Other local app"
            otherPort.hostnames = ["127.0.0.1:4019"]
            var hostFallback = captureBoards[0]
            hostFallback.id = "island-host-fallback-board"
            hostFallback.name = "Host fallback"
            hostFallback.hostnames = ["127.0.0.1"]
            store.navigationBoards[captureDestination.projectID] = [otherPort, hostFallback] + captureBoards
            store.selectedProjectID = ""
            store.selectedBoardID = ""
            let captureDirectory = output.appending(path: "capture-input")
            try? FileManager.default.createDirectory(
                at: captureDirectory, withIntermediateDirectories: true)
            let captureFile = captureDirectory.appending(path: "capture.png")
            let image = NSImage(size: NSSize(width: 180, height: 90))
            image.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 180, height: 90).fill()
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try? png.write(to: captureFile)
            }
            controller.installCaptureFixture(
                file: captureFile,
                browser: CaptureBrowserContext(url: "http://127.0.0.1:4018/commitments/3", browser: true))
            let captureClicked =
                controller.islandWindow.map { NativeUIAccessibility.click("island.capture-task", in: $0) }
                ?? false
            let captureOpened = await waitUntil {
                guard
                    let window = NSApp.windows.first(where: { $0.title == "Capture task" && $0.isVisible })
                else { return false }
                return NativeUIAccessibility.find("quick-task.attachments", in: window) != nil
                    && NativeUIAccessibility.find("quick-task.source-url", in: window) != nil
            }
            let captureRouted =
                store.selectedProjectID == captureDestination.projectID
                && store.selectedBoardID == captureDestination.boardID
            var captureAttachment = false
            var captureURL = false
            if let draftWindow = NSApp.windows.first(where: { $0.title == "Capture task" && $0.isVisible }
            ) {
                captureAttachment =
                    NativeUIAccessibility.find("quick-task.attachments", in: draftWindow) != nil
                captureURL = NativeUIAccessibility.find("quick-task.source-url", in: draftWindow) != nil
                try? NativeUIAccessibility.elements(in: draftWindow).map(\.text).joined(separator: "\n")
                    .write(
                        to: output.appending(path: "capture-draft-accessibility.txt"), atomically: true,
                        encoding: .utf8)
                capture(draftWindow, to: output.appending(path: "capture-task-draft.png"))
                draftWindow.close()
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
            let boardCardOpened =
                store.section == .board && store.selectedProjectID == navigation.projectID
                && store.selectedBoardID == navigation.boardID && store.selectedCardID == navigation.cardID
                && store.selectedChatID == nil
            await store.openConversation(cardID: navigation.chatID)
            let chatOpened =
                store.section == .chats && store.selectedProjectID == navigation.projectID
                && store.selectedCardID == nil && store.selectedChatID == navigation.chatID

            store.openSettings(section: .island)
            try? await DieterTaskSleep.milliseconds(450)
            let settingsVisible = store.section == .settings && store.settingsSection == .island
            if let window = NSApp.windows.first(where: { $0.title == "Dieter" && $0.isVisible }) {
                capture(window, to: output.appending(path: "island-settings.png"))
            }
            let displayChecks = await checkDisplayMovement(
                controller: controller, activity: store.islandActivity, defaults: defaults, output: output)

            writeReport(
                [
                    "capture-port-routing": captureRouted
                        ? "passed"
                        : "failed: browser port did not select the matching board ahead of other ports and host fallback",
                    "capture-task-button": captureClicked
                        ? "passed" : "failed: capture button did not dispatch",
                    "capture-task-draft": captureOpened && captureAttachment && captureURL
                        ? "passed" : "failed: screenshot or URL draft absent",
                    "capture-temp-cleanup": !FileManager.default.fileExists(atPath: captureFile.path)
                        ? "passed" : "failed: capture file retained",
                    "collapsed-window": appeared ? "passed" : "failed: island window did not appear",
                    "expanded-window": expanded
                        ? "passed" : "failed: island did not expand to its activity panel",
                    "expanded-section-insets": expandedInsets,
                    "single-activity-layout": singleItemExpanded
                        ? "passed" : "failed: single activity did not fit its compact content height",
                    "single-activity-section-insets": singleItemInsets,
                    "empty-activity-layout": emptyExpanded
                        ? "passed" : "failed: empty activity did not fit its compact content height",
                    "empty-activity-section-insets": emptyInsets,
                    "settings-toggle-off": hidden
                        ? "passed" : "failed: disabling the preference left the island visible",
                    "settings-toggle-on": restored
                        ? "passed" : "failed: re-enabling the preference did not restore the island",
                    "open-board-card": boardCardOpened
                        ? "passed" : "failed: activity did not route to its project and board",
                    "open-chat": chatOpened ? "passed" : "failed: activity did not route to Chats",
                    "settings-page": settingsVisible
                        ? "passed" : "failed: Island was not the active Settings destination",
                ].merging(displayChecks) { _, checked in checked }, to: output)
            NSApp.terminate(nil)
        }

        private static func checkDisplayMovement(
            controller: DieterIslandController, activity: DieterIslandActivity, defaults: UserDefaults, output: URL
        ) async -> [String: String] {
            var results = [
                "display-picker": "failed: picker did not open",
                "display-selection": "failed: display was not selected",
                "display-placement": "failed: island was not placed on the selected display",
                "display-automatic": "failed: Automatic was not restored",
            ]
            // Always return this isolated fixture to Automatic, even if a UI
            // assertion fails. The explicit Automatic action is checked first.
            defer {
                controller.setExpanded(false, animated: false)
                controller.moveToDisplay(nil)
            }
            let displays = controller.availableDisplays
            guard let target = displays.first(where: { $0.id != controller.currentDisplayID }) ?? displays.first,
                let window = controller.islandWindow
            else {
                results["display-picker"] = "failed: no attached display or island window"
                return results
            }
            controller.setExpanded(true, animated: false)
            let expandedSettled = await waitForExpandedLayout(controller: controller, activity: activity)
            let ready = await waitForIslandTarget("island.display-picker", in: window, activate: true)
            let opened = expandedSettled && ready && NativeUIAccessibility.press("island.display-picker", in: window)
            let targetID = "island.display.\(target.id)"
            let choicesReady = opened ? await waitForIslandTarget(targetID, in: window) : false
            results["display-picker"] =
                choicesReady ? "passed" : "failed: expanded=\(expandedSettled), ready=\(ready), opened=\(opened)"
            guard choicesReady else {
                writeDisplayDiagnostics(targetID, in: window, controller: controller, output: output)
                return results
            }
            if let popover = NativeUIAccessibility.find("island.display-options", in: window)?.recordedWindow {
                capture(popover, to: output.appending(path: "island-display-options.png"))
            }
            let selected = NativeUIAccessibility.click(targetID, in: window)
            let moved = await waitUntil {
                controller.currentDisplayID == target.id
                    && DieterIslandPreferences.displayID(in: defaults) == target.id
                    && NativeUIAccessibility.find("island.display-options", in: window)?.recordedWindow?.isVisible
                        != true
            }
            results["display-selection"] =
                selected && moved
                ? "passed"
                : "failed: clicked=\(selected), current=\(controller.currentDisplayID ?? "nil"), saved=\(DieterIslandPreferences.displayID(in: defaults) ?? "nil"), expected=\(target.id)"
            let placed = await waitUntil {
                guard let frame = controller.islandWindow?.frame else { return false }
                return controller.currentDisplayID == target.id
                    && target.geometry.screenFrame.insetBy(dx: -1, dy: -1).contains(frame)
            }
            results["display-placement"] =
                placed
                ? "passed" : "failed: island frame=\(window.frame), display frame=\(target.geometry.screenFrame)"
            capture(window, to: output.appending(path: "island-moved-display.png"))

            let automaticReady = await waitForIslandTarget("island.display-picker", in: window, activate: true)
            let reopened = automaticReady && NativeUIAccessibility.press("island.display-picker", in: window)
            let automaticVisible = reopened ? await waitForIslandTarget("island.display.automatic", in: window) : false
            guard automaticVisible else {
                results["display-automatic"] = "failed: picker did not reopen for Automatic"
                return results
            }
            let connected = controller.availableDisplays
            let mainID = NSScreen.main.flatMap { screen in
                connected.first { $0.geometry.screenFrame == screen.frame }?.id
            }
            let automaticDisplay = DieterIslandDisplay.selected(
                preferredID: nil, displays: connected, mainDisplayID: mainID)
            let automaticClicked = NativeUIAccessibility.click("island.display.automatic", in: window)
            let automaticRestored = await waitUntil {
                guard let display = automaticDisplay, let frame = controller.islandWindow?.frame else { return false }
                return DieterIslandPreferences.displayID(in: defaults) == nil
                    && controller.currentDisplayID == display.id
                    && display.geometry.screenFrame.insetBy(dx: -1, dy: -1).contains(frame)
                    && NativeUIAccessibility.find("island.display-options", in: window)?.recordedWindow?.isVisible
                        != true
            }
            results["display-automatic"] =
                automaticClicked && automaticRestored
                ? "passed"
                : "failed: clicked=\(automaticClicked), current=\(controller.currentDisplayID ?? "nil"), saved=\(DieterIslandPreferences.displayID(in: defaults) ?? "nil"), expected=\(automaticDisplay?.id ?? "nil")"
            capture(window, to: output.appending(path: "island-automatic-display.png"))
            return results
        }

        /// Wait for AppKit activation and stable geometry, then callers dispatch
        /// a single pointer gesture. No selection action is retried.
        private static func waitForIslandTarget(_ identifier: String, in window: NSWindow, activate: Bool = false) async
            -> Bool
        {
            var previousFrame: CGRect?
            var previousHost: NSWindow?
            var stableSamples = 0
            var nextActivation = Date.distantPast
            return await waitUntil(timeout: 8) {
                if activate, (!NSApp.isActive || !window.isKeyWindow), Date() >= nextActivation {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    nextActivation = Date().addingTimeInterval(1)
                }
                guard !activate || (NSApp.isActive && window.isKeyWindow),
                    let target = NativeUIAccessibility.find(identifier, in: window),
                    let host = target.recordedWindow, host.isVisible, let frame = target.recordedFrame,
                    frame.width > 0, frame.height > 0, host.frame.insetBy(dx: -1, dy: -1).contains(frame)
                else {
                    stableSamples = 0
                    return false
                }
                stableSamples = frame == previousFrame && host === previousHost ? stableSamples + 1 : 0
                previousFrame = frame
                previousHost = host
                return stableSamples >= 3
            }
        }

        /// The SwiftUI spring still scales the content after the panel itself
        /// reaches its target frame, including setExpanded(animated: false).
        private static func waitForExpandedLayout(
            controller: DieterIslandController, activity: DieterIslandActivity
        ) async -> Bool {
            var previousFrames: [CGRect] = []
            var stableSamples = 0
            return await waitUntil(timeout: 5) {
                guard controller.isExpanded, let window = controller.islandWindow,
                    window.frame.size == DieterIslandLayout.expandedSize(itemCount: activity.items.count),
                    sectionInsets(controller: controller, activity: activity) == "passed"
                else {
                    stableSamples = 0
                    return false
                }
                let frames =
                    [window.frame]
                    + sectionIdentifiers(activity: activity).compactMap {
                        NativeUIAccessibility.find($0, in: window)?.recordedFrame
                    }
                stableSamples = frames == previousFrames ? stableSamples + 1 : 0
                previousFrames = frames
                return stableSamples >= 3
            }
        }

        private static func writeDisplayDiagnostics(
            _ identifier: String, in window: NSWindow, controller: DieterIslandController, output: URL
        ) {
            let targets = ["island.display-picker", "island.display-options", identifier].map { id in
                guard let target = NativeUIAccessibility.find(id, in: window) else { return "\(id): absent" }
                return
                    "\(id): frame=\(String(describing: target.recordedFrame)), host=\(String(describing: target.recordedWindow?.frame)), visible=\(target.recordedWindow?.isVisible == true)"
            }
            let windows = NSApp.windows.filter(\.isVisible).map {
                "\(type(of: $0)) title=\($0.title), frame=\($0.frame), key=\($0.isKeyWindow), parent=\(String(describing: $0.parent?.windowNumber))"
            }
            let details =
                ["expanded=\(controller.isExpanded), active=\(NSApp.isActive), islandKey=\(window.isKeyWindow)"]
                + targets + windows
            try? details.joined(separator: "\n").write(
                to: output.appending(path: "island-display-picker-diagnostics.txt"), atomically: true, encoding: .utf8)
            capture(window, to: output.appending(path: "island-display-picker-failed.png"))
        }

        private static func sectionIdentifiers(activity: DieterIslandActivity) -> [String] {
            var identifiers = ["island.header", "island.footer"]
            if !activity.items.isEmpty {
                identifiers.append("island.activity-heading")
                identifiers += activity.items.map { "island.activity-row.\($0.id)" }
            }
            return identifiers
        }

        private static func sectionInsets(
            controller: DieterIslandController, activity: DieterIslandActivity
        ) -> String {
            guard let window = controller.islandWindow else { return "failed: island window unavailable" }
            let expected = window.frame.insetBy(dx: DieterIslandLayout.horizontalInset, dy: 0)
            var failures: [String] = []
            for identifier in sectionIdentifiers(activity: activity) {
                guard let element = NativeUIAccessibility.find(identifier, in: window),
                    element.recordedWindow === window, let frame = element.recordedFrame,
                    frame.width > 0, frame.height > 0
                else {
                    failures.append("\(identifier) missing")
                    continue
                }
                if abs(frame.minX - expected.minX) > 1 || abs(frame.maxX - expected.maxX) > 1 {
                    failures.append("\(identifier) horizontal bounds \(frame.minX)...\(frame.maxX)")
                }
            }
            return failures.isEmpty
                ? "passed"
                : "failed: expected \(expected.minX)...\(expected.maxX); " + failures.joined(separator: "; ")
        }

        private static func installFixture(in store: DieterStore) {
            let now = DieterTimestamp.string(from: Date())
            var board = Dieter_V1_Board()
            board.id = "island-board"
            board.name = "Mac polish"
            var running = Dieter_V1_Card()
            running.id = "island-running"
            running.boardID = board.id
            running.title = "Polish the Dieter Island"
            running.runtime = "running"
            running.lane = "running"
            running.provider = "codex"
            running.summary = "Building the native notch activity panel"
            running.runtimeUpdatedAt = now
            var review = Dieter_V1_Card()
            review.id = "island-review"
            review.boardID = board.id
            review.title = "Verify Settings toggle"
            review.runtime = "waiting_for_user"
            review.lane = "review"
            review.provider = "codex"
            review.runtimeUpdatedAt = now
            var done = Dieter_V1_Card()
            done.id = "island-done"
            done.boardID = board.id
            done.title = "Detect the built-in display"
            done.runtime = "completed"
            done.lane = "done"
            done.provider = "codex"
            done.runtimeUpdatedAt = now
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

        private static func waitUntil(
            timeout: TimeInterval = 5, condition: @escaping @MainActor () -> Bool
        ) async
            -> Bool
        {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await DieterTaskSleep.milliseconds(100)
            }
            return condition()
        }

        private static func outputDirectory() -> URL {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--island-ui-smoke-output"),
                arguments.indices.contains(index + 1)
            {
                return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            }
            return URL(filePath: NSTemporaryDirectory()).appending(
                path: "dieter-island-ui-smoke", directoryHint: .isDirectory)
        }

        private static func capture(_ window: NSWindow, to url: URL) {
            guard let view = window.contentView,
                let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url, options: .atomic)
        }

        private static func writeReport(_ values: [String: String], to directory: URL) {
            let data = try? JSONSerialization.data(
                withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: directory.appending(path: "report.json"), options: .atomic)
        }
    }
#endif
