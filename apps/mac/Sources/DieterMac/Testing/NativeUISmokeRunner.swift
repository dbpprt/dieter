import AppKit
import DieterAPI
import Foundation

/// An in-process smoke driver for a native app.
///
/// Events are delivered to Dieter's own NSWindow and snapshots are read from its
/// own content view. This exercises the same SwiftUI button hit-testing as a
/// person while requiring neither Accessibility nor Screen Recording access.
@MainActor
enum NativeUISmokeRunner {
    private struct Step {
        let name: String
        let section: AppSection
        let distanceFromTop: CGFloat
    }

    static func run(store: DieterStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard await waitUntil(timeout: 20, condition: {
            store.phase.isConnected && !store.projects.isEmpty && store.projects.contains { !store.boards(for: $0.id).isEmpty }
        }) else {
            writeReport([
                "connection": "failed: fixture workspace did not become ready",
                "phase": store.phase.label,
                "projects": "\(store.projects.count)",
            ], to: output)
            return
        }
        guard let project = store.projects.first(where: { !store.boards(for: $0.id).isEmpty }),
              let board = store.boards(for: project.id).first else {
            writeReport(["fixture": "failed: project or board missing"], to: output)
            return
        }
        store.selectedProjectID = project.id
        store.selectedBoardID = board.id
        if store.state.cards.allSatisfy({ $0.boardID != board.id }) {
            guard let rpc = store.rpc else {
                writeReport(["fixture": "failed: RPC client missing"], to: output)
                return
            }
            var request = Dieter_V1_CreateConversationRequest()
            request.projectID = project.id
            request.boardID = board.id
            request.lane = board.lanes.first?.id ?? "backlog"
            request.title = "Native UI smoke fixture"
            request.prompt = "Keep this deferred. It only exercises the packaged UI."
            request.provider = store.harnessCatalog.harnesses.first?.id ?? "mock"
            request.deferStart = true
            do {
                _ = try await rpc.createCard(request)
                await store.refreshState()
            } catch {
                writeReport(["fixture": "failed: \(error.localizedDescription)"], to: output)
                return
            }
        }
        await store.openBoard(board.id, projectID: project.id)
        try? await DieterTaskSleep.seconds(1)

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Dieter" })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            writeReport(["error": "Dieter window not found"], to: output)
            return
        }

        window.setContentSize(NSSize(width: 1_380, height: 870))
        window.center()
        window.makeKeyAndOrderFront(nil)
        try? await DieterTaskSleep.milliseconds(500)

        var results: [String: String] = [
            "connection": "passed",
            "fixture-project": project.name,
        ]
        let originalWindowFrame = window.frame
        let originalZoomedState = window.isZoomed
        doubleClickTitleBar(of: window)
        try? await DieterTaskSleep.seconds(1)
        results["window-titlebar-double-click"] = window.isZoomed != originalZoomedState && window.frame != originalWindowFrame
            ? "passed"
            : "failed: hidden title-bar double-click did not toggle the window zoom state"
        doubleClickTitleBar(of: window)
        try? await DieterTaskSleep.seconds(1)
        if window.frame != originalWindowFrame {
            window.setFrame(originalWindowFrame, display: true)
        }
        let appearanceDefaults = DieterAppearance.applicationDefaults()
        appearanceDefaults.set(DieterAppearance.dark.rawValue, forKey: DieterAppearance.storageKey)
        try? await DieterTaskSleep.milliseconds(300)
        await captureAppearances(window, named: "01-board.png", in: output)
        results["board-initial"] = store.section.rawValue

