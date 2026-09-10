#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation
    import SwiftUI

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

        /// MenuBarExtra keeps the process alive when a previous run closed its last
        /// workspace window, and macOS may restore that no-window state even for a
        /// fresh isolated launch. Ensure UI smoke modes exercise an actual
        /// workspace window instead of idling until their outer shell timeout expires.
        static func prepareWindowIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
            guard arguments.contains(where: { $0.hasSuffix("-ui-smoke") }) else { return }
            Task { @MainActor in
                for attempt in 0..<20 {
                    try? await DieterTaskSleep.milliseconds(250)
                    if NSApp.windows.contains(where: {
                        $0.contentView != nil && $0.frame.width >= 600 && $0.frame.height >= 400
                    }) {
                        return
                    }
                    if attempt == 0 {
                        let titles =
                            NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).map(\.title) ?? []
                        let text = "Window startup menu items: " + titles.joined(separator: " | ")
                        try? text.write(
                            to: outputDirectory().appending(path: "window-startup.log"), atomically: true,
                            encoding: .utf8)
                    }
                    guard attempt.isMultiple(of: 4),
                        let item = NSApp.mainMenu?.items
                            .compactMap(\.submenu)
                            .flatMap(\.items)
                            .first(where: { $0.title == "Dieter" || $0.title.hasSuffix(" Window") }),
                        let action = item.action
                    else { continue }
                    _ = NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        }

        static func run(store: DieterStore) async {
            let output = outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Wait for a genuinely live workspace, not merely one hydrated from the
            // disk projection: `workspaceIsLive` requires the daemon tunnel to be up
            // and the current sync to have settled, so the fixture RPC below is not
            // cancelled by an in-flight sync-recovery pass.
            guard
                await waitUntil(
                    timeout: 25,
                    condition: {
                        store.workspaceIsLive && !store.projects.isEmpty
                            && store.projects.contains { !store.boards(for: $0.id).isEmpty }
                    })
            else {
                writeReport(
                    [
                        "connection": "failed: fixture workspace did not become ready",
                        "phase": store.phase.label,
                        "projects": "\(store.projects.count)",
                    ], to: output)
                return
            }
            guard let project = store.projects.first(where: { !store.boards(for: $0.id).isEmpty }),
                let board = store.boards(for: project.id).first
            else {
                writeReport(["fixture": "failed: project or board missing"], to: output)
                return
            }
            store.selectedProjectID = project.id
            store.selectedBoardID = board.id
            await store.loadSchedules()
            var scheduleFixtureID = store.schedules.first?.id
            var scheduleFixtureError: String?
            if scheduleFixtureID == nil {
                var draft = Dieter_V1_ScheduleDraft()
                draft.projectID = project.id
                draft.boardID = board.id
                draft.name = "Native UI smoke schedule"
                draft.cron = "0 9 * * 1-5"
                draft.timezone = "UTC"
                draft.enabled = false
                draft.action = "draft"
                draft.titleTemplate = "Native UI smoke · {{date}}"
                draft.promptTemplate = "Exercise the native schedules list for {{project}}."
                draft.provider = "mock"
                draft.model = "mock"
                draft.effort = "low"
                draft.openCardPolicy = "skip_if_open"
                draft.misfirePolicy = "latest"
                draft.busyPolicy = "queue"
                draft.workspaceMode = "worktree"
                if await store.saveSchedule(id: nil, draft: draft) {
                    scheduleFixtureID = store.selectedScheduleID
                } else {
                    scheduleFixtureError = store.errorMessage ?? "the schedule RPC was unavailable"
                }
            }
            let schedulesOnly = ProcessInfo.processInfo.arguments.contains("--schedules-ui-smoke")
            var fixtureNote: String?
            if !schedulesOnly && store.state.cards.allSatisfy({ $0.boardID != board.id }) {
                // Create the fixture card through the store's outbox rather than a raw
                // RPC: the outbox queues and retries across the sync-recovery reconnects
                // that would otherwise cancel a single in-flight createCard call.
                let harness = store.harnessCatalog.harnesses.first
                await store.createConversation(
                    title: "Native UI smoke fixture",
                    prompt: "Keep this deferred. It only exercises the packaged UI.",
                    chat: false,
                    provider: harness?.id ?? "mock",
                    model: harness?.defaultModel ?? "",
                    effort: harness?.models.first(where: { $0.id == harness?.defaultModel })?.defaultEffort
                        ?? "",
                    deferred: true,
                    projectID: project.id,
                    lane: board.lanes.first?.id ?? "backlog"
                )
                store.section = .board
                store.closeConversation()
                let fixtureReady = await waitUntil(timeout: 25) {
                    store.state.cards.contains { $0.boardID == board.id }
                }
                if !fixtureReady {
                    fixtureNote =
                        "warning: fixture card did not sync within 25s; captured chrome may show an empty board"
                }
                await store.refreshState()
            }
            await store.openBoard(board.id, projectID: project.id)
            try? await DieterTaskSleep.seconds(1)

            guard
                let window = NSApp.windows.first(where: {
                    $0.isVisible && $0.contentView != nil && $0.title == "Dieter"
                })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            else {
                writeReport(["error": "failed: Dieter window not found"], to: output)
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
            let compatibleEndpointID = store.endpoint.id
            results["mixed-version-compatible-startup"] =
                store.endpoint.apiCompatibility == .compatible
                    && store.machines.contains(where: { $0.apiCompatibility == .incompatible })
                ? "passed"
                : "failed: startup did not select API \(dieterExpectedAPIVersion) from the mixed fleet"
            if let incompatibleMachine = store.machines.first(where: {
                $0.apiCompatibility == .incompatible
            }) {
                await store.connect(to: incompatibleMachine)
                results["mixed-version-switch-isolation"] =
                    store.endpoint.id == compatibleEndpointID && store.phase.isConnected
                        && store.workspaceIsLive
                        && store.machineConnectionErrors[incompatibleMachine.id] != nil
                        && store.errorMessage == nil
                    ? "passed"
                    : "failed: incompatible switch displaced the healthy route or presented a global error"
            } else {
                results["mixed-version-switch-isolation"] = "failed: legacy fixture machine was absent"
            }
            if let fixtureNote { results["fixture"] = fixtureNote }
            if let scheduleFixtureError {
                results["schedule-fixture"] = "failed: \(scheduleFixtureError)"
            }

            // Rapid project/conversation navigation can overlap an explicit route
            // change with an automatic reconnect. A completed stale attempt must
            // never tear down or publish state over the newest connection.
            let overlappingConnections = (0..<6).map { _ in
                Task { @MainActor in await store.connect() }
            }
            for attempt in overlappingConnections { await attempt.value }
            let newestConnectionSurvived = store.phase.isConnected
            results["connection-overlap-ownership"] =
                newestConnectionSurvived
                ? "passed"
                : "failed: stale attempt displaced the newest connection (\(store.phase.label))"
            if !newestConnectionSurvived {
                _ = await waitUntil(timeout: 25) { store.workspaceIsLive }
            }

            if schedulesOnly {
                await store.openProject(project.id, section: .schedules)
                let scheduleReady = await waitUntil(timeout: 10) {
                    store.schedulesAreLoaded
                        && scheduleFixtureID.map { id in store.schedules.contains(where: { $0.id == id }) }
                            == true
                }
                results["05-project-schedules"] =
                    store.section == .schedules ? "passed" : "failed: \(store.section.rawValue)"
                results["05-project-schedules-data"] =
                    scheduleReady
                    ? "passed"
                    : "failed: dedicated schedule load did not return the fixture"
                await captureAppearances(window, named: "05-project-schedules.png", in: output)
                writeReport(results, to: output)
                NSApp.terminate(nil)
                return
            }
            let originalWindowFrame = window.frame
            // AppKit may report isZoomed=false when the minimum window width
            // exceeds the CI display. Compare against its actual standard zoom.
            window.performZoom(nil)
            try? await DieterTaskSleep.seconds(1)
            let standardZoomFrame = window.frame
            window.setFrame(originalWindowFrame, display: true)
            try? await DieterTaskSleep.milliseconds(300)
            doubleClickTitleBar(of: window)
            try? await DieterTaskSleep.seconds(1)
            results["window-titlebar-double-click"] =
                window.frame == standardZoomFrame && window.frame != originalWindowFrame
                ? "passed"
                : "failed: hidden title-bar double-click did not toggle zoom (before=\(originalWindowFrame), after=\(window.frame), layout=\(window.contentLayoutRect), expected=\(standardZoomFrame))"
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

            // The packaged-app smoke has a fixed 1,380pt content width. Drive the
            // first lane's rendered sort button through Dieter's own NSWindow and
            // capture immediately, before any appearance change can rebuild it.
            NativeUIAccessibility.press("lane-sort.todo", in: window)
            try? await DieterTaskSleep.milliseconds(500)
            capture(window, to: output.appending(path: "01-board-oldest-first.png"))
            results["board-lane-sort-toggle"] = "dispatched for visual verification"
            if ProcessInfo.processInfo.arguments.contains("--board-stress-ui-smoke") {
                let boardCards = store.state.cards.filter { $0.boardID == board.id }
                let largestLane =
                    Dictionary(grouping: boardCards, by: \.lane).values.map(\.count).max() ?? 0
                results["board-stress-total-cards"] =
                    boardCards.count == 100
                    ? "passed"
                    : "failed: expected 100 cards, received \(boardCards.count)"
                results["board-stress-largest-lane"] =
                    largestLane == 85
                    ? "passed"
                    : "failed: expected 85 cards, received \(largestLane)"
            }
            if ProcessInfo.processInfo.arguments.contains("--board-stress-ui-smoke") {
                await runBoardOpeningChecks(
                    store: store, window: window, board: board, project: project, results: &results,
                    output: output)
                await runNavigationResponsivenessChecks(
                    store: store, window: window, board: board, project: project, results: &results,
                    output: output)
            }
            if ProcessInfo.processInfo.arguments.contains("--lane-sort-ui-smoke") {
                // Navigation measurements finish on Screens. Restore the board
                // before exercising controls that only exist in its header.
                await store.openBoard(board.id, projectID: project.id)
                _ = await waitUntil(timeout: 5) { NativeUIAccessibility.find("board.quick-task", in: window) != nil }
                try? await DieterTaskSleep.milliseconds(350)
                let toolbarUncovered = await closeBoardConversationForToolbar(store: store, window: window)
                results["board-toolbar-uncovered"] =
                    toolbarUncovered
                    ? "passed" : "failed: conversation overlay still covers board toolbar"
                if var draft = store.state.cards.first(where: { $0.boardID == board.id }) {
                    draft.initialPromptSentAt = ""
                    draft.lane = "todo"
                    let editor = NSWindow(
                        contentRect: NSRect(x: 100, y: 100, width: 620, height: 700),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    editor.isReleasedWhenClosed = false
                    editor.contentView = NSHostingView(
                        rootView: EditCardSheet(card: draft).environment(store))
                    editor.makeKeyAndOrderFront(nil)
                    try? await DieterTaskSleep.milliseconds(500)
                    results["draft-agent-settings"] =
                        NativeUIAccessibility.find("edit-card.agent-settings", in: editor) != nil
                        ? "passed" : "failed: draft agent controls absent"
                    capture(editor, to: output.appending(path: "draft-agent-settings.png"))
                    editor.close()
                    draft.initialPromptSentAt = "started"
                    let hover = BoardCardDropState()
                    let preview = NSWindow(
                        contentRect: NSRect(x: 100, y: 100, width: 310, height: 210),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    preview.isReleasedWhenClosed = false
                    preview.contentView = NSHostingView(
                        rootView: BoardCardView(card: draft, dropState: hover).environment(store).padding())
                    preview.makeKeyAndOrderFront(nil)
                    hover.enter(NSItemProvider(object: "board-card|board|todo|source" as NSString)) { _ in
                        true
                    }
                    // The production two-second hover begins only after the
                    // item provider finishes loading. Wait for that state so
                    // slower CI rendering does not consume a fixed sleep's slack.
                    let hoverArmed = await waitUntil(timeout: 5) { hover.mergeReady }
                    results["card-merge-hover-icon"] =
                        hoverArmed
                        ? "passed"
                        : "failed: merge hover did not arm (targeted=\(hover.targeted), payloadLoaded=\(hover.payload != nil))"
                    capture(preview, to: output.appending(path: "card-merge-hover-icon.png"))
                    hover.reset()
                    preview.close()
                    window.makeKeyAndOrderFront(nil)
                }
                let settingsClicked = NativeUIAccessibility.click("board.settings", in: window)
                let generalVisible = await waitUntil(timeout: 5) {
                    NativeUIAccessibility.find("board.settings.name", in: window) != nil
                }
                try? await DieterTaskSleep.milliseconds(400)
                let routingClicked = NativeUIAccessibility.selectSegment(
                    1, identifier: "board.settings.sections", in: window)
                let routingVisible = await waitUntil(timeout: 5) {
                    NativeUIAccessibility.find("board.hostnames", in: window) != nil
                }
                try? await DieterTaskSleep.milliseconds(300)
                let generalClicked = NativeUIAccessibility.selectSegment(
                    0, identifier: "board.settings.sections", in: window)
                let returned = await waitUntil(timeout: 5) {
                    NativeUIAccessibility.find("board.settings.name", in: window) != nil
                }
                results["board-settings-native-sections"] =
                    settingsClicked && generalVisible && routingClicked && routingVisible && generalClicked && returned
                    ? "passed"
                    : "failed: open=\(settingsClicked), general=\(generalVisible), route action=\(routingClicked), routing=\(routingVisible), general action=\(generalClicked), restored=\(returned)"
                let boardSettingsClosed = await NativeUIAccessibility.pressWhenSettled(
                    "board.settings.cancel", in: window)
                let boardSettingsDismissed = await waitUntil(timeout: 5) {
                    !store.archivePolicyPresented && window.attachedSheet == nil
                }
                results["board-settings-dismissal"] =
                    boardSettingsClosed && boardSettingsDismissed
                    ? "passed" : "failed: board settings did not dismiss before project settings"

                let projectClicked = NativeUIAccessibility.click("sidebar.project.\(project.id).settings", in: window)
                let projectContextVisible = await waitUntil(timeout: 5) {
                    NativeUIAccessibility.find("project.context.instructions", in: window) != nil
                }
                results["sidebar-project-context"] =
                    projectClicked && projectContextVisible
                    ? "passed" : "failed: project cog did not open instructions"
                let projectContextClosed = await NativeUIAccessibility.pressWhenSettled(
                    "project.context.cancel", in: window)
                let projectContextDismissed = await waitUntil(timeout: 5) {
                    !store.projectContextPresented && window.attachedSheet == nil
                }
                results["project-context-dismissal"] =
                    projectContextClosed && projectContextDismissed
                    ? "passed" : "failed: project settings did not dismiss before Quick Task"

                let globalReady = await waitForBoardControl("sidebar.quick-task", in: window)
                let globalOpened = globalReady && NativeUIAccessibility.click("sidebar.quick-task", in: window)
                let globalVisible = await waitUntil(timeout: 8, intervalMilliseconds: 50) {
                    ["quick-task.content", "quick-task.title", "quick-task.story", "quick-task.create"].allSatisfy {
                        NativeUIAccessibility.find($0, in: window)?.recordedFrame?.height ?? 0 > 0
                    }
                }
                if let content = NativeUIAccessibility.find("quick-task.content", in: window),
                    let sheet = content.recordedWindow,
                    let contentFrame = content.recordedFrame,
                    let titleFrame = NativeUIAccessibility.find("quick-task.title", in: sheet)?.recordedFrame,
                    let storyFrame = NativeUIAccessibility.find("quick-task.story", in: sheet)?.recordedFrame,
                    let createFrame = NativeUIAccessibility.find("quick-task.create", in: sheet)?
                        .recordedFrame
                {
                    let sheetFrame = sheet.convertToScreen(sheet.contentLayoutRect)
                    // Catch the former 700-point shell around a short, narrower form.
                    let compact =
                        abs(sheetFrame.height - contentFrame.height) < 48
                        && abs(sheetFrame.width - contentFrame.width) < 48
                        && contentFrame.height < 580
                        && createFrame.minY - contentFrame.minY < 40
                        && titleFrame.minY > storyFrame.maxY
                    results["global-quick-task-layout"] =
                        globalOpened && globalVisible && compact
                        ? "passed"
                        : "failed: excess shell space or misplaced title/footer; shell=\(sheetFrame), content=\(contentFrame)"
                    capture(sheet, to: output.appending(path: "global-quick-task-layout.png"))
                    let storyFocused = await focusQuickTaskStory(in: sheet)
                    if storyFocused {
                        await NativeUIAccessibility.type("Keep this draft after clicking outside", in: sheet)
                    }
                    let storyEntered = await waitUntil(timeout: 5, intervalMilliseconds: 50) {
                        store.quickTaskForm.story == "Keep this draft after clicking outside"
                    }
                    NativeUIEventDispatcher.click(
                        window: window, x: window.frame.width - 60, distanceFromTop: window.frame.height - 70,
                        throughApplication: true)
                    let dismissed = await waitUntil(timeout: 5) { !sheet.isVisible }
                    let reopenReady = await waitForBoardControl("sidebar.quick-task", in: window)
                    let reopenClicked = reopenReady && NativeUIAccessibility.click("sidebar.quick-task", in: window)
                    _ = await waitUntil(timeout: 5) {
                        NativeUIAccessibility.find("quick-task.story", in: window)?.recordedWindow?.isVisible == true
                    }
                    let reopened = NativeUIAccessibility.find("quick-task.story", in: window)?.recordedWindow
                    let retained =
                        reopened != nil && store.quickTaskForm.story == "Keep this draft after clicking outside"
                    if let reopened {
                        capture(reopened, to: output.appending(path: "global-quick-task-restored.png"))
                    }
                    results["global-quick-task-retains-draft"] =
                        storyFocused && storyEntered && dismissed && reopenClicked && retained
                        ? "passed"
                        : "failed: focus=\(storyFocused), typed=\(storyEntered), outside dismissal=\(dismissed), reopen=\(reopenClicked), restored content=\(retained), story=\(store.quickTaskForm.story)"
                    if let reopened {
                        if await waitForBoardControl("quick-task.cancel", in: reopened) {
                            _ = NativeUIAccessibility.click("quick-task.cancel", in: reopened)
                        }
                        _ = await waitUntil(timeout: 5) { !reopened.isVisible }
                    }
                    try? await DieterTaskSleep.milliseconds(350)
                    store.quickTaskForm.reset()
                } else {
                    results["global-quick-task-layout"] =
                        "failed: global ready=\(globalReady), open action=\(globalOpened), visible=\(globalVisible), active=\(NSApp.isActive), key=\(window.isKeyWindow); "
                        + ["quick-task.content", "quick-task.title", "quick-task.story", "quick-task.create"].map {
                            "\($0)=\(NativeUIAccessibility.find($0, in: window)?.recordedFrame?.debugDescription ?? "missing")"
                        }.joined(separator: "; ")
                }
                // Dismissing the global popover can also activate the underlying
                // card. A board header control stays mounted behind the overlay;
                // close the conversation before clicking the visible toolbar.
                let quickTaskToolbarUncovered = await closeBoardConversationForToolbar(store: store, window: window)
                results["quick-task-toolbar-uncovered"] =
                    quickTaskToolbarUncovered
                    ? "passed" : "failed: conversation overlay still covers Quick Task"
                let boardQuickTaskReady = await waitForBoardControl("board.quick-task", in: window)
                let boardQuickTaskClicked =
                    quickTaskToolbarUncovered && boardQuickTaskReady
                    && NativeUIAccessibility.click("board.quick-task", in: window)
                _ = await waitUntil(timeout: 5) {
                    NativeUIAccessibility.find("quick-task.story", in: window)?.recordedWindow?.isVisible == true
                }
                if let target = NativeUIAccessibility.find("quick-task.story", in: window),
                    let popover = target.recordedWindow
                {
                    let storyFocused = await focusQuickTaskStory(in: popover)
                    let pasteboard = NSPasteboard.general
                    let saved = (pasteboard.pasteboardItems ?? []).map { item in
                        item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                            values[type] = item.data(forType: type)
                        }
                    }
                    let image = NSImage(size: NSSize(width: 24, height: 24))
                    image.lockFocus()
                    NSColor.systemGreen.setFill()
                    NSRect(x: 0, y: 0, width: 24, height: 24).fill()
                    image.unlockFocus()
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    if storyFocused {
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let event = NSEvent.keyEvent(
                                with: type, location: .zero, modifierFlags: [.command],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popover.windowNumber,
                                context: nil,
                                characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)
                            {
                                NSApp.postEvent(event, atStart: false)
                            }
                        }
                    }
                    let attached = await waitUntil(timeout: 8, intervalMilliseconds: 50) {
                        popover.contentView?.layoutSubtreeIfNeeded()
                        popover.displayIfNeeded()
                        guard !store.quickTaskForm.attachments.isEmpty,
                            let preview = NativeUIAccessibility.find("quick-task.attachments", in: popover),
                            preview.recordedWindow === popover, let frame = preview.recordedFrame
                        else { return false }
                        return frame.width > 0 && frame.height > 0 && popover.isVisible
                    }
                    results["quick-task-paste-screenshot"] =
                        storyFocused && attached
                        ? "passed"
                        : "failed: focus=\(storyFocused), attachments=\(store.quickTaskForm.attachments.count), rendered preview=\(attached), active=\(NSApp.isActive), key=\(popover.isKeyWindow)"
                    capture(popover, to: output.appending(path: "quick-task-pasted-screenshot.png"))
                    pasteboard.clearContents()
                    let items = saved.map { values in
                        let item = NSPasteboardItem()
                        for (type, data) in values { item.setData(data, forType: type) }
                        return item
                    }
                    if !items.isEmpty { pasteboard.writeObjects(items) }
                } else {
                    results["quick-task-paste-screenshot"] =
                        "failed: Quick Task popover was absent (section=\(store.section.rawValue), click=\(boardQuickTaskClicked))"
                }
                writeReport(results, to: output)
                NSApp.terminate(nil)
                return
            }
            NativeUIAccessibility.press("lane-sort.todo", in: window)  // restore newest-first
            try? await DieterTaskSleep.milliseconds(350)

            store.openScreens()
            try? await DieterTaskSleep.milliseconds(500)
            results["01a-experimental-screens"] =
                store.section == .screens ? "passed" : "failed: screens did not open"
            await captureAppearances(window, named: "01a-experimental-screens.png", in: output)
            await store.openBoard(board.id, projectID: project.id)
            try? await DieterTaskSleep.milliseconds(500)

            // Project expansion remains independent of the system sidebar visibility.
            NativeUIAccessibility.click("sidebar.project.\(project.id).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(600)
            await captureAppearances(window, named: "01c-project-expanded.png", in: output)
            results["01c-project-expanded"] = "passed"
            NativeUIAccessibility.click("sidebar.project.\(project.id).toggle", in: window)
            try? await DieterTaskSleep.milliseconds(450)

            // Note: the row-body quick-nav popover is verified by hand — driving it
            // here opens a child window whose key/scene-phase cycle restarts global
            // sync and destabilizes the later RPC-backed steps. Its rows are identical
            // to the inline expansion captured above.

            // Exercise the system NavigationSplitView toggle. Collapsing hides
            // the entire sidebar; global compose stays in the window toolbar.
            let navigation = NativeUIAccessibility.navigationSplitController(in: window)
            navigation?.toggleSidebar(nil)
            let sidebarHidden = await NativeUIAccessibility.wait {
                navigation?.splitViewItems.first?.isCollapsed == true
            }
            let composeAvailable = NativeUIAccessibility.find("sidebar.quick-task", in: window) != nil
            await captureAppearances(window, named: "01b-navigation-collapsed.png", in: output)
            navigation?.toggleSidebar(nil)
            let sidebarShown = await NativeUIAccessibility.wait {
                navigation?.splitViewItems.first?.isCollapsed == false
            }
            let chatsReady = await waitForExpandedSidebarTarget("sidebar.all-chats", navigation: navigation, in: window)
            let chatsClicked = chatsReady && NativeUIAccessibility.click("sidebar.all-chats", in: window)
            let chatsOpened = await NativeUIAccessibility.wait { store.section == .chats }
            results["navigation-collapse"] =
                navigation != nil && sidebarHidden && composeAvailable && sidebarShown
                    && chatsReady && chatsClicked && chatsOpened
                ? "passed"
                : "failed: native sidebar toggle/navigation (hidden=\(sidebarHidden), shown=\(sidebarShown), compose=\(composeAvailable), ready=\(chatsReady), clicked=\(chatsClicked), active=\(NSApp.isActive), key=\(window.isKeyWindow), section=\(store.section.rawValue))"
            store.section = .board
            let steps = [Step(name: "02-global-chats", section: .chats, distanceFromTop: 142)]
            for step in steps {
                NativeUIAccessibility.click("sidebar.all-chats", in: window)
                try? await DieterTaskSleep.seconds(1)
                results[step.name] =
                    store.section == step.section ? "passed" : "failed: \(store.section.rawValue)"
                await captureAppearances(window, named: "\(step.name).png", in: output)
            }

            // Fast local reads can mount and remove the compact loading feedback in
            // one display cycle. Exercise that lifetime repeatedly because a task
            // attached to the feedback view previously aborted during cancellation.
            var allChatsChurnPassed = true
            for _ in 0..<12 {
                store.section = .board
                try? await DieterTaskSleep.milliseconds(20)
                await store.openChats()
                try? await DieterTaskSleep.milliseconds(20)
                allChatsChurnPassed = allChatsChurnPassed && store.section == .chats
            }
            results["02a-all-chats-loading-churn"] =
                allChatsChurnPassed
                ? "passed"
                : "failed: navigation became unstable"

            NativeUIAccessibility.click("chats.new", in: window)
            try? await DieterTaskSleep.seconds(1)
            results["03-standalone-chat"] =
                store.section == .chats && store.newChatProjectID == project.id
                ? "passed"
                : "failed: new chat composer did not open"
            await captureAppearances(window, named: "03-standalone-chat.png", in: output)

            // Projects are compressed by default, so these destinations are reached
            // through the project quick-nav popover / inline expansion at runtime.
            // Drive them through the store the popover calls into and capture each pane.
            let remaining: [(name: String, section: AppSection, navigate: () async -> Void)] = [
                ("04-project-files", .files, { await store.openProject(project.id, section: .files) }),
                (
                    "05-project-schedules", .schedules,
                    { await store.openProject(project.id, section: .schedules) }
                ),
                ("06-board", .board, { await store.openBoard(board.id, projectID: project.id) }),
            ]
            for step in remaining {
                await step.navigate()
                try? await DieterTaskSleep.seconds(1)
                results[step.name] =
                    store.section == step.section ? "passed" : "failed: \(store.section.rawValue)"
                await captureAppearances(window, named: "\(step.name).png", in: output)

                if step.section == .files {
                    await assessFileResponsiveness(
                        store: store, projectID: project.id, boardID: board.id,
                        window: window, output: output, results: &results)
                }

                if step.section == .schedules {
                    results["05-project-schedules-data"] =
                        store.schedulesAreLoaded
                            && scheduleFixtureID.map { id in store.schedules.contains(where: { $0.id == id }) }
                                == true
                        ? "passed"
                        : "failed: dedicated schedule load did not return the fixture"
                    let cancellationWindow = NSPanel(
                        contentRect: NSRect(x: 0, y: 0, width: 980, height: 820),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered,
                        defer: false
                    )
                    cancellationWindow.title = "New schedule cancellation"
                    cancellationWindow.contentViewController = NSHostingController(
                        rootView: ScheduleEditor(
                            model: store.schedulesModel, context: store.scheduleEditorContext, schedule: nil)
                    )
                    window.beginSheet(cancellationWindow, completionHandler: { _ in })
                    try? await DieterTaskSleep.milliseconds(50)
                    window.endSheet(cancellationWindow)
                    cancellationWindow.contentViewController = nil
                    try? await DieterTaskSleep.milliseconds(350)
                    results["05a-schedule-editor-cancellation"] = "passed"

                    let editorWindow = NSPanel(
                        contentRect: NSRect(x: 0, y: 0, width: 980, height: 820),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered,
                        defer: false
                    )
                    editorWindow.title = "New schedule"
                    editorWindow.contentViewController = NSHostingController(
                        rootView: ScheduleEditor(
                            model: store.schedulesModel, context: store.scheduleEditorContext, schedule: nil)
                    )
                    window.beginSheet(editorWindow, completionHandler: { _ in })
                    try? await DieterTaskSleep.seconds(2)
                    await captureAppearances(editorWindow, named: "05b-schedule-editor.png", in: output)
                    let size = editorWindow.contentLayoutRect.size
                    results["05b-schedule-editor"] =
                        size.width >= 900 && size.height >= 740
                        ? "passed"
                        : "failed: editor was cramped at \(Int(size.width))×\(Int(size.height))"
                    window.endSheet(editorWindow)
                    try? await DieterTaskSleep.milliseconds(350)
                }
            }

            click(window: window, x: 370, distanceFromTop: 215)
            try? await DieterTaskSleep.seconds(1)
            results["07-card-conversation"] =
                store.selectedCardID == nil ? "failed: no card selected" : "passed"
            await captureAppearances(window, named: "07-card-conversation.png", in: output)

            store.openSettings()
            try? await DieterTaskSleep.milliseconds(700)
            results["09-settings-general"] =
                store.section == .settings ? "passed" : "failed: settings did not open"
            await captureAppearances(window, named: "09-settings-general.png", in: output)

            click(window: window, x: 920, distanceFromTop: 196)
            try? await DieterTaskSleep.milliseconds(700)
            let storedAppearance = DieterAppearance.resolve(
                appearanceDefaults.string(forKey: DieterAppearance.storageKey))
            let effectiveAppearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            results["09b-settings-light-appearance"] =
                storedAppearance == .light
                    && store.themeSelection.appearance == .light
                    && effectiveAppearance == .aqua
                ? "passed"
                : "failed: stored=\(storedAppearance.rawValue), live=\(store.themeSelection.appearance.rawValue), effective=\(effectiveAppearance?.rawValue ?? "unknown")"
            await captureAppearances(window, named: "09b-settings-light-appearance.png", in: output)

            click(window: window, x: 1_230, distanceFromTop: 376)
            try? await DieterTaskSleep.milliseconds(700)
            let storedPalette = DieterPalette.resolve(
                appearanceDefaults.string(forKey: DieterPalette.storageKey))
            results["09c-settings-coral-design"] =
                storedPalette == .coralSignal
                    && store.themeSelection.palette == .coralSignal
                ? "passed"
                : "failed: stored=\(storedPalette.rawValue), live=\(store.themeSelection.palette.rawValue)"
            await captureAppearances(window, named: "09c-settings-coral-design.png", in: output)

            click(window: window, x: 600, distanceFromTop: 324)
            try? await DieterTaskSleep.milliseconds(700)
            results["09d-settings-monochrome-design"] =
                store.themeSelection.palette == .monochrome
                ? "passed"
                : "failed: live=\(store.themeSelection.palette.rawValue)"

            click(window: window, x: 320, distanceFromTop: 151)
            try? await DieterTaskSleep.milliseconds(700)
            await captureAppearances(window, named: "10-settings-connection.png", in: output)
            results["10-settings-connection"] = "passed"

            await store.cleanSync()
            let cleanSyncRecovered = await waitUntil(timeout: 20) {
                store.phase.isConnected && !store.projects.isEmpty
            }
            results["10b-settings-clean-sync"] =
                cleanSyncRecovered
                ? "passed"
                : "failed: clean sync did not rebuild the workspace (\(store.phase.label), \(store.projects.count) projects)"

            click(window: window, x: 320, distanceFromTop: 187)
            try? await DieterTaskSleep.seconds(1)
            await captureAppearances(window, named: "11-settings-prompts.png", in: output)
            results["11-settings-prompts"] = "passed"

            store.section = .board
            // A pending error alert from an earlier step blocks any further sheet
            // presentation on the same window; dismiss it before opening sheets.
            store.errorMessage = nil
            try? await DieterTaskSleep.milliseconds(350)
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
            results["12b-connection-onboarding"] =
                store.phase.needsConnectionOverlay ? "passed" : "failed: overlay phase inactive"
            store.phase = connectedPhase
            try? await DieterTaskSleep.milliseconds(350)

            store.errorMessage = nil
            try? await DieterTaskSleep.milliseconds(350)
            store.createConversationPresented = true
            try? await DieterTaskSleep.milliseconds(700)
            if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
                await captureAppearances(sheet, named: "13-new-card.png", in: output)
                results["13-new-card"] = "passed"
                click(window: sheet, x: 217, distanceFromTop: 425)
                try? await DieterTaskSleep.milliseconds(700)
                if let picker = NSApp.windows.first(where: {
                    $0.isSheet && $0.isVisible && $0.windowNumber != sheet.windowNumber
                }) {
                    await captureAppearances(picker, named: "13a-workspace-picker-worktree.png", in: output)
                    click(window: picker, x: 500, distanceFromTop: 190)
                    try? await DieterTaskSleep.milliseconds(350)
                    await captureAppearances(picker, named: "13a-workspace-picker-project.png", in: output)
                    results["13a-workspace-picker"] = "passed"
                    click(window: picker, x: picker.frame.width - 32, distanceFromTop: 36)
                    try? await DieterTaskSleep.milliseconds(350)
                } else {
                    results["13a-workspace-picker"] = "failed: sheet not visible"
                }
            } else {
                results["13-new-card"] = "failed: sheet not visible"
            }
            store.createConversationPresented = false
            try? await DieterTaskSleep.milliseconds(350)

            store.section = .board
            store.closeConversation()
            let todoLane = board.lanes.first(where: {
                $0.id.caseInsensitiveCompare("todo") == .orderedSame
            })
            if let todoLane {
                let title = "Native UI todo creation \(UUID().uuidString.lowercased())"
                let harness = store.harnessCatalog.harnesses.first
                await store.createConversation(
                    title: title,
                    prompt: "Create this deferred card without opening its conversation.",
                    chat: false,
                    provider: harness?.id ?? "",
                    model: harness?.defaultModel ?? "",
                    effort: harness?.models.first(where: { $0.id == harness?.defaultModel })?.defaultEffort
                        ?? "",
                    deferred: true,
                    lane: todoLane.id,
                    workspace: ConversationWorkspaceDraft(
                        mode: .worktree,
                        baseBranch: project.baseBranch
                    )
                )
                let created = await waitUntil(timeout: 10) {
                    store.state.cards.contains {
                        $0.title == title && $0.lane.caseInsensitiveCompare("todo") == .orderedSame
                            && $0.workspaceMode == "worktree" && DieterConversationID.isServerBacked($0.id)
                    }
                }
                results["13b-todo-card-stays-on-board"] =
                    created && store.section == .board && store.selectedCardID == nil
                    ? "passed"
                    : "failed: created=\(created), section=\(store.section.rawValue), selected=\(store.selectedCardID ?? "none")"
                if let draft = store.state.cards.first(where: { $0.title == title }) {
                    let editedTitle = "\(title) edited"
                    let editedTask = "Edit this deferred card before its first agent turn."
                    let updated = await store.update(draft, title: editedTitle, initialPrompt: editedTask)
                    let synchronized: Bool
                    if updated {
                        synchronized = await waitUntil(timeout: 10) {
                            store.state.cards.contains {
                                $0.id == draft.id && $0.title == editedTitle && $0.initialPrompt == editedTask
                            }
                        }
                    } else {
                        synchronized = false
                    }
                    results["13c-todo-card-edit"] =
                        synchronized
                        ? "passed"
                        : "failed: packaged Mac UpdateCard did not synchronize both draft fields"
                } else {
                    results["13c-todo-card-edit"] = "failed: deferred card was unavailable for editing"
                }
            } else {
                results["13b-todo-card-stays-on-board"] = "failed: fixture board has no Todo lane"
                results["13c-todo-card-edit"] = "failed: fixture board has no Todo lane"
            }

            store.section = .chats
            store.closeConversation()
            store.errorMessage = nil
            let chatTitle = "Native UI chat creation \(UUID().uuidString.lowercased())"
            let chatHarness =
                store.harnessCatalog.harnesses.first(where: { $0.id == "mock" })
                ?? store.harnessCatalog.harnesses.first
            await store.createConversation(
                title: chatTitle,
                prompt: "Create and open this standalone chat.",
                chat: true,
                provider: chatHarness?.id ?? "",
                model: chatHarness?.defaultModel ?? "",
                effort: chatHarness?.models.first(where: { $0.id == chatHarness?.defaultModel })?
                    .defaultEffort ?? "",
                deferred: false,
                projectID: project.id
            )
            var chatRowStayedSingle = true
            let openedChat = await waitUntil(timeout: 10, intervalMilliseconds: 25) {
                let ids = store.chats.map(\.id)
                chatRowStayedSingle =
                    chatRowStayedSingle && Set(ids).count == ids.count
                    && store.chats.count { $0.title == chatTitle } <= 1
                guard let chatID = store.selectedChatID, DieterConversationID.isServerBacked(chatID) else {
                    return false
                }
                return store.conversation?.detail.card.id == chatID && !store.conversationLoading
            }
            results["13c-standalone-chat-opens"] =
                openedChat && store.errorMessage == nil
                ? "passed"
                : "failed: selected=\(store.selectedChatID ?? "none"), loading=\(store.conversationLoading), error=\(store.errorMessage ?? "none")"
            results["13c-standalone-chat-single-row"] =
                chatRowStayedSingle
                ? "passed"
                : "failed: optimistic and synchronized chat rows were visible together"
            if openedChat,
                let chatID = store.selectedChatID,
                let chat = store.chats.first(where: { $0.id == chatID })
            {
                let renamedTitle = "\(chatTitle) renamed"
                await store.rename(chat, title: renamedTitle)
                let renamed = await waitUntil(timeout: 10) {
                    store.chats.contains { $0.id == chatID && $0.title == renamedTitle }
                }
                results["13d-standalone-chat-rename"] =
                    renamed
                    ? "passed"
                    : "failed: packaged Mac RenameCard did not synchronize the chat title"

                if let renamedChat = store.chats.first(where: { $0.id == chatID }) {
                    await store.pin(renamedChat, pinned: true)
                    let pinned = await waitUntil(timeout: 10) {
                        store.chats.contains { $0.id == chatID && $0.pinned }
                    }
                    results["13e-standalone-chat-pin"] =
                        pinned
                        ? "passed"
                        : "failed: packaged Mac PinChat did not update the chat projection"

                    if pinned {
                        store.closeConversation()
                        try? await DieterTaskSleep.milliseconds(500)
                        await captureAppearances(window, named: "13e-standalone-chat-pinned.png", in: output)
                        results["13e-pinned-chat-ui"] = "passed"
                    } else {
                        results["13e-pinned-chat-ui"] =
                            "failed: pinned chat was unavailable for rendered verification"
                    }

                    if let pinnedChat = store.chats.first(where: { $0.id == chatID }) {
                        await store.pin(pinnedChat, pinned: false)
                    }
                    let unpinned = await waitUntil(timeout: 10) {
                        store.chats.contains { $0.id == chatID && !$0.pinned }
                    }
                    results["13f-standalone-chat-unpin"] =
                        unpinned
                        ? "passed"
                        : "failed: packaged Mac PinChat did not clear the pinned state"
                } else {
                    results["13e-standalone-chat-pin"] = "failed: renamed chat disappeared before pinning"
                    results["13f-standalone-chat-unpin"] = "failed: renamed chat disappeared before unpinning"
                }
            } else {
                results["13d-standalone-chat-rename"] = "failed: created chat was unavailable for rename"
                results["13e-standalone-chat-pin"] = "failed: created chat was unavailable for pinning"
                results["13f-standalone-chat-unpin"] = "failed: created chat was unavailable for unpinning"
            }
            store.closeConversation()
            try? await DieterTaskSleep.milliseconds(500)
            await captureAppearances(window, named: "13d-standalone-chat-renamed.png", in: output)

            // A repository can be registered on several enrolled machines. Render
            // the real new-chat surface with a duplicate project name and require
            // its selected destination to retain the owning machine identity.
            let duplicateMachine = DieterEndpoint(
                name: "Smoke remote Mac",
                host: store.endpoint.host,
                port: store.endpoint.port,
                secure: store.endpoint.secure,
                daemonID: "smoke-duplicate-machine",
                online: false,
                version: "v0.4.57"
            )
            var duplicateProject = project
            duplicateProject.id = "p_duplicate_machine_ui_smoke"
            duplicateProject.path = "/Users/smoke/Development/\(project.name)"
            store.endpoints.append(duplicateMachine)
            store.projectDirectory[duplicateProject.id] = duplicateProject
            store.projectEndpointIDs[duplicateProject.id] = duplicateMachine.id
            store.beginStandaloneChat(projectID: duplicateProject.id)
            try? await DieterTaskSleep.milliseconds(700)
            let destinationGroups = store.projectDestinationGroups()
            let duplicateDestination = ProjectDestinationCatalog.destination(
                projectID: duplicateProject.id,
                in: destinationGroups
            )
            let duplicateNamesAreGrouped =
                destinationGroups.filter {
                    $0.destinations.contains { $0.project.name == project.name }
                }.count >= 2
            results["13g-new-chat-projects-grouped-by-machine"] =
                duplicateNamesAreGrouped
                    && duplicateDestination?.title == "\(project.name) · Smoke remote Mac"
                ? "passed"
                : "failed: groups=\(destinationGroups.map(\.title)), selection=\(duplicateDestination?.title ?? "none")"
            await captureAppearances(window, named: "13g-new-chat-project-machine.png", in: output)
            store.projectDirectory.removeValue(forKey: duplicateProject.id)
            store.projectEndpointIDs.removeValue(forKey: duplicateProject.id)
            store.endpoints.removeAll { $0.id == duplicateMachine.id }
            store.newChatProjectID = project.id
            store.selectedProjectID = project.id
            try? await DieterTaskSleep.milliseconds(350)

            store.createProjectPresented = true
            try? await DieterTaskSleep.milliseconds(700)
            if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
                await captureAppearances(sheet, named: "14-new-project.png", in: output)
                results["14-new-project"] = "passed"
                let browseClicked = NativeUIAccessibility.click("new-project.browse", in: sheet)
                _ = await NativeUIAccessibility.wait {
                    NSApp.windows.contains {
                        $0.isSheet && $0.isVisible && $0.windowNumber != sheet.windowNumber
                    }
                }
                if let browser = NSApp.windows.first(where: {
                    $0.isSheet && $0.isVisible && $0.windowNumber != sheet.windowNumber
                }) {
                    await captureAppearances(browser, named: "15-remote-directory-browser.png", in: output)
                    results["15-remote-directory-browser"] = "passed"
                } else {
                    results["15-remote-directory-browser"] =
                        "failed: browser sheet not visible (browse click dispatched=\(browseClicked))"
                }
            } else {
                results["14-new-project"] = "failed: sheet not visible"
            }
            store.createProjectPresented = false
            try? await DieterTaskSleep.milliseconds(350)

            let projectParent = URL(fileURLWithPath: project.path).deletingLastPathComponent()
            let projectMachineID = store.machine(forProjectID: project.id)?.id ?? store.endpoint.id
            var newProjectDraft = ProjectSetupDraft()
            newProjectDraft.mode = .newRepository
            newProjectDraft.path =
                projectParent.appendingPathComponent("mac-created-\(UUID().uuidString.lowercased())").path
            newProjectDraft.name = "Mac-created Git project"
            newProjectDraft.boardName = "Main"
            newProjectDraft.workflow = "review"
            do {
                let created = try await store.createProject(newProjectDraft, machineID: projectMachineID)
                let listing = try await store.listProjectDirectories(
                    path: created.project.path, machineID: projectMachineID)
                results["15b-create-git-project"] =
                    listing.gitRepository && created.board.projectID == created.project.id
                    ? "passed"
                    : "failed: created path was not a Git working tree or board ownership was wrong"
            } catch {
                results["15b-create-git-project"] = "failed: \(DieterRPCFailure.message(for: error))"
            }

            var linkedWorktreeDraft = ProjectSetupDraft()
            linkedWorktreeDraft.mode = .existing
            linkedWorktreeDraft.path = projectParent.appendingPathComponent("linked-worktree").path
            linkedWorktreeDraft.name = "Linked worktree"
            linkedWorktreeDraft.boardName = "Main"
            linkedWorktreeDraft.workflow = "review"
            do {
                let created = try await store.createProject(
                    linkedWorktreeDraft, machineID: projectMachineID)
                let listing = try await store.listProjectDirectories(
                    path: created.project.path, machineID: projectMachineID)
                results["15c-open-linked-worktree"] =
                    listing.gitRepository && created.project.path != project.path
                    ? "passed"
                    : "failed: linked worktree was not registered as a distinct Git project"
            } catch {
                results["15c-open-linked-worktree"] = "failed: \(DieterRPCFailure.message(for: error))"
            }

            await store.openBoard(board.id, projectID: project.id)

            store.section = .board
            try? await DieterTaskSleep.milliseconds(700)
            await captureAppearances(window, named: "16-light-workspace.png", in: output)
            results["16-light-workspace"] =
                window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
                ? "passed"
                : "failed: light appearance did not persist"

            do {
                guard
                    let cachedBoard = try await store.createBoard(
                        projectID: project.id,
                        name: "Offline navigation smoke \(UUID().uuidString.lowercased())",
                        workflow: "review",
                        doneArchivePolicy: "never"
                    )
                else {
                    throw NSError(
                        domain: "NativeUISmokeRunner",
                        code: 17,
                        userInfo: [NSLocalizedDescriptionKey: "RPC client missing"]
                    )
                }
                await store.refreshState()
                try? await DieterTaskSleep.seconds(1)
                await store.openBoard(board.id, projectID: project.id)
                store.errorMessage = nil
                let liveCard = store.state.cards.first(where: { $0.boardID == board.id })
                if let liveCard {
                    await store.openConversation(cardID: liveCard.id)
                    _ = await waitUntil(timeout: 5) {
                        store.conversation?.detail.card.id == liveCard.id && !store.conversationLoading
                    }
                    let inspectorVisible = await waitUntil(timeout: 5) {
                        NativeUIAccessibility.find("board.conversation-close", in: window) != nil
                    }
                    // The inspector animates after its controls first enter the view tree.
                    try? await DieterTaskSleep.milliseconds(400)
                    let closed = await NativeUIAccessibility.pressWhenSettled("board.conversation-close", in: window)
                    let selectionCleared = await waitUntil(timeout: 5) {
                        store.selectedCardID == nil && store.conversation == nil
                            && !NativeUIAccessibility.hasOpenInspector(in: window)
                    }
                    let clearedState =
                        "selection=\(store.selectedCardID ?? "nil"), conversation=\(store.conversation?.detail.card.id ?? "nil"), close mounted=\(NativeUIAccessibility.find("board.conversation-close", in: window) != nil)"
                    // Let the native collapse transition finish before presenting again.
                    try? await DieterTaskSleep.milliseconds(400)
                    await store.openConversation(cardID: liveCard.id)
                    let reopened = await waitUntil(timeout: 5) {
                        store.conversation?.detail.card.id == liveCard.id && !store.conversationLoading
                            && NativeUIAccessibility.find("board.conversation-close", in: window) != nil
                    }
                    try? await DieterTaskSleep.milliseconds(400)
                    results["board-native-inspector-close-reopen"] =
                        closed && selectionCleared && reopened
                        ? "passed"
                        : "failed: inspector visible=\(inspectorVisible), close=\(closed), cleared=\(selectionCleared), reopened=\(reopened), \(clearedState)"
                }
                if let trigger = offlineTrigger() {
                    FileManager.default.createFile(atPath: trigger.path, contents: Data())
                    _ = await waitUntil(timeout: 10) { !store.phase.isConnected }
                    // Let both WatchSync and WatchConversation observe the
                    // daemon tunnel closing before checking for alert state.
                    try? await DieterTaskSleep.seconds(1)
                } else {
                    store.disconnect()
                }
                let canceledOfflineMessage =
                    "Canceled offline outbox smoke \(UUID().uuidString.lowercased())"
                if let liveCard, let machine = store.machine(forProjectID: liveCard.projectID) {
                    store.composerText = canceledOfflineMessage
                    await store.sendComposer()
                    let queued = await waitUntil(timeout: 5) {
                        store.outboxSummary(for: machine)?.messageCount == 1
                    }
                    results["17a-offline-message-queued"] =
                        queued && store.composerText.isEmpty
                        ? "passed"
                        : "failed: queued=\(store.outboxSummary(for: machine)?.messageCount ?? 0), draft=\(store.composerText)"
                    await captureAppearances(window, named: "17a-offline-message-queued.png", in: output)

                    let removed = await store.discardOutbox(for: machine)
                    let canceled = await waitUntil(timeout: 5) {
                        store.outboxSummary(for: machine) == nil
                            && !store.conversationMessages.contains { message in
                                message.parts.contains { $0.type == "text" && $0.text == canceledOfflineMessage }
                            }
                    }
                    results["17b-offline-message-canceled"] =
                        removed == 1 && canceled
                        ? "passed"
                        : "failed: removed=\(removed), queued=\(store.outboxSummary(for: machine)?.messageCount ?? 0)"
                    await captureAppearances(window, named: "17b-offline-message-canceled.png", in: output)

                    store.composerText = "Offline delivery smoke \(UUID().uuidString.lowercased())"
                    await store.sendComposer()
                    _ = await waitUntil(timeout: 5) {
                        store.outboxSummary(for: machine)?.messageCount == 1
                    }
                } else {
                    results["17a-offline-message-queued"] = "failed: live card or owning machine missing"
                    results["17b-offline-message-canceled"] = "failed: live card or owning machine missing"
                }
                await store.openBoard(cachedBoard.id, projectID: project.id)
                try? await DieterTaskSleep.milliseconds(700)
                let offlineLabel = SyncFreshnessPresentation.lastConnectedLabel(
                    lastConnectedAt: store.lastSyncedAt
                )
                let stayedUsable =
                    store.section == .board && store.selectedBoard?.id == cachedBoard.id
                    && store.errorMessage == nil
                    && store.hasLoadedWorkspace && !store.phase.isConnected
                    && offlineLabel.hasPrefix("Last connected ")
                results["17-offline-cached-board-navigation"] =
                    stayedUsable
                    ? "passed"
                    : "failed: section=\(store.section.rawValue), board=\(store.selectedBoard?.id ?? "none"), phase=\(store.phase.label), freshness=\(offlineLabel), error=\(store.errorMessage ?? "none")"
                await captureAppearances(
                    window, named: "17-offline-cached-board-navigation.png", in: output)

                if let trigger = offlineTrigger(), let liveCard {
                    try? FileManager.default.removeItem(at: trigger)
                    let reconnected = await waitUntil(timeout: 25) { store.phase.isConnected }
                    let delivered = await waitUntil(timeout: 15) {
                        guard let machine = store.machine(forProjectID: liveCard.projectID) else {
                            return false
                        }
                        return store.outboxSummary(for: machine) == nil
                    }
                    if reconnected && delivered {
                        await store.openConversation(cardID: liveCard.id)
                    }
                    let visible = await waitUntil(timeout: 10) {
                        store.conversationMessages.contains { message in
                            message.parts.contains {
                                $0.type == "text" && $0.text.hasPrefix("Offline delivery smoke ")
                            }
                        }
                    }
                    let canceledStayedAbsent = !store.conversationMessages.contains { message in
                        message.parts.contains { $0.type == "text" && $0.text == canceledOfflineMessage }
                    }
                    results["17c-reconnected-message-delivered"] =
                        reconnected && delivered && visible && canceledStayedAbsent
                        ? "passed"
                        : "failed: reconnected=\(reconnected), delivered=\(delivered), visible=\(visible), canceledAbsent=\(canceledStayedAbsent)"
                    await captureAppearances(
                        window, named: "17c-reconnected-message-delivered.png", in: output)
                } else {
                    results["17c-reconnected-message-delivered"] =
                        "failed: reconnect trigger or live card missing"
                }
            } catch {
                results["17-offline-cached-board-navigation"] =
                    "failed: could not prepare cached board: \(error.localizedDescription)"
            }

            // Use an independent task: closing a Window cancels its view task,
            // while the app session and its menu-bar reopen action must survive.
            let reopened = await Task { @MainActor in
                let selection = store.selectedProjectID
                let client = store.rpc
                window.close()
                try? await DieterTaskSleep.milliseconds(350)
                store.reopenWorkspaceWindow()
                let visible = await waitUntil(timeout: 5) {
                    NSApp.windows.filter { $0.isVisible && !$0.isSheet && $0.frame.width >= 600 }.count == 1
                }
                if let reopenedWindow = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 600 }
                ) {
                    capture(reopenedWindow, to: output.appending(path: "workspace-window-reopened.png"))
                }
                return visible && store.rpc === client && store.selectedProjectID == selection
            }.value
            results["workspace-window-reopen"] =
                reopened ? "passed" : "failed: selection, connection or window count changed"
            writeReport(results, to: output)
        }

        private static func waitUntil(
            timeout: TimeInterval,
            intervalMilliseconds: Int = 200,
            condition: @escaping @MainActor () -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await DieterTaskSleep.milliseconds(intervalMilliseconds)
            }
            return condition()
        }

        private static func waitForExpandedSidebarTarget(
            _ identifier: String, navigation: NSSplitViewController?, in window: NSWindow
        ) async -> Bool {
            guard let item = navigation?.splitViewItems.first else { return false }
            var previousFrame: CGRect?
            var stableSamples = 0
            var nextActivation = Date.distantPast
            return await waitUntil(timeout: 8, intervalMilliseconds: 50) {
                if (!NSApp.isActive || !window.isKeyWindow), window.attachedSheet == nil,
                    Date() >= nextActivation
                {
                    _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    nextActivation = Date().addingTimeInterval(1)
                }
                guard NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil, !item.isCollapsed,
                    let target = NativeUIAccessibility.find(identifier, in: window),
                    target.recordedWindow === window, let frame = target.recordedFrame,
                    frame.width > 0, frame.height > 0
                else {
                    stableSamples = 0
                    return false
                }
                let sidebar = item.viewController.view
                let sidebarFrame = window.convertToScreen(sidebar.convert(sidebar.bounds, to: nil))
                guard sidebar.window === window, sidebarFrame.insetBy(dx: -1, dy: -1).contains(frame) else {
                    stableSamples = 0
                    return false
                }
                stableSamples = frame == previousFrame ? stableSamples + 1 : 0
                previousFrame = frame
                return stableSamples >= 3
            }
        }

        /// Popover and toolbar controls must be in their actual, focused window
        /// before the one pointer action; a first click can otherwise only focus.
        private static func waitForBoardControl(_ identifier: String, in window: NSWindow) async -> Bool {
            var previousFrame: CGRect?
            var stableSamples = 0
            var nextActivation = Date.distantPast
            return await waitUntil(timeout: 8, intervalMilliseconds: 50) {
                if (!NSApp.isActive || !window.isKeyWindow), window.attachedSheet == nil,
                    Date() >= nextActivation
                {
                    _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    nextActivation = Date().addingTimeInterval(1)
                }
                window.contentView?.layoutSubtreeIfNeeded()
                guard NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil,
                    let target = NativeUIAccessibility.find(identifier, in: window),
                    target.recordedWindow === window, let frame = target.recordedFrame,
                    frame.width > 0, frame.height > 0, window.frame.insetBy(dx: -1, dy: -1).contains(frame)
                else {
                    stableSamples = 0
                    return false
                }
                stableSamples = frame == previousFrame ? stableSamples + 1 : 0
                previousFrame = frame
                return stableSamples >= 3
            }
        }

        private static func focusQuickTaskStory(in window: NSWindow) async -> Bool {
            guard await waitForBoardControl("quick-task.story", in: window) else { return false }
            window.makeFirstResponder(nil)
            guard NativeUIAccessibility.click("quick-task.story", in: window) else { return false }
            return await waitUntil(timeout: 5, intervalMilliseconds: 50) {
                guard NSApp.isActive, window.isKeyWindow,
                    let editor = window.firstResponder as? NSTextView, editor.isEditable, editor.window === window,
                    let storyFrame = NativeUIAccessibility.find("quick-task.story", in: window)?.recordedFrame
                else { return false }
                let editorFrame = window.convertToScreen(editor.convert(editor.bounds, to: nil))
                return storyFrame.intersects(editorFrame)
            }
        }

        private static func assessFileResponsiveness(
            store: DieterStore, projectID: String, boardID: String, window: NSWindow,
            output: URL, results: inout [String: String]
        ) async {
            guard let rpc = store.rpc else {
                results["files-editor-lifecycle"] = "failed: no RPC"
                return
            }
            let documents = [
                ("responsiveness-a.md", "# File A\nVisible editor content.\n"),
                ("responsiveness-b.md", "# File B\nAnother document.\n"),
            ]
            do {
                for (path, content) in documents {
                    var create = Dieter_V1_CreateFileRequest()
                    create.projectID = projectID
                    create.path = path
                    create.kind = "file"
                    _ = try await rpc.createFile(create)
                    var read = Dieter_V1_ReadFileRequest()
                    read.projectID = projectID
                    read.path = path
                    let blank = try await rpc.readFile(read)
                    var save = Dieter_V1_SaveFileRequest()
                    save.projectID = projectID
                    save.path = path
                    save.content = content
                    save.revision = blank.revision
                    _ = try await rpc.saveFile(save)
                }
                await store.loadFiles()
                try? await DieterTaskSleep.milliseconds(250)
                var latencies: [Double] = []
                var feedbackLatencies: [Double] = []
                for (path, content) in [documents[0], documents[1], documents[0]] {
                    let start = ContinuousClock.now
                    let clicked = NativeUIAccessibility.click("files.row.\(path)", in: window)
                    let acknowledged = await waitUntil(timeout: 5, intervalMilliseconds: 5) {
                        store.selectedFilePath == path
                    }
                    let feedbackTime = start.duration(to: .now)
                    feedbackLatencies.append(
                        Double(feedbackTime.components.attoseconds) / 1e15 + Double(
                            feedbackTime.components.seconds)
                            * 1_000)
                    let loaded = await waitUntil(timeout: 5, intervalMilliseconds: 5) {
                        store.selectedFilePath == path && store.fileDocument?.content == content
                            && nativeTextViews(in: window.contentView).contains { $0.string == content }
                    }
                    latencies.append(
                        Double(start.duration(to: .now).components.attoseconds) / 1e15
                            + Double(start.duration(to: .now).components.seconds) * 1_000)
                    guard clicked && acknowledged && loaded else {
                        results["files-editor-lifecycle"] =
                            "failed: \(path) did not display its nonempty document"
                        return
                    }
                }
                results["files-editor-lifecycle"] = "passed"
                results["files-click-to-selection-ms"] = feedbackLatencies.map {
                    String(format: "%.1f", $0)
                }.joined(
                    separator: ", ")
                results["files-open-to-content-ms"] = latencies.map { String(format: "%.1f", $0) }.joined(
                    separator: ", ")
                guard
                    let editor = nativeTextViews(in: window.contentView).first(where: {
                        $0.string == documents[0].1 && $0.isEditable && $0.window === window
                    })
                else {
                    results["files-edit-save"] = "failed: native editor missing"
                    return
                }
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                await NativeUIAccessibility.type("Saved through the native editor.\n", in: window)
                let expected = documents[0].1 + "Saved through the native editor.\n"
                let edited = await waitUntil(timeout: 5) {
                    store.fileEditorSession.isDirty && editor.string == expected
                }
                let saved = await NativeUIAccessibility.pressWhenSettled("files.save", in: window)
                let persisted = await waitUntil(timeout: 5) {
                    store.fileDocument?.content == expected && !store.fileEditorSession.isDirty
                }
                results["files-edit-save"] =
                    edited && saved && persisted
                    ? "passed"
                    : "failed: native edit/save did not persist (edited=\(edited), save action=\(saved), persisted=\(persisted))"
                await store.openBoard(boardID, projectID: projectID)
                await store.openProject(projectID, section: .files)
                let revisited = await waitUntil(timeout: 5) {
                    nativeTextViews(in: window.contentView).contains { $0.string == expected }
                }
                results["files-warm-revisit"] =
                    revisited ? "passed" : "failed: saved editor was blank on revisit"
                await captureAppearances(window, named: "04a-loaded-editor.png", in: output)
                await store.openFile(path: "missing-responsiveness-file.txt")
                results["files-failed-read-ends-loading"] =
                    !store.fileLoading && store.fileError != nil
                    ? "passed" : "failed: read did not settle into an error"
                await captureAppearances(window, named: "04b-file-read-error.png", in: output)
                let row = NativeUIAccessibility.find("files.row.responsiveness-b.md", in: window)
                let frame = row?.recordedFrame ?? row?.frame ?? .zero
                let recover = NativeUIAccessibility.click("files.row.responsiveness-b.md", in: window)
                let recovered = await waitUntil(timeout: 5) {
                    store.fileError == nil
                        && nativeTextViews(in: window.contentView).contains { $0.string == documents[1].1 }
                }
                results["files-list-remains-usable-after-error"] =
                    frame.height > 0 && recover && recovered
                    ? "passed"
                    : "failed: file navigator error recovery; frame=\(frame), clicked=\(recover), selected=\(store.selectedFilePath), recovered=\(recovered)"
            } catch {
                results["files-editor-lifecycle"] = "failed: \(error)"
            }
        }

        private static func closeBoardConversationForToolbar(store: DieterStore, window: NSWindow) async -> Bool {
            if store.selectedCardID == nil, !NativeUIAccessibility.hasOpenInspector(in: window) { return true }
            let visibleClose = await waitUntil(timeout: 5) {
                guard let close = NativeUIAccessibility.find("board.conversation-close", in: window),
                    close.recordedWindow === window, let frame = close.recordedFrame
                else { return false }
                return frame.width > 0 && frame.height > 0 && window.frame.contains(frame)
            }
            guard visibleClose else { return false }
            try? await DieterTaskSleep.milliseconds(350)
            let clicked = NativeUIAccessibility.click("board.conversation-close", in: window)
            let detached = await waitUntil(timeout: 5) {
                store.selectedCardID == nil && !NativeUIAccessibility.hasOpenInspector(in: window)
            }
            return clicked && detached
        }

        private static func runBoardOpeningChecks(
            store: DieterStore, window: NSWindow, board: Dieter_V1_Board,
            project: Dieter_V1_Project, results: inout [String: String], output: URL
        ) async {
            var selection: [Double] = []
            var display: [Double] = []
            for _ in 0..<3 {
                store.openScreens()
                try? await DieterTaskSleep.milliseconds(150)
                let start = Date()
                await store.openBoard(board.id, projectID: project.id)
                let selected = Date()
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                selection.append(selected.timeIntervalSince(start) * 1_000)
                display.append(Date().timeIntervalSince(selected) * 1_000)
                try? await DieterTaskSleep.milliseconds(150)
            }
            results["board-open-selection-ms"] = selection.map { String(format: "%.1f", $0) }.joined(
                separator: ", ")
            results["board-open-layout-display-ms"] = display.map { String(format: "%.1f", $0) }.joined(
                separator: ", ")
            let tables = nativeTables(in: window.contentView)
            let mounted = tables.reduce(0) { count, table in
                var rows = 0
                table.enumerateAvailableRowViews { _, _ in rows += 1 }
                return count + rows
            }
            results["board-mounted-card-rows"] =
                "\(mounted) of \(tables.reduce(0) { $0 + $1.numberOfRows })"
            results["board-virtualized"] =
                tables.reduce(0) { $0 + $1.numberOfRows } == 100 && mounted < 40
                ? "passed" : "failed: offscreen cards were mounted or missing"
            guard let table = tables.first(where: { $0.numberOfRows == 85 }) else {
                results["board-scroll-to-last-card"] = "failed: Todo lane missing"
                return
            }
            table.scrollRowToVisible(84)
            try? await DieterTaskSleep.milliseconds(200)
            let last = BoardCardOrdering.sorted(store.displayedCards.filter { $0.lane == "todo" }).last
            let lastVisible =
                last.map { NativeUIAccessibility.find("card.\($0.id)", in: window) != nil } ?? false
            results["board-scroll-to-last-card"] =
                lastVisible ? "passed" : "failed: last card unavailable"
            capture(window, to: output.appending(path: "02-board-scrolled-to-last.png"))
            if let last {
                let clicked = NativeUIAccessibility.click("card.\(last.id)", in: window)
                let opened = await NativeUIAccessibility.wait { store.selectedCardID == last.id }
                results["board-scrolled-card-click"] =
                    clicked && opened ? "passed" : "failed: recycled card opened the wrong conversation"
                store.closeConversation()
            }
            table.scrollRowToVisible(0)
            try? await DieterTaskSleep.milliseconds(200)
            capture(window, to: output.appending(path: "03-board-returned-to-top.png"))
        }

        private static func runNavigationResponsivenessChecks(
            store: DieterStore, window: NSWindow,
            board: Dieter_V1_Board, project: Dieter_V1_Project, results: inout [String: String],
            output: URL
        ) async {
            if NativeUIAccessibility.find("sidebar.board.\(board.id)", in: window) == nil {
                let expanded = NativeUIAccessibility.click(
                    "sidebar.project.\(project.id).toggle", in: window)
                guard expanded,
                    await NativeUIAccessibility.wait(until: {
                        NativeUIAccessibility.find("sidebar.board.\(board.id)", in: window) != nil
                    })
                else {
                    results["navigation-controls"] = "failed: project destinations did not expand"
                    return
                }
                try? await DieterTaskSleep.milliseconds(250)
            }
            let destinations: [(AppSection, String)] = [
                (.board, "sidebar.board.\(board.id)"), (.chats, "sidebar.all-chats"),
                (.files, "sidebar.files.\(project.id)"), (.changes, "sidebar.changes.\(project.id)"),
                (.schedules, "sidebar.schedules.\(project.id)"), (.terminals, "sidebar.terminals"),
                (.settings, "sidebar.settings"), (.screens, "sidebar.screens"),
            ]
            for (section, control) in destinations {
                var samples: [String] = []
                for repetition in 0..<3 {
                    if section == .screens { store.openSettings() } else { store.openScreens() }
                    try? await DieterTaskSleep.milliseconds(300)
                    let probe = NativeUINavigationProbe(window: window, section: section)
                    probe.start()
                    let clicked = NativeUIAccessibility.click(control, in: window)
                    // Do not force layout/display or traverse accessibility inside
                    // the measured interval. Let the real event/run loop advance.
                    for _ in 0..<200 {
                        if probe.firstDrawMS != nil || !clicked { break }
                        try? await DieterTaskSleep.milliseconds(10)
                    }
                    try? await DieterTaskSleep.milliseconds(150)
                    probe.stop()
                    if clicked, store.section == section, let update = probe.firstDrawMS {
                        samples.append(
                            String(
                                format: "event %.1f / draw %.1f / max-gap %.1f ms",
                                probe.mouseDownMS ?? -1, update, probe.maximumMainLoopGapMS))
                    } else {
                        samples.append(
                            "failed: click \(clicked), section \(store.section.rawValue), draw \(probe.firstDrawMS != nil)"
                        )
                    }
                    if repetition == 0 {
                        capture(
                            window, to: output.appending(path: "navigation-\(section.rawValue.lowercased()).png"))
                    }
                }
                results["navigation-\(section.rawValue.lowercased())"] = samples.joined(separator: "; ")
            }
            results["navigation-metric-definition"] =
                "Native click invocation to first destination drawing callback; includes target lookup. Not compositor presentation or data-ready time. Event = mouse-down delivery; max-gap = largest main-run-loop timer interval (8 ms target). Three samples, debug fixture."
        }

        private static func nativeTables(in view: NSView?) -> [NSTableView] {
            guard let view else { return [] }
            return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { nativeTables(in: $0) }
        }

        private static func nativeTextViews(in view: NSView?) -> [NSTextView] {
            guard let view else { return [] }
            return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { nativeTextViews(in: $0) }
        }

        private static func outputDirectory() -> URL {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--ui-smoke-output"),
                arguments.indices.contains(index + 1)
            {
                return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            }
            return URL(filePath: NSTemporaryDirectory()).appending(
                path: "dieter-mac-ui-smoke", directoryHint: .isDirectory)
        }

        private static func offlineTrigger() -> URL? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--ui-smoke-offline-trigger"),
                arguments.indices.contains(index + 1)
            else { return nil }
            return URL(filePath: arguments[index + 1])
        }

        private static func click(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat) {
            NativeUIEventDispatcher.click(window: window, x: x, distanceFromTop: distanceFromTop)
        }

        private static func doubleClickTitleBar(of window: NSWindow) {
            let point = NSPoint(
                x: window.contentLayoutRect.midX,
                y: window.contentLayoutRect.maxY
                    + ((window.frame.height - window.contentLayoutRect.maxY) / 2)
            )
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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
                    // Queue the full gesture so AppKit's local event monitors and
                    // native tracking loop receive the same events as a user click.
                    if let event { NSApp.postEvent(event, atStart: false) }
                }
            }
        }

        private static func captureAppearances(_ window: NSWindow, named name: String, in output: URL)
            async
        {
            let defaults = DieterAppearance.applicationDefaults()
            let original = defaults.string(forKey: DieterAppearance.storageKey)
            for appearance in [DieterAppearance.dark, DieterAppearance.light] {
                defaults.set(appearance.rawValue, forKey: DieterAppearance.storageKey)
                try? await DieterTaskSleep.milliseconds(450)
                let directory = output.appending(
                    path: "appearance-\(appearance.rawValue)", directoryHint: .isDirectory)
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
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @MainActor
    enum NativeUIEventDispatcher {
        static func click(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat, throughApplication: Bool = false) {
            guard let content = window.contentView else { return }
            let contentLocation = contentLocation(
                x: x,
                distanceFromTop: distanceFromTop,
                contentBounds: content.bounds,
                isFlipped: content.isFlipped
            )
            let location = content.convert(contentLocation, to: nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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
                if let event {
                    if throughApplication { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
                }
            }
        }

        nonisolated static func contentLocation(
            x: CGFloat,
            distanceFromTop: CGFloat,
            contentBounds: NSRect,
            isFlipped: Bool
        ) -> NSPoint {
            NSPoint(
                x: x,
                y: isFlipped ? distanceFromTop : contentBounds.height - distanceFromTop
            )
        }
    }
#endif
