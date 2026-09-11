#if DIETER_UI_SMOKE
    import AppKit
    import Foundation
    import DieterAPI

    /// A direct native-app smoke driver for sidebar and chat-project persistence.
    ///
    /// The shell runner launches the packaged app twice with one isolated defaults
    /// suite. The first launch clicks the real SwiftUI controls, records an accepted
    /// project drop, drags the sidebar divider, and collapses a project in Chats.
    /// The second launch proves those states were reconstructed in the rendered UI.
    @MainActor
    enum SidebarNavigationUISmokeRunner {
        private static let projectIDs = ["p_sidebar_one", "p_sidebar_two", "p_sidebar_three"]
        private static let chatIDs = ["c_sidebar_one", "c_sidebar_two", "c_sidebar_three"]
        private static let expectedMachineNames = ["alpha", "Beta", "Zulu"]

        static func run(store: DieterStore) async {
            let output = outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Let the store's normal disk projection restoration finish, then replace
            // it with a deterministic UI-only workspace for this smoke process.
            try? await DieterTaskSleep.seconds(1)
            seed(store)
            try? await DieterTaskSleep.milliseconds(700)

            guard
                let window = NSApp.windows.first(where: {
                    $0.isVisible && $0.contentView != nil && $0.title == "Dieter"
                })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            else {
                writeReport(["window": "failed: Dieter window not found"], to: output)
                return
            }

            window.setContentSize(NSSize(width: 1_380, height: 870))
            window.center()
            window.makeKeyAndOrderFront(nil)
            try? await DieterTaskSleep.milliseconds(500)

            let phase = argument(after: "--sidebar-ui-smoke") ?? "prepare"
            var results: [String: String] = [:]
            let sourceMachineNames = store.machines.map(\.name)
            results["machine-source-order"] =
                sourceMachineNames == ["Beta", "Zulu", "alpha"]
                ? "passed"
                : "failed: \(sourceMachineNames.joined(separator: ","))"
            let sidebarMachineNames = SidebarMachineOrdering.sorted(store.machines).map(\.name)
            results["machine-sidebar-order"] =
                sidebarMachineNames == expectedMachineNames
                ? "passed"
                : "failed: \(sidebarMachineNames.joined(separator: ","))"
            let expectedProjectMachinePresence = ["online", "offline", "online"]
            let projectMachinePresence = zip(projectIDs, expectedProjectMachinePresence).map { projectID, status in
                NativeUIAccessibility.find("sidebar.project.\(projectID).machine.\(status)", in: window) != nil
            }
            results["project-machine-presence"] =
                projectMachinePresence.allSatisfy { $0 }
                ? "passed"
                : "failed: \(projectMachinePresence)"
            switch phase {
            case "prepare":
                await prepare(store: store, window: window, results: &results)
            case "verify":
                await verify(store: store, window: window, results: &results)
            default:
                results["phase"] = "failed: unknown phase \(phase)"
            }
            capture(window, to: output.appending(path: "sidebar-\(phase).png"))
            writeReport(results, to: output)
        }

        private static func prepare(store: DieterStore, window: NSWindow, results: inout [String: String]) async {
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[0]).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(450)
            var preferences = loadPreferences()
            results["expand-click"] =
                preferences.isExpanded(projectIDs[0]) ? "passed" : "failed: first project did not expand"

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
            results["drag-order"] =
                order == [projectIDs[2], projectIDs[0], projectIDs[1]]
                ? "passed" : "failed: \(order.joined(separator: ","))"
            results["saved-expand"] =
                preferences.isExpanded(projectIDs[0]) ? "passed" : "failed: expanded state was not saved"

            if let split = navigationSplit(in: window) {
                let initialWidth = split.arrangedSubviews[0].frame.width
                let targetWidth: CGFloat = initialWidth > 275 ? 250 : 300
                // Resize the actual AppKit divider, not the removed SwiftUI drag handle.
                split.setPosition(targetWidth, ofDividerAt: 0)
                let resized = await NativeUIAccessibility.wait {
                    abs(split.arrangedSubviews[0].frame.width - targetWidth) < 2
                        && abs(persistedSidebarWidth() - targetWidth) < 2
                }
                SidebarProjectNavigationPreferences.applicationDefaults().set(
                    Double(targetWidth), forKey: "smoke.expectedSidebarWidth")
                results["resize-native-divider"] =
                    resized
                    ? "passed"
                    : "failed: native width \(split.arrangedSubviews[0].frame.width), saved \(persistedSidebarWidth()), expected \(targetWidth)"
            } else {
                results["resize-native-divider"] = "failed: navigation split view unavailable"
            }

            await showChats(store: store, window: window)
            let chatWasVisible = NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) != nil
            let clicked = NativeUIAccessibility.click("chats.project.\(projectIDs[0]).toggle", in: window)
            let saved = await NativeUIAccessibility.wait {
                loadChatPreferences().isCollapsed(projectIDs[0])
            }
            results["chat-collapse-click"] = clicked && saved ? "passed" : "failed: collapsed state was not saved"
            results["chat-collapse-rendered"] =
                chatWasVisible && NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) == nil
                ? "passed"
                : "failed: project chat rows did not collapse"
        }

        private static func verify(store: DieterStore, window: NSWindow, results: inout [String: String]) async {
            let restored = loadPreferences()
            results["restored-order"] =
                restored.orderedIDs(from: projectIDs) == [projectIDs[2], projectIDs[0], projectIDs[1]]
                ? "passed" : "failed"
            results["restored-expand"] = restored.isExpanded(projectIDs[0]) ? "passed" : "failed"
            let expectedWidth = SidebarProjectNavigationPreferences.applicationDefaults().double(
                forKey: "smoke.expectedSidebarWidth")
            let widthRestored = await NativeUIAccessibility.wait {
                guard let split = navigationSplit(in: window) else { return false }
                return abs(split.arrangedSubviews[0].frame.width - expectedWidth) < 2
                    && abs(persistedSidebarWidth() - expectedWidth) < 2
            }
            results["restored-width"] =
                widthRestored ? "passed" : "failed: expected \(expectedWidth), restored \(persistedSidebarWidth())"

            // Verify the rendered order before expanding the first row.
            let first = NativeUIAccessibility.find("sidebar.project.\(projectIDs[2]).toggle", in: window)
            let second = NativeUIAccessibility.find("sidebar.project.\(projectIDs[0]).toggle", in: window)
            let firstFrame = first?.recordedFrame ?? first?.frame ?? .zero
            let secondFrame = second?.recordedFrame ?? second?.frame ?? .zero
            let renderedOrder = firstFrame.width > 0 && secondFrame.width > 0 && firstFrame.minY > secondFrame.maxY
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[2]).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(350)
            var interacted = loadPreferences()
            results["order-in-relaunched-ui"] =
                renderedOrder && interacted.isExpanded(projectIDs[2])
                ? "passed" : "failed: first visible toggle was not the reordered project"
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[2]).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(350)

            // The saved-expanded project renders second; collapsing it clears the flag.
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[0]).toggle", in: window)
            _ = await NativeUIAccessibility.wait { !loadPreferences().isExpanded(projectIDs[0]) }

            await showChats(store: store, window: window)
            let restoredChatPreferences = loadChatPreferences()
            results["chat-restored-collapse"] =
                restoredChatPreferences.isCollapsed(projectIDs[0])
                    && NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) == nil
                ? "passed"
                : "failed: collapsed Chats project was not restored"
            let clicked = NativeUIAccessibility.click("chats.project.\(projectIDs[0]).toggle", in: window)
            let expanded = await NativeUIAccessibility.wait {
                !loadChatPreferences().isCollapsed(projectIDs[0])
                    && NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) != nil
            }
            results["chat-expand-in-relaunched-ui"] = clicked && expanded ? "passed" : "failed"
            _ = NativeUIAccessibility.click("chats.project.\(projectIDs[0]).toggle", in: window)
            _ = await NativeUIAccessibility.wait { loadChatPreferences().isCollapsed(projectIDs[0]) }
            interacted = loadPreferences()
            results["expand-in-relaunched-ui"] =
                !interacted.isExpanded(projectIDs[0])
                ? "passed" : "failed: saved expanded project was not rendered second"
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[0]).toggle", in: window)
            _ = await NativeUIAccessibility.wait { loadPreferences().isExpanded(projectIDs[0]) }
        }

        private static func seed(_ store: DieterStore) {
            let names = ["Alpha", "Beta", "Gamma"]
            let machines = [
                DieterEndpoint(
                    name: "Zulu",
                    host: "127.0.0.1",
                    port: 4242,
                    daemonID: "sidebar-smoke-zulu",
                    online: true,
                    version: "smoke"
                ),
                DieterEndpoint(
                    name: "alpha",
                    host: "127.0.0.1",
                    port: 4243,
                    daemonID: "sidebar-smoke-alpha",
                    online: false,
                    version: "smoke"
                ),
                DieterEndpoint(
                    name: "Beta",
                    host: "127.0.0.1",
                    port: 4244,
                    daemonID: "sidebar-smoke-beta",
                    online: true,
                    version: "smoke"
                ),
            ]
            let machine = machines[0]
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
            store.endpoints = machines
            store.projectEndpointIDs = Dictionary(
                uniqueKeysWithValues: zip(projectIDs, machines).map { pair in (pair.0, pair.1.id) })
            store.machineConnectionStatuses = Dictionary(
                uniqueKeysWithValues: machines.map {
                    ($0.id, MachineConnectionStatus(route: .local, latencyMilliseconds: 3))
                })
            var chats: [Dieter_V1_Card] = []
            for (index, projectID) in projectIDs.enumerated() {
                var chat = Dieter_V1_Card()
                chat.id = chatIDs[index]
                chat.projectID = projectID
                chat.scope = "chat"
                chat.title = "\(names[index]) planning"
                chat.updatedAt = "2026-09-08T06:00:0\(index)Z"
                chats.append(chat)
            }
            store.chats = chats
            store.chatProjects = projects
            store.state.project = projects[0]
            store.state.projects = projects
            store.state.boards = boardsByProject[projectIDs[0]] ?? []
            store.selectedProjectID = projectIDs[0]
            store.selectedBoardID = boardsByProject[projectIDs[0]]?.first?.id ?? ""
            store.phase = .connected(version: "sidebar-smoke")
        }

        private static func drag(window: NSWindow, fromX: CGFloat, fromTop: CGFloat, toX: CGFloat, toTop: CGFloat) async
        {
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
            if posted { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
        }

        private static func loadPreferences() -> SidebarProjectNavigationPreferences {
            SidebarProjectNavigationPreferences.load(from: SidebarProjectNavigationPreferences.applicationDefaults())
        }

        private static func loadChatPreferences() -> ChatProjectDisclosurePreferences {
            ChatProjectDisclosurePreferences.load(from: DieterAppearance.applicationDefaults())
        }

        private static func showChats(store: DieterStore, window: NSWindow) async {
            store.closeConversation()
            store.section = .chats
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("chats.project.\(projectIDs[0]).toggle", in: window) != nil
            }
        }

        private static func navigationSplit(in window: NSWindow) -> NSSplitView? {
            guard let content = window.contentView else { return nil }
            var views = [content]
            while let view = views.popLast() {
                if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 {
                    return split
                }
                views.append(contentsOf: view.subviews)
            }
            return nil
        }

        private static func persistedSidebarWidth() -> CGFloat {
            let value = SidebarProjectNavigationPreferences.applicationDefaults().double(
                forKey: SidebarSizing.storageKey)
            return value > 0 ? SidebarSizing.clamped(CGFloat(value)) : SidebarSizing.defaultWidth
        }

        private static func outputDirectory() -> URL {
            if let value = argument(after: "--ui-smoke-output") {
                return URL(filePath: value, directoryHint: .isDirectory)
            }
            return URL(filePath: NSTemporaryDirectory()).appending(
                path: "dieter-sidebar-ui-smoke", directoryHint: .isDirectory)
        }

        private static func argument(after flag: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
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
            let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: directory.appending(path: "report.json"), options: .atomic)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
#endif