        click(window: window, x: 164, distanceFromTop: 54)
        try? await DieterTaskSleep.milliseconds(500)
        await captureAppearances(window, named: "01b-navigation-collapsed.png", in: output)
        click(window: window, x: 29, distanceFromTop: 138)
        try? await DieterTaskSleep.seconds(1)
        results["navigation-collapse"] = store.section == .chats ? "passed" : "failed: collapsed rail did not navigate"
        click(window: window, x: 29, distanceFromTop: 58)
        try? await DieterTaskSleep.milliseconds(500)
        let steps = [Step(name: "02-global-chats", section: .chats, distanceFromTop: 138)]
        for step in steps {
            click(window: window, x: 80, distanceFromTop: step.distanceFromTop)
            try? await DieterTaskSleep.seconds(1)
            results[step.name] = store.section == step.section ? "passed" : "failed: \(store.section.rawValue)"
            await captureAppearances(window, named: "\(step.name).png", in: output)
        }

        click(window: window, x: 500, distanceFromTop: 65)
        try? await DieterTaskSleep.seconds(1)
        results["03-standalone-chat"] = store.section == .chats && store.newChatProjectID == project.id
            ? "passed"
            : "failed: new chat composer did not open"
        await captureAppearances(window, named: "03-standalone-chat.png", in: output)

        let remaining = [
            Step(name: "04-project-files", section: .files, distanceFromTop: 281),
            Step(name: "05-project-schedules", section: .schedules, distanceFromTop: 315),
            Step(name: "06-board", section: .board, distanceFromTop: 247),
        ]
        for step in remaining {
            click(window: window, x: 55, distanceFromTop: step.distanceFromTop)
            try? await DieterTaskSleep.seconds(1)
            results[step.name] = store.section == step.section ? "passed" : "failed: \(store.section.rawValue)"
            await captureAppearances(window, named: "\(step.name).png", in: output)
        }

        click(window: window, x: 370, distanceFromTop: 215)
        try? await DieterTaskSleep.seconds(1)
        results["07-card-conversation"] = store.selectedCardID == nil ? "failed: no card selected" : "passed"
        await captureAppearances(window, named: "07-card-conversation.png", in: output)

        store.openSettings()
        try? await DieterTaskSleep.milliseconds(700)
        results["09-settings-general"] = store.section == .settings ? "passed" : "failed: settings did not open"
        await captureAppearances(window, named: "09-settings-general.png", in: output)

        appearanceDefaults.set(DieterAppearance.light.rawValue, forKey: DieterAppearance.storageKey)
        try? await DieterTaskSleep.milliseconds(700)
        let storedAppearance = DieterAppearance.resolve(appearanceDefaults.string(forKey: DieterAppearance.storageKey))
        let effectiveAppearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        results["09b-settings-light-appearance"] = storedAppearance == .light && effectiveAppearance == .aqua
            ? "passed"
            : "failed: stored=\(storedAppearance.rawValue), effective=\(effectiveAppearance?.rawValue ?? "unknown")"
        await captureAppearances(window, named: "09b-settings-light-appearance.png", in: output)

        click(window: window, x: 320, distanceFromTop: 151)
        try? await DieterTaskSleep.milliseconds(700)
        await captureAppearances(window, named: "10-settings-connection.png", in: output)
        results["10-settings-connection"] = "passed"

        await store.cleanSync()
        let cleanSyncRecovered = await waitUntil(timeout: 20) {
            store.phase.isConnected && !store.projects.isEmpty
        }
        results["10b-settings-clean-sync"] = cleanSyncRecovered
            ? "passed"
            : "failed: clean sync did not rebuild the workspace (\(store.phase.label), \(store.projects.count) projects)"

        click(window: window, x: 320, distanceFromTop: 187)
        try? await DieterTaskSleep.seconds(1)
        await captureAppearances(window, named: "11-settings-prompts.png", in: output)
        results["11-settings-prompts"] = "passed"

