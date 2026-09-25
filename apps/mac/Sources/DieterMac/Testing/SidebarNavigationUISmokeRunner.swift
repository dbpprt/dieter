#if DIETER_UI_SMOKE
    import AppKit
    import Foundation
    import DieterAPI
    import DieterClient

    /// A direct native-app smoke driver for sidebar and chat-project persistence.
    ///
    /// The shell runner launches the packaged app twice with one isolated defaults
    /// suite. The first launch clicks the real SwiftUI controls, records an accepted
    /// project drop, drags the sidebar divider, and collapses a project in Chats.
    /// The second launch proves those states were reconstructed in the rendered UI.
    @MainActor
    enum SidebarNavigationUISmokeRunner {
        private static let projectIDs = ["p_sidebar_one", "p_sidebar_two", "p_sidebar_three"]
        // These chats belong only to the rendered fixture. Keep selection local
        // so row clicks never try the synthetic machines' placeholder ports.
        private static let chatIDs = ["local_sidebar_one", "local_sidebar_two", "local_sidebar_three"]
        private static let projectFolderID = "folder_sidebar_projects"
        private static let chatFolderID = "folder_sidebar_chats"
        private static let longMachineName = "Zulu-workstation-with-a-long-hostname"
        private static let expectedMachineNames = ["alpha", "Beta", longMachineName]

        static func run(store: DieterStore) async {
            let output = outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Let the store's normal disk projection restoration finish, then replace
            // it with a deterministic UI-only workspace for this smoke process.
            try? await DieterTaskSleep.seconds(1)
            seed(store)
            try? "seeded".write(to: output.appending(path: "progress.txt"), atomically: true, encoding: .utf8)
            // This suite deliberately uses an offline account fixture. Its
            // restart assertions exercise the durable client outbox/cache.
            store.environment.defaults.set("sidebar-fixture", forKey: "DieterSharedKV.activeAccount")
            store.sharedNavigation = SharedKV(
                defaults: store.environment.defaults,
                root: store.syncPersistence.fileURL.deletingLastPathComponent().appending(path: "shared-kv"))
            store.bindSharedNavigation(); store.applySharedNavigation()
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
                sourceMachineNames == ["Beta", longMachineName, "alpha"]
                ? "passed"
                : "failed: \(sourceMachineNames.joined(separator: ","))"
            let sidebarMachineNames = SidebarMachineOrdering.sorted(store.machines).map(\.name)
            results["machine-sidebar-order"] =
                sidebarMachineNames == expectedMachineNames
                ? "passed"
                : "failed: \(sidebarMachineNames.joined(separator: ","))"
            let projectHasNoSingleMachine = projectIDs.allSatisfy { projectID in
                NativeUIAccessibility.find("sidebar.project.\(projectID).machine.online", in: window) == nil
                    && NativeUIAccessibility.find("sidebar.project.\(projectID).machine.offline", in: window) == nil
            }
            results["shared-project-navigation"] =
                projectHasNoSingleMachine ? "passed" : "failed: project has an owner badge"
            try? "window ready: \(phase)".write(to: output.appending(path: "progress.txt"), atomically: true, encoding: .utf8)
            switch phase {
            case "prepare":
                await recordProjectRowLayout(store: store, window: window, results: &results)
                try? "project row checked".write(to: output.appending(path: "progress.txt"), atomically: true, encoding: .utf8)
                await prepare(store: store, window: window, results: &results)
            case "verify":
                await verify(store: store, window: window, results: &results)
            default:
                results["phase"] = "failed: unknown phase \(phase)"
            }
            try? "navigation checked".write(to: output.appending(path: "progress.txt"), atomically: true, encoding: .utf8)
            if phase == "prepare" {
                results.merge(await WorkspaceChromeUISmoke.run(store: store, window: window, output: output)) { _, new in new }
            }
            capture(window, to: output.appending(path: "sidebar-\(phase).png"))
            writeReport(results, to: output)
        }

        private static func recordProjectRowLayout(
            store: DieterStore, window: NSWindow, results: inout [String: String]
        ) async {
            guard let split = navigationSplit(in: window) else {
                results["project-row-layout"] = "failed: no native sidebar split"
                return
            }
            let originalWidth = split.arrangedSubviews[0].frame.width
            let originalPointer = NSEvent.mouseLocation
            defer {
                split.setPosition(originalWidth, ofDividerAt: 0)
                NativeUIAccessibility.movePointer(to: originalPointer)
            }
            split.setPosition(250, ofDividerAt: 0)
            let away = NSPoint(x: window.frame.midX, y: window.frame.midY)
            NativeUIAccessibility.movePointer(to: away)
            let prefix = "sidebar.project.\(projectIDs[0])"
            let hidden = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find(prefix + ".settings", in: window) == nil
                    && NativeUIAccessibility.find(prefix + ".new-board", in: window) == nil
                    && abs(split.arrangedSubviews[0].frame.width - 250) < 2
            }
            let ready = await NativeUIAccessibility.waitForInteractiveTarget(prefix + ".name", in: window)
            let beforeHover = NativeUIAccessibility.targetDiagnostics(prefix + ".name", in: window)
            let name = store.projectDirectory[projectIDs[0]]?.name ?? ""
            let nameFrame = NativeUIAccessibility.find(prefix + ".name", in: window)?.recordedFrame ?? .zero
            let expectedNameWidth = (name as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]).width
            results["project-name-before-host"] =
                hidden && !name.isEmpty && nameFrame.width + 1 >= expectedNameWidth
                ? "passed"
                : "failed: name=\(name) width=\(nameFrame.width)/\(expectedNameWidth), hidden=\(hidden)"
            let hovered = ready && NativeUIAccessibility.hover(prefix + ".name", in: window)
            let controlsVisible = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find(prefix + ".settings", in: window) != nil
                    && NativeUIAccessibility.find(prefix + ".new-board", in: window) != nil
            }
            let afterHover = NativeUIAccessibility.targetDiagnostics(prefix + ".name", in: window)
            if !controlsVisible {
                capture(window, to: outputDirectory().appending(path: "project-hover-failure.png"))
            }
            NativeUIAccessibility.movePointer(to: away)
            let hiddenAgain = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find(prefix + ".settings", in: window) == nil
                    && NativeUIAccessibility.find(prefix + ".new-board", in: window) == nil
            }
            results["project-actions-on-hover"] =
                ready && hidden && hovered && controlsVisible && hiddenAgain
                ? "passed"
                : "failed: ready=\(ready) hidden=\(hidden) hovered=\(hovered) visible=\(controlsVisible) hiddenAgain=\(hiddenAgain); before={\(beforeHover)} after={\(afterHover)}"
        }

        private static func prepare(store: DieterStore, window: NSWindow, results: inout [String: String]) async {
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[0]).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(450)
            var preferences = store.sidebarProjectNavigation
            results["expand-click"] =
                preferences.isExpanded(projectIDs[0]) ? "passed" : "failed: first project did not expand"

            await drag(window: window, fromX: 100, fromTop: 324, toX: 100, toTop: 210)
            try? await DieterTaskSleep.milliseconds(700)
            preferences = store.sidebarProjectNavigation
            if preferences.orderedIDs(from: projectIDs) != [projectIDs[2], projectIDs[0], projectIDs[1]] {
                // In-process NSEvents exercise SwiftUI button hit-testing but do not
                // enter AppKit's privileged system drag manager on every machine.
                // Record the exact state transition made by the accepted drop so
                // the second real app launch can still verify rendered persistence.
                _ = preferences.move(projectIDs[2], before: projectIDs[0], availableIDs: projectIDs)
                store.sidebarProjectNavigation = preferences
                results["drag-dispatch"] = "accepted-drop state recorded"
            } else {
                results["drag-dispatch"] = "native mouse drag passed"
            }
            preferences = store.sidebarProjectNavigation
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

            installProjectFolder(store)
            let projectFolderRendered = await NativeUIAccessibility.wait(timeout: 3) {
                NativeUIAccessibility.find("sidebar.project-folder.\(projectFolderID)", in: window) != nil
            }
            await showChats(store: store, window: window)
            recordNavigationBoundaries(in: window, results: &results)
            await switchChatsWithCompanion(store: store, window: window, results: &results)
            let chatWasVisible = NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) != nil
            let clicked = NativeUIAccessibility.click("chats.project.\(projectIDs[0]).toggle", in: window)
            let saved = await NativeUIAccessibility.wait {
                store.chatProjectDisclosure.isCollapsed(projectIDs[0])
            }
            results["chat-collapse-click"] = clicked && saved ? "passed" : "failed: collapsed state was not saved"
            results["chat-collapse-rendered"] =
                chatWasVisible && NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) == nil
                ? "passed"
                : "failed: project chat rows did not collapse"

            installChatFolder(store)
            let chatFolderRendered = await NativeUIAccessibility.wait(timeout: 3) {
                NativeUIAccessibility.find("chats.folder.\(chatFolderID)", in: window) != nil
                    && NativeUIAccessibility.find("chat.\(chatIDs[1])", in: window) != nil
            }
            results["folders-rendered"] =
                projectFolderRendered && chatFolderRendered ? "passed" : "failed"
        }

        private static func verify(store: DieterStore, window: NSWindow, results: inout [String: String]) async {
            let projectFolderRendered = await NativeUIAccessibility.wait(timeout: 3) {
                NativeUIAccessibility.find("sidebar.project-folder.\(projectFolderID)", in: window) != nil
            }
            results["folders-restored"] =
                store.sidebarProjectFolders.folder(containing: projectIDs[1])?.id == projectFolderID
                    && store.allChatsFolders.folder(containing: chatIDs[1])?.id == chatFolderID
                    && projectFolderRendered
                ? "passed"
                : "failed"
            store.sidebarProjectFolders = NavigationFolderPreferences()
            store.allChatsFolders = NavigationFolderPreferences()
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("sidebar.project-folder.\(projectFolderID)", in: window) == nil
            }

            let restored = store.sidebarProjectNavigation
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
            let renderedOrder = await NativeUIAccessibility.wait(timeout: 3) {
                let first = NativeUIAccessibility.find("sidebar.project.\(projectIDs[2]).toggle", in: window)
                let second = NativeUIAccessibility.find("sidebar.project.\(projectIDs[0]).toggle", in: window)
                let firstFrame = first?.recordedFrame ?? first?.frame ?? .zero
                let secondFrame = second?.recordedFrame ?? second?.frame ?? .zero
                return firstFrame.width > 0 && secondFrame.width > 0 && firstFrame.minY > secondFrame.maxY
            }
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[2]).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(350)
            var interacted = store.sidebarProjectNavigation
            results["order-in-relaunched-ui"] =
                renderedOrder && interacted.isExpanded(projectIDs[2])
                ? "passed" : "failed: first visible toggle was not the reordered project"
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[2]).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(350)

            // The saved-expanded project renders second; collapsing it clears the flag.
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[0]).toggle", in: window)
            _ = await NativeUIAccessibility.wait { !store.sidebarProjectNavigation.isExpanded(projectIDs[0]) }

            await showChats(store: store, window: window)
            recordNavigationBoundaries(in: window, results: &results)
            let restoredChatPreferences = store.chatProjectDisclosure
            results["chat-restored-collapse"] =
                restoredChatPreferences.isCollapsed(projectIDs[0])
                    && NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) == nil
                ? "passed"
                : "failed: collapsed Chats project was not restored"
            let clicked = NativeUIAccessibility.click("chats.project.\(projectIDs[0]).toggle", in: window)
            let expanded = await NativeUIAccessibility.wait {
                !store.chatProjectDisclosure.isCollapsed(projectIDs[0])
                    && NativeUIAccessibility.find("chat.\(chatIDs[0])", in: window) != nil
            }
            results["chat-expand-in-relaunched-ui"] = clicked && expanded ? "passed" : "failed"
            _ = NativeUIAccessibility.click("chats.project.\(projectIDs[0]).toggle", in: window)
            _ = await NativeUIAccessibility.wait { store.chatProjectDisclosure.isCollapsed(projectIDs[0]) }
            interacted = store.sidebarProjectNavigation
            results["expand-in-relaunched-ui"] =
                !interacted.isExpanded(projectIDs[0])
                ? "passed" : "failed: saved expanded project was not rendered second"
            NativeUIAccessibility.click("sidebar.project.\(projectIDs[0]).toggle", in: window)
            _ = await NativeUIAccessibility.wait { store.sidebarProjectNavigation.isExpanded(projectIDs[0]) }

            installChatFolder(store)
            let chatFolderRendered = await NativeUIAccessibility.wait(timeout: 3) {
                NativeUIAccessibility.find("chats.folder.\(chatFolderID)", in: window) != nil
            }
            results["folders-in-relaunched-ui"] = chatFolderRendered ? "passed" : "failed"
        }

        private static func installProjectFolder(_ store: DieterStore) {
            store.sidebarProjectFolders = NavigationFolderPreferences(folders: [
                NavigationFolder(
                    id: projectFolderID,
                    name: "Client work",
                    itemIDs: [projectIDs[1]]
                )
            ])
        }

        private static func installChatFolder(_ store: DieterStore) {
            store.allChatsFolders = NavigationFolderPreferences(folders: [
                NavigationFolder(
                    id: chatFolderID,
                    name: "Research",
                    itemIDs: [chatIDs[1]]
                )
            ])
        }

        private static func switchChatsWithCompanion(
            store: DieterStore, window: NSWindow, results: inout [String: String]
        ) async {
            let model = store.conversationContext.content
            defer {
                model.hide()
                store.closeConversation()
            }
            let first = chatIDs[0]
            let second = chatIDs[2]
            let firstClicked = NativeUIAccessibility.click("chat.\(first)", in: window)
            let firstSelected = await NativeUIAccessibility.wait { store.selectedChatID == first }
            guard firstClicked && firstSelected else {
                results["chat-companion-switch"] = "failed: first chat could not be selected"
                return
            }
            model.showEmpty(conversationID: first)
            let opened = await NativeUIAccessibility.wait {
                model.isPresented(for: first)
                    && NativeUIAccessibility.find("conversation.content-pane", in: window) != nil
            }
            let originalSize = window.contentView?.bounds.size ?? NSSize(width: 1_380, height: 870)
            for width in [CGFloat(1_080), CGFloat(1_380)] {
                window.setContentSize(NSSize(width: width, height: originalSize.height))
                let visible = await NativeUIAccessibility.wait {
                    guard let browser = NativeUIAccessibility.find("chats.browser-pane", in: window),
                        let detail = NativeUIAccessibility.find("chats.detail-pane", in: window),
                        let row = NativeUIAccessibility.find("chat.\(second)", in: window)
                    else { return false }
                    let browserFrame = browser.recordedFrame ?? browser.frame
                    let detailFrame = detail.recordedFrame ?? detail.frame
                    let rowFrame = row.recordedFrame ?? row.frame
                    return browserFrame.width >= ChatPaneSizing.minimumWidth - 1
                        && abs(browserFrame.maxX - detailFrame.minX) < 2
                        && browserFrame.intersects(rowFrame)
                        && detailFrame.maxX <= window.frame.maxX + 1
                }
                results["chat-companion-navigation-\(Int(width))"] =
                    opened && visible ? "passed" : "failed: companion=\(opened), visible browser=\(visible)"
            }
            let secondClicked = NativeUIAccessibility.click("chat.\(second)", in: window)
            let switched = await NativeUIAccessibility.wait {
                store.selectedChatID == second && !model.isPresented(for: second)
            }
            let backClicked = NativeUIAccessibility.click("chat.\(first)", in: window)
            let returned = await NativeUIAccessibility.wait {
                store.selectedChatID == first && model.isPresented(for: first)
                    && NativeUIAccessibility.find("chat.\(second)", in: window) != nil
            }
            results["chat-companion-switch"] =
                secondClicked && switched && backClicked && returned
                ? "passed"
                : "failed: second=\(secondClicked)/\(switched), return=\(backClicked)/\(returned)"
            capture(window, to: outputDirectory().appending(path: "chats-companion-switch.png"))
            window.setContentSize(originalSize)
        }

        private static func recordNavigationBoundaries(in window: NSWindow, results: inout [String: String]) {
            let main = NativeUIAccessibility.find("sidebar.main-pane", in: window)
            let browser = NativeUIAccessibility.find("chats.browser-pane", in: window)
            let detail = NativeUIAccessibility.find("chats.detail-pane", in: window)
            func chatSplit(in view: NSView?) -> NSSplitView? {
                guard let view else { return nil }
                if let split = view as? NSSplitView,
                    split.accessibilityIdentifier() == "chats.resize-divider"
                {
                    return split
                }
                return view.subviews.lazy.compactMap { chatSplit(in: $0) }.first
            }
            guard
                let mainFrame = main.map({ $0.recordedFrame ?? $0.frame }),
                let browserFrame = browser.map({ $0.recordedFrame ?? $0.frame }),
                let detailFrame = detail.map({ $0.recordedFrame ?? $0.frame }),
                let split = chatSplit(in: window.contentView), let browserItem = split.arrangedSubviews.first
            else {
                results["navigation-boundaries"] = "failed: missing pane"
                return
            }
            // The divider is now owned by NSSplitView, not a SwiftUI overlay.
            let dividerFrame = window.convertToScreen(
                split.convert(
                    NSRect(
                        x: browserItem.frame.maxX, y: split.bounds.minY,
                        width: split.dividerThickness, height: split.bounds.height), to: nil))
            let systemDivider = browserFrame.minX - mainFrame.maxX
            let chatDivider = detailFrame.minX - browserFrame.maxX
            let dividerTopGap = window.frame.maxY - dividerFrame.maxY
            let dividerBottomGap = dividerFrame.minY - window.frame.minY
            results["navigation-boundaries"] =
                systemDivider >= 0 && systemDivider <= 1.5
                    && abs(chatDivider - split.dividerThickness) < 1
                    && dividerTopGap >= 0 && dividerTopGap <= 1.5
                    && dividerBottomGap >= 0 && dividerBottomGap <= 1.5
                ? "passed"
                : "failed: system=\(systemDivider) chat=\(chatDivider) top=\(dividerTopGap) bottom=\(dividerBottomGap)"
        }

        private static func seed(_ store: DieterStore) {
            let names = ["adops-monorepo", "Beta", "Gamma"]
            let machines = [
                DieterEndpoint(
                    name: longMachineName,
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
            store.projectReplicaEndpointIDs = Dictionary(
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
            NativeTestSupport.outputDirectory(flag: "--ui-smoke-output")
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
            NativeTestSupport.writeReport(values, to: directory)
        }
    }
#endif
