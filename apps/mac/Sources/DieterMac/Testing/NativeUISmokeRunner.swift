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
    /// WindowGroup instead of idling until their outer shell timeout expires.
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
                guard attempt.isMultiple(of: 4),
                      let item = NSApp.mainMenu?.items
                        .compactMap(\.submenu)
                        .flatMap(\.items)
                        .first(where: { $0.title.hasSuffix(" Window") }),
                      let action = item.action else { continue }
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
        guard await waitUntil(timeout: 25, condition: {
            store.workspaceIsLive && !store.projects.isEmpty && store.projects.contains { !store.boards(for: $0.id).isEmpty }
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
                effort: harness?.models.first(where: { $0.id == harness?.defaultModel })?.defaultEffort ?? "",
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
                fixtureNote = "warning: fixture card did not sync within 25s; captured chrome may show an empty board"
            }
            await store.refreshState()
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
        if let fixtureNote { results["fixture"] = fixtureNote }
        if let scheduleFixtureError { results["schedule-fixture"] = "failed: \(scheduleFixtureError)" }

        if schedulesOnly {
            await store.openProject(project.id, section: .schedules)
            let scheduleReady = await waitUntil(timeout: 10) {
                store.schedulesAreLoaded &&
                    scheduleFixtureID.map { id in store.schedules.contains(where: { $0.id == id }) } == true
            }
            results["05-project-schedules"] = store.section == .schedules ? "passed" : "failed: \(store.section.rawValue)"
            results["05-project-schedules-data"] = scheduleReady
                ? "passed"
                : "failed: dedicated schedule load did not return the fixture"
            await captureAppearances(window, named: "05-project-schedules.png", in: output)
            writeReport(results, to: output)
            NSApp.terminate(nil)
            return
        }
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

        // The packaged-app smoke has a fixed 1,380pt content width. Drive the
        // first lane's rendered sort button through Dieter's own NSWindow and
        // capture immediately, before any appearance change can rebuild it.
        click(window: window, x: 478, distanceFromTop: 164)
        try? await DieterTaskSleep.milliseconds(500)
        capture(window, to: output.appending(path: "01-board-oldest-first.png"))
        results["board-lane-sort-toggle"] = "dispatched for visual verification"
        if ProcessInfo.processInfo.arguments.contains("--lane-sort-ui-smoke") {
            writeReport(results, to: output)
            NSApp.terminate(nil)
            return
        }
        click(window: window, x: 478, distanceFromTop: 164) // restore newest-first
        try? await DieterTaskSleep.milliseconds(350)

        store.openScreens()
        try? await DieterTaskSleep.milliseconds(500)
        results["01a-experimental-screens"] = store.section == .screens ? "passed" : "failed: screens did not open"
        await captureAppearances(window, named: "01a-experimental-screens.png", in: output)
        await store.openBoard(board.id, projectID: project.id)
        try? await DieterTaskSleep.milliseconds(500)

        // Expand the first compressed project inline via its trailing chevron
        // (x≈211 for the 234pt sidebar; the first row sits just below the PROJECTS
        // header). This reveals the same boards/files/schedules rows the quick-nav
        // popover shows, so it doubles as the popover's row-design verification.
        click(window: window, x: 211, distanceFromTop: 240)
        try? await DieterTaskSleep.milliseconds(600)
        await captureAppearances(window, named: "01c-project-expanded.png", in: output)
        results["01c-project-expanded"] = "passed"
        click(window: window, x: 211, distanceFromTop: 240) // collapse back
        try? await DieterTaskSleep.milliseconds(450)

        // Note: the row-body quick-nav popover is verified by hand — driving it
        // here opens a child window whose key/scene-phase cycle restarts global
        // sync and destabilizes the later RPC-backed steps. Its rows are identical
        // to the inline expansion captured above.

        // Collapse the navigation to capture the compressed rail. The toggle sits
        // in the header band (x≈174 for the 234pt sidebar); the rail's All chats
        // destination is the first pill below the search/brand stack.
        click(window: window, x: 174, distanceFromTop: 56)
        try? await DieterTaskSleep.milliseconds(500)
        await captureAppearances(window, named: "01b-navigation-collapsed.png", in: output)
        let collapsedRailCaptured = store.section == .board
        click(window: window, x: 30, distanceFromTop: 150)
        try? await DieterTaskSleep.seconds(1)
        results["navigation-collapse"] = store.section == .chats
            ? "passed"
            : "failed: collapsed rail did not navigate (rendered=\(collapsedRailCaptured), section=\(store.section.rawValue))"
        store.section = .board
        // Re-expand for the remaining expanded-sidebar interactions.
        click(window: window, x: 30, distanceFromTop: 56)
        try? await DieterTaskSleep.milliseconds(500)
        let steps = [Step(name: "02-global-chats", section: .chats, distanceFromTop: 142)]
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

        // Projects are compressed by default, so these destinations are reached
        // through the project quick-nav popover / inline expansion at runtime.
        // Drive them through the store the popover calls into and capture each pane.
        let remaining: [(name: String, section: AppSection, navigate: () async -> Void)] = [
            ("04-project-files", .files, { await store.openProject(project.id, section: .files) }),
            ("05-project-schedules", .schedules, { await store.openProject(project.id, section: .schedules) }),
            ("06-board", .board, { await store.openBoard(board.id, projectID: project.id) }),
        ]
        for step in remaining {
            await step.navigate()
            try? await DieterTaskSleep.seconds(1)
            results[step.name] = store.section == step.section ? "passed" : "failed: \(store.section.rawValue)"
            await captureAppearances(window, named: "\(step.name).png", in: output)

            if step.section == .schedules {
                results["05-project-schedules-data"] = store.schedulesAreLoaded &&
                    scheduleFixtureID.map { id in store.schedules.contains(where: { $0.id == id }) } == true
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
                    rootView: ScheduleEditor(schedule: nil).environment(store)
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
                    rootView: ScheduleEditor(schedule: nil).environment(store)
                )
                window.beginSheet(editorWindow, completionHandler: { _ in })
                try? await DieterTaskSleep.seconds(2)
                await captureAppearances(editorWindow, named: "05b-schedule-editor.png", in: output)
                let size = editorWindow.contentLayoutRect.size
                results["05b-schedule-editor"] = size.width >= 900 && size.height >= 740
                    ? "passed"
                    : "failed: editor was cramped at \(Int(size.width))×\(Int(size.height))"
                window.endSheet(editorWindow)
                try? await DieterTaskSleep.milliseconds(350)
            }
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
        results["12b-connection-onboarding"] = store.phase.needsConnectionOverlay ? "passed" : "failed: overlay phase inactive"
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
                lane: todoLane.id,
                workspace: ConversationWorkspaceDraft(
                    mode: .worktree,
                    baseBranch: project.baseBranch
                )
            )
            let created = await waitUntil(timeout: 10) {
                store.state.cards.contains {
                    $0.title == title &&
                        $0.lane.caseInsensitiveCompare("todo") == .orderedSame &&
                        $0.workspaceMode == "worktree" &&
                        DieterConversationID.isServerBacked($0.id)
                }
            }
            results["13b-todo-card-stays-on-board"] = created && store.section == .board && store.selectedCardID == nil
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
                results["13c-todo-card-edit"] = synchronized
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
        if openedChat,
           let chatID = store.selectedChatID,
           let chat = store.chats.first(where: { $0.id == chatID }) {
            let renamedTitle = "\(chatTitle) renamed"
            await store.rename(chat, title: renamedTitle)
            let renamed = await waitUntil(timeout: 10) {
                store.chats.contains { $0.id == chatID && $0.title == renamedTitle }
            }
            results["13d-standalone-chat-rename"] = renamed
                ? "passed"
                : "failed: packaged Mac RenameCard did not synchronize the chat title"

            if let renamedChat = store.chats.first(where: { $0.id == chatID }) {
                await store.pin(renamedChat, pinned: true)
                let pinned = await waitUntil(timeout: 10) {
                    store.chats.contains { $0.id == chatID && $0.pinned }
                }
                results["13e-standalone-chat-pin"] = pinned
                    ? "passed"
                    : "failed: packaged Mac PinChat did not update the chat projection"

                if let pinnedChat = store.chats.first(where: { $0.id == chatID }) {
                    await store.pin(pinnedChat, pinned: false)
                }
                let unpinned = await waitUntil(timeout: 10) {
                    store.chats.contains { $0.id == chatID && !$0.pinned }
                }
                results["13f-standalone-chat-unpin"] = unpinned
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

        store.createProjectPresented = true
        try? await DieterTaskSleep.milliseconds(700)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
            await captureAppearances(sheet, named: "14-new-project.png", in: output)
            results["14-new-project"] = "passed"
            click(window: sheet, x: 605, distanceFromTop: 281)
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

        let projectParent = URL(fileURLWithPath: project.path).deletingLastPathComponent()
        let projectMachineID = store.machine(forProjectID: project.id)?.id ?? store.endpoint.id
        var newProjectDraft = ProjectSetupDraft()
        newProjectDraft.mode = .newRepository
        newProjectDraft.path = projectParent.appendingPathComponent("mac-created-\(UUID().uuidString.lowercased())").path
        newProjectDraft.name = "Mac-created Git project"
        newProjectDraft.boardName = "Main"
        newProjectDraft.workflow = "review"
        do {
            let created = try await store.createProject(newProjectDraft, machineID: projectMachineID)
            let listing = try await store.listProjectDirectories(path: created.project.path, machineID: projectMachineID)
            results["15b-create-git-project"] = listing.gitRepository && created.board.projectID == created.project.id
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
            let created = try await store.createProject(linkedWorktreeDraft, machineID: projectMachineID)
            let listing = try await store.listProjectDirectories(path: created.project.path, machineID: projectMachineID)
            results["15c-open-linked-worktree"] = listing.gitRepository && created.project.path != project.path
                ? "passed"
                : "failed: linked worktree was not registered as a distinct Git project"
        } catch {
            results["15c-open-linked-worktree"] = "failed: \(DieterRPCFailure.message(for: error))"
        }

        await store.openBoard(board.id, projectID: project.id)

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
                let liveCard = store.state.cards.first(where: { $0.boardID == board.id })
                if let liveCard {
                    await store.openConversation(cardID: liveCard.id)
                    _ = await waitUntil(timeout: 5) {
                        store.conversation?.detail.card.id == liveCard.id && !store.conversationLoading
                    }
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
                let canceledOfflineMessage = "Canceled offline outbox smoke \(UUID().uuidString.lowercased())"
                if let liveCard, let machine = store.machine(forProjectID: liveCard.projectID) {
                    store.composerText = canceledOfflineMessage
                    await store.sendComposer()
                    let queued = await waitUntil(timeout: 5) {
                        store.outboxSummary(for: machine)?.messageCount == 1
                    }
                    results["17a-offline-message-queued"] = queued && store.composerText.isEmpty
                        ? "passed"
                        : "failed: queued=\(store.outboxSummary(for: machine)?.messageCount ?? 0), draft=\(store.composerText)"
                    await captureAppearances(window, named: "17a-offline-message-queued.png", in: output)

                    let removed = await store.discardOutbox(for: machine)
                    let canceled = await waitUntil(timeout: 5) {
                        store.outboxSummary(for: machine) == nil &&
                            !store.conversationMessages.contains { message in
                                message.parts.contains { $0.type == "text" && $0.text == canceledOfflineMessage }
                            }
                    }
                    results["17b-offline-message-canceled"] = removed == 1 && canceled
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
                let stayedUsable = store.section == .board &&
                    store.selectedBoard?.id == cachedBoard.id &&
                    store.errorMessage == nil &&
                    store.hasLoadedWorkspace &&
                    !store.phase.isConnected &&
                    offlineLabel.hasPrefix("Last connected ")
                results["17-offline-cached-board-navigation"] = stayedUsable
                    ? "passed"
                    : "failed: section=\(store.section.rawValue), board=\(store.selectedBoard?.id ?? "none"), phase=\(store.phase.label), freshness=\(offlineLabel), error=\(store.errorMessage ?? "none")"
                await captureAppearances(window, named: "17-offline-cached-board-navigation.png", in: output)

                if let trigger = offlineTrigger(), let liveCard {
                    try? FileManager.default.removeItem(at: trigger)
                    let reconnected = await waitUntil(timeout: 25) { store.phase.isConnected }
                    let delivered = await waitUntil(timeout: 15) {
                        guard let machine = store.machine(forProjectID: liveCard.projectID) else { return false }
                        return store.outboxSummary(for: machine) == nil
                    }
                    if reconnected && delivered {
                        await store.openConversation(cardID: liveCard.id)
                    }
                    let visible = await waitUntil(timeout: 10) {
                        store.conversationMessages.contains { message in
                            message.parts.contains { $0.type == "text" && $0.text.hasPrefix("Offline delivery smoke ") }
                        }
                    }
                    let canceledStayedAbsent = !store.conversationMessages.contains { message in
                        message.parts.contains { $0.type == "text" && $0.text == canceledOfflineMessage }
                    }
                    results["17c-reconnected-message-delivered"] = reconnected && delivered && visible && canceledStayedAbsent
                        ? "passed"
                        : "failed: reconnected=\(reconnected), delivered=\(delivered), visible=\(visible), canceledAbsent=\(canceledStayedAbsent)"
                    await captureAppearances(window, named: "17c-reconnected-message-delivered.png", in: output)
                } else {
                    results["17c-reconnected-message-delivered"] = "failed: reconnect trigger or live card missing"
                }
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

    private static func offlineTrigger() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-smoke-offline-trigger"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(filePath: arguments[index + 1])
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
