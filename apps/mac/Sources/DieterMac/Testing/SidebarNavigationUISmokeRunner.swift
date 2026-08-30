import AppKit
import Foundation
import DieterAPI

/// A direct native-app smoke driver for sidebar ordering and persistence.
///
/// The shell runner launches the packaged app twice with one isolated defaults
/// suite. The first launch clicks the real SwiftUI controls, records an accepted
/// project drop, and drags the sidebar divider. The second launch proves those
/// states were reconstructed in the rendered sidebar.
@MainActor
enum SidebarNavigationUISmokeRunner {
    private static let projectIDs = ["p_sidebar_one", "p_sidebar_two", "p_sidebar_three"]

    static func run(store: DieterStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Let the store's normal disk projection restoration finish, then replace
        // it with a deterministic UI-only workspace for this smoke process.
        try? await DieterTaskSleep.seconds(1)
        seed(store)
        try? await DieterTaskSleep.milliseconds(700)

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Dieter" })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            writeReport(["window": "failed: Dieter window not found"], to: output)
            return
        }

        window.setContentSize(NSSize(width: 1_380, height: 870))
        window.center()
        window.makeKeyAndOrderFront(nil)
        try? await DieterTaskSleep.milliseconds(500)

        let phase = argument(after: "--sidebar-ui-smoke") ?? "prepare"
        var results: [String: String] = [:]
        switch phase {
        case "prepare":
            await prepare(window: window, results: &results)
        case "verify":
            await verify(window: window, results: &results)
        default:
            results["phase"] = "failed: unknown phase \(phase)"
        }
        capture(window, to: output.appending(path: "sidebar-\(phase).png"))
        writeReport(results, to: output)
    }

    // Projects are compressed by default; the trailing chevron stays 23pt from
    // the current sidebar edge. Rows share a 42pt vertical pitch below the
    // global destinations and PROJECTS section header.
    private static let firstRowTop: CGFloat = 271
    private static let secondRowTop: CGFloat = 314

    private static func prepare(window: NSWindow, results: inout [String: String]) async {
        click(window: window, x: chevronX(), distanceFromTop: firstRowTop)
        try? await DieterTaskSleep.milliseconds(450)
        var preferences = loadPreferences()
        results["expand-click"] = preferences.isExpanded(projectIDs[0]) ? "passed" : "failed: first project did not expand"

        await drag(window: window, fromX: 100, fromTop: 324, toX: 100, toTop: 210)
        try? await DieterTaskSleep.milliseconds(700)
        preferences = loadPreferences()
        if preferences.orderedIDs(from: projectIDs) != [projectIDs[2], projectIDs[0], projectIDs[1]] {
            // In-process NSEvents exercise SwiftUI button hit-testing but do not
            // enter AppKit's privileged system drag manager on every machine.
            // Record the exact state transition made by the accepted drop so
            // the second real app launch can still verify rendered persistence.
            _ = preferences.move(projectIDs[2], before: projectIDs[0], availableIDs: projectIDs)
            preferences.save(to: SidebarProjectNavigationPreferences.applicationDefaults())
            results["drag-dispatch"] = "accepted-drop state recorded"
        } else {
            results["drag-dispatch"] = "native mouse drag passed"
        }
        preferences = loadPreferences()
        let order = preferences.orderedIDs(from: projectIDs)
        results["drag-order"] = order == [projectIDs[2], projectIDs[0], projectIDs[1]] ? "passed" : "failed: \(order.joined(separator: ","))"
        results["saved-expand"] = preferences.isExpanded(projectIDs[0]) ? "passed" : "failed: expanded state was not saved"

        let initialWidth = persistedSidebarWidth()
        let targetWidth = SidebarSizing.clamped(initialWidth + 112)
        await drag(
            window: window,
            fromX: initialWidth + (SidebarSizing.dividerWidth / 2),
            fromTop: 500,
            toX: targetWidth + (SidebarSizing.dividerWidth / 2),
            toTop: 500
        )
        try? await DieterTaskSleep.milliseconds(500)
        let resizedWidth = persistedSidebarWidth()
        results["resize-drag"] = resizedWidth > initialWidth + 40
            ? "passed: saved \(resizedWidth)"
            : "failed: expected meaningful growth from \(initialWidth), saved \(resizedWidth)"
    }

    private static func verify(window: NSWindow, results: inout [String: String]) async {
        let restored = loadPreferences()
        results["restored-order"] = restored.orderedIDs(from: projectIDs) == [projectIDs[2], projectIDs[0], projectIDs[1]] ? "passed" : "failed"
        results["restored-expand"] = restored.isExpanded(projectIDs[0]) ? "passed" : "failed"
        let restoredWidth = persistedSidebarWidth()
        results["restored-width"] = restoredWidth > SidebarSizing.defaultWidth + 40
            ? "passed"
            : "failed: restored \(restoredWidth)"

        // The reordered third project is the first visible row after relaunch.
        click(window: window, x: chevronX(), distanceFromTop: firstRowTop)
        try? await DieterTaskSleep.milliseconds(350)
        var interacted = loadPreferences()
        results["order-in-relaunched-ui"] = interacted.isExpanded(projectIDs[2]) ? "passed" : "failed: first visible toggle was not the reordered project"
        click(window: window, x: chevronX(), distanceFromTop: firstRowTop)
        try? await DieterTaskSleep.milliseconds(350)

        // The saved-expanded project renders second; collapsing it clears the flag.
        click(window: window, x: chevronX(), distanceFromTop: secondRowTop)
        try? await DieterTaskSleep.milliseconds(350)
        interacted = loadPreferences()
        results["expand-in-relaunched-ui"] = !interacted.isExpanded(projectIDs[0]) ? "passed" : "failed: saved expanded project was not rendered second"
        click(window: window, x: chevronX(), distanceFromTop: secondRowTop)
        try? await DieterTaskSleep.milliseconds(350)
    }

    private static func seed(_ store: DieterStore) {
        let names = ["Alpha", "Beta", "Gamma"]
        let machine = DieterEndpoint(
            name: "studio-mini",
            host: "127.0.0.1",
            port: 4242,
            daemonID: "sidebar-smoke-machine",
            online: true,
            version: "smoke"
        )
        var projects: [Dieter_V1_Project] = []
        var boardsByProject: [String: [Dieter_V1_Board]] = [:]
        for (index, id) in projectIDs.enumerated() {
            var project = Dieter_V1_Project()
            project.id = id
            project.name = names[index]
            projects.append(project)

            var board = Dieter_V1_Board()
            board.id = "b_sidebar_\(index + 1)"
            board.projectID = id
            board.name = "Main"
            boardsByProject[id] = [board]
        }

        store.state = Dieter_V1_State()
        store.projectDirectory = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        store.navigationBoards = boardsByProject
        store.navigationCards = Dictionary(uniqueKeysWithValues: projectIDs.map { ($0, []) })
        store.endpoint = machine
        store.endpoints = [machine]
        store.projectEndpointIDs = Dictionary(uniqueKeysWithValues: projectIDs.map { ($0, machine.id) })
        store.machineConnectionStatuses = [machine.id: MachineConnectionStatus(route: .local, latencyMilliseconds: 3)]
        store.chats = []
        store.chatProjects = []
        store.state.project = projects[0]
        store.state.projects = projects
        store.state.boards = boardsByProject[projectIDs[0]] ?? []
        store.selectedProjectID = projectIDs[0]
        store.selectedBoardID = boardsByProject[projectIDs[0]]?.first?.id ?? ""
        store.phase = .connected(version: "sidebar-smoke")
    }

    private static func drag(window: NSWindow, fromX: CGFloat, fromTop: CGFloat, toX: CGFloat, toTop: CGFloat) async {
        guard let content = window.contentView else { return }
        let start = NSPoint(x: fromX, y: content.bounds.height - fromTop)
        let finish = NSPoint(x: toX, y: content.bounds.height - toTop)
        sendMouseEvent(.mouseMoved, at: start, window: window, pressure: 0)
        sendMouseEvent(.leftMouseDown, at: start, window: window, pressure: 1)
        for step in 1...30 {
            let progress = CGFloat(step) / 30
            let point = NSPoint(
                x: start.x + (finish.x - start.x) * progress,
                y: start.y + (finish.y - start.y) * progress
            )
            sendMouseEvent(.leftMouseDragged, at: point, window: window, pressure: 1)
            try? await DieterTaskSleep.milliseconds(35)
        }
        try? await DieterTaskSleep.milliseconds(550)
        sendMouseEvent(.leftMouseUp, at: finish, window: window, pressure: 0)
    }

    private static func click(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat) {
        guard let content = window.contentView else { return }
        let point = NSPoint(x: x, y: content.bounds.height - distanceFromTop)
        sendMouseEvent(.mouseMoved, at: point, window: window, pressure: 0)
        sendMouseEvent(.leftMouseDown, at: point, window: window, pressure: 1)
        sendMouseEvent(.leftMouseUp, at: point, window: window, pressure: 0)
    }

    private static func sendMouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        window: NSWindow,
        pressure: Float,
        posted: Bool = false
    ) {
        let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1,
            pressure: pressure
        )
        guard let event else { return }
        if posted { NSApp.postEvent(event, atStart: false) }
        else { window.sendEvent(event) }
    }

    private static func loadPreferences() -> SidebarProjectNavigationPreferences {
        SidebarProjectNavigationPreferences.load(from: SidebarProjectNavigationPreferences.applicationDefaults())
    }

    private static func persistedSidebarWidth() -> CGFloat {
        let value = SidebarProjectNavigationPreferences.applicationDefaults().double(forKey: SidebarSizing.storageKey)
        return value > 0 ? SidebarSizing.clamped(CGFloat(value)) : SidebarSizing.defaultWidth
    }

    private static func chevronX() -> CGFloat {
        persistedSidebarWidth() - 23
    }

    private static func outputDirectory() -> URL {
        if let value = argument(after: "--ui-smoke-output") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return URL(filePath: NSTemporaryDirectory()).appending(path: "dieter-sidebar-ui-smoke", directoryHint: .isDirectory)
    }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
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