        store.section = .board
        store.labelsPresented = true
        try? await DieterTaskSleep.milliseconds(700)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            await captureAppearances(sheet, named: "12-board-label-editor.png", in: output)
            results["12-board-label-editor"] = "passed"
        } else {
            results["12-board-label-editor"] = "failed: sheet not visible"
        }
        store.labelsPresented = false
        try? await DieterTaskSleep.milliseconds(350)

        let connectedPhase = store.phase
        store.phase = .authenticationRequired
        try? await DieterTaskSleep.milliseconds(700)
        await captureAppearances(window, named: "12b-connection-onboarding.png", in: output)
        results["12b-connection-onboarding"] = store.phase.needsConnectionOverlay ? "passed" : "failed: overlay phase inactive"
        store.phase = connectedPhase
        try? await DieterTaskSleep.milliseconds(350)

        store.createConversationPresented = true
        try? await DieterTaskSleep.milliseconds(700)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            await captureAppearances(sheet, named: "13-new-card.png", in: output)
            results["13-new-card"] = "passed"
        } else {
            results["13-new-card"] = "failed: sheet not visible"
        }
        store.createConversationPresented = false
        try? await DieterTaskSleep.milliseconds(350)

        store.section = .board
        store.closeConversation()
        let todoLane = board.lanes.first(where: { $0.id.caseInsensitiveCompare("todo") == .orderedSame })
        if let todoLane {
            let title = "Native UI todo creation \(UUID().uuidString.lowercased())"
            let harness = store.harnessCatalog.harnesses.first
            await store.createConversation(
                title: title,
                prompt: "Create this deferred card without opening its conversation.",
                chat: false,
                provider: harness?.id ?? "",
                model: harness?.defaultModel ?? "",
                effort: harness?.models.first(where: { $0.id == harness?.defaultModel })?.defaultEffort ?? "",
                deferred: true,
                lane: todoLane.id
            )
            let created = await waitUntil(timeout: 10) {
                store.state.cards.contains { $0.title == title && $0.lane.caseInsensitiveCompare("todo") == .orderedSame }
            }
            results["13b-todo-card-stays-on-board"] = created && store.section == .board && store.selectedCardID == nil
                ? "passed"
                : "failed: created=\(created), section=\(store.section.rawValue), selected=\(store.selectedCardID ?? "none")"
        } else {
            results["13b-todo-card-stays-on-board"] = "failed: fixture board has no Todo lane"
        }

        store.section = .chats
        store.closeConversation()
        store.errorMessage = nil
        let chatTitle = "Native UI chat creation \(UUID().uuidString.lowercased())"
        let chatHarness = store.harnessCatalog.harnesses.first(where: { $0.id == "mock" })
            ?? store.harnessCatalog.harnesses.first
        await store.createConversation(
            title: chatTitle,
            prompt: "Create and open this standalone chat.",
            chat: true,
            provider: chatHarness?.id ?? "",
            model: chatHarness?.defaultModel ?? "",
            effort: chatHarness?.models.first(where: { $0.id == chatHarness?.defaultModel })?.defaultEffort ?? "",
            deferred: false,
            projectID: project.id
        )
        let openedChat = await waitUntil(timeout: 10) {
            guard let chatID = store.selectedChatID, DieterConversationID.isServerBacked(chatID) else { return false }
            return store.conversation?.detail.card.id == chatID && !store.conversationLoading
        }
        results["13c-standalone-chat-opens"] = openedChat && store.errorMessage == nil
            ? "passed"
            : "failed: selected=\(store.selectedChatID ?? "none"), loading=\(store.conversationLoading), error=\(store.errorMessage ?? "none")"
        store.closeConversation()

        store.createProjectPresented = true
        try? await DieterTaskSleep.milliseconds(700)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            await captureAppearances(sheet, named: "14-new-project.png", in: output)
            results["14-new-project"] = "passed"
            click(window: sheet, x: 605, distanceFromTop: 239)
            try? await DieterTaskSleep.seconds(1.5)
            if let browser = NSApp.windows.first(where: {
                $0.isSheet && $0.isVisible && $0.windowNumber != sheet.windowNumber
            }) {
                await captureAppearances(browser, named: "15-remote-directory-browser.png", in: output)
                results["15-remote-directory-browser"] = "passed"
            } else {
                results["15-remote-directory-browser"] = "failed: browser sheet not visible"
            }
        } else {
            results["14-new-project"] = "failed: sheet not visible"
        }
        store.createProjectPresented = false
        try? await DieterTaskSleep.milliseconds(350)

        store.section = .board
        try? await DieterTaskSleep.milliseconds(700)
        await captureAppearances(window, named: "16-light-workspace.png", in: output)
        results["16-light-workspace"] = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? "passed"
            : "failed: light appearance did not persist"

        if let rpc = store.rpc {
            var request = Dieter_V1_CreateBoardRequest()
            request.projectID = project.id
            request.name = "Offline navigation smoke \(UUID().uuidString.lowercased())"
            request.workflow = "review"
            request.doneArchivePolicy = "never"
            do {
                let cachedBoard = try await rpc.createBoard(request)
                await store.refreshState()
                try? await DieterTaskSleep.seconds(1)
                await store.openBoard(board.id, projectID: project.id)
                store.errorMessage = nil
                store.disconnect()
                await store.openBoard(cachedBoard.id, projectID: project.id)
                try? await DieterTaskSleep.milliseconds(700)
                let stayedUsable = store.section == .board &&
                    store.selectedBoard?.id == cachedBoard.id &&
                    store.errorMessage == nil &&
                    store.hasLoadedWorkspace
                results["17-offline-cached-board-navigation"] = stayedUsable
                    ? "passed"
                    : "failed: section=\(store.section.rawValue), board=\(store.selectedBoard?.id ?? "none"), error=\(store.errorMessage ?? "none")"
                await captureAppearances(window, named: "17-offline-cached-board-navigation.png", in: output)
            } catch {
                results["17-offline-cached-board-navigation"] = "failed: could not prepare cached board: \(error.localizedDescription)"
            }
        } else {
            results["17-offline-cached-board-navigation"] = "failed: RPC client missing"
        }

        writeReport(results, to: output)
    }

    private static func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await DieterTaskSleep.milliseconds(200)
        }
        return condition()
    }

    private static func outputDirectory() -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-smoke-output"), arguments.indices.contains(index + 1) {
            return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        }
        return URL(filePath: NSTemporaryDirectory()).appending(path: "dieter-mac-ui-smoke", directoryHint: .isDirectory)
    }

    private static func click(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat) {
        guard let content = window.contentView else { return }
        let location = NSPoint(x: x, y: content.bounds.height - distanceFromTop)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let types: [NSEvent.EventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp]
        for type in types {
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
            if let event { window.sendEvent(event) }
        }
    }

    private static func doubleClickTitleBar(of window: NSWindow) {
        let point = NSPoint(
            x: window.contentLayoutRect.midX,
            y: window.contentLayoutRect.maxY + ((window.frame.height - window.contentLayoutRect.maxY) / 2)
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        for clickCount in [1, 2] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: timestamp + (Double(clickCount - 1) * 0.08),
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: clickCount,
                    clickCount: clickCount,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
                if let event { NSApp.sendEvent(event) }
            }
        }
    }

    private static func captureAppearances(_ window: NSWindow, named name: String, in output: URL) async {
        let defaults = DieterAppearance.applicationDefaults()
        let original = defaults.string(forKey: DieterAppearance.storageKey)
        for appearance in [DieterAppearance.dark, DieterAppearance.light] {
            defaults.set(appearance.rawValue, forKey: DieterAppearance.storageKey)
            try? await DieterTaskSleep.milliseconds(450)
            let directory = output.appending(path: "appearance-\(appearance.rawValue)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(window, to: directory.appending(path: name))
        }
        if let original {
            defaults.set(original, forKey: DieterAppearance.storageKey)
        } else {
            defaults.removeObject(forKey: DieterAppearance.storageKey)
        }
        try? await DieterTaskSleep.milliseconds(450)
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
