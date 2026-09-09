#if DIETER_UI_SMOKE
    import AppKit
    import DieterAPI
    import Foundation

    /// An in-process end-to-end driver for card-scoped worktree review and the
    /// project-scoped local Changes surface.
    ///
    /// Against the isolated gateway fixture it creates a board card with a
    /// worktree workspace, seeds real commits and uncommitted changes through Git,
    /// then exercises the redesigned Changes tab: file list, inline and split
    /// diffs, the merge sheet, the full merge flow (commit → merge → cleanup
    /// → card to Done → toast), and the conflict experience. It also drives
    /// project-checkout staging, staged-only commit, and safe discard semantics.
    @MainActor
    enum WorkspaceUISmokeRunner {
        static let selectTabNotification = Notification.Name("dieter.smoke.select-tab")
        static let openMergeSheetNotification = Notification.Name("dieter.smoke.open-merge-sheet")
        static let closeMergeSheetNotification = Notification.Name("dieter.smoke.close-merge-sheet")

        static func run(store: DieterStore) async {
            let output = outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var results: [String: String] = [:]

            progress("runner started, phase \(store.phase.label)", in: output)
            var waited = 0
            while !(store.phase.isConnected && !store.projects.isEmpty
                && store.projects.contains(where: { !store.boards(for: $0.id).isEmpty })) && waited < 30
            {
                try? await DieterTaskSleep.seconds(1)
                waited += 1
            }
            guard store.phase.isConnected, let project = store.projects.first,
                let board = store.boards(for: project.id).first
            else {
                results["connection"] = "failed: fixture project did not become ready (\(store.phase.label))"
                writeReport(results, to: output)
                return
            }
            results["connection"] = "passed"

            var mainWindow: NSWindow?
            for _ in 0..<20 {
                mainWindow =
                    NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title == "Dieter" }
                    ?? NSApp.windows.first {
                        $0.isVisible && $0.contentView != nil && $0.frame.width >= 600 && $0.frame.height >= 400
                    }
                if mainWindow != nil { break }
                try? await DieterTaskSleep.milliseconds(500)
            }
            guard let window = mainWindow else {
                results["window"] = "failed: Dieter window not found"
                writeReport(results, to: output)
                return
            }
            // Wide enough that the board's conversation pane clears the review
            // surface's compact breakpoint and shows navigator + diff side by side.
            window.setContentSize(NSSize(width: 1_920, height: 1_000))
            window.center()
            window.makeKeyAndOrderFront(nil)
            UserDefaults.standard.set(Double(720), forKey: "dieter.conversationPaneWidth")

            store.selectedProjectID = project.id
            store.selectedBoardID = board.id

            // Phase A — the happy path: seed → review → merge into base.
            await runMergePhase(
                store: store, window: window, board: board, project: project, results: &results, output: output)
            // Phase B — the blocked path: conflicting histories → conflict UX.
            await runConflictPhase(store: store, window: window, board: board, results: &results, output: output)
            // Phase C — shared project checkout: inspect → stage → commit → discard.
            await runProjectChangesPhase(
                store: store, window: window, project: project, results: &results, output: output)

            await runProjectDesignPhase(
                store: store, window: window, project: project, results: &results, output: output)
            writeReport(results, to: output)
            progress("runner finished", in: output)
        }

        /// A richer real-Git fixture exercises the reference layout, including a
        /// file with staged and unstaged edits and two distinct diff hunks.
        private static func runProjectDesignPhase(
            store: DieterStore, window: NSWindow, project: Dieter_V1_Project,
            results: inout [String: String], output: URL
        ) async {
            let model = store.projectChanges
            let path = project.path
            let folder = """
                import SwiftUI

                struct ChatFolder: View {
                    let chats: [Chat]
                    @State private var expanded = false

                    var body: some View {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(chats) { chat in
                                ChatRow(chat: chat)
                            }
                        }
                    }
                }
                """
            try? FileManager.default.createDirectory(atPath: path + "/web/Legacy", withIntermediateDirectories: true)
            try? folder.write(toFile: path + "/web/ChatFolder.swift", atomically: true, encoding: .utf8)
            try? "// Previous chat list\n".write(
                toFile: path + "/web/Legacy/OldChatList.swift", atomically: true, encoding: .utf8)
            git(["add", "-A"], in: path)
            git(["commit", "-m", "Prepare Changes design fixture"], in: path)
            let staged = folder.replacingOccurrences(
                of: "    @State",
                with:
                    "    private let foldThreshold = 5\n    private var visible: [Chat] {\n        expanded ? chats : Array(chats.prefix(foldThreshold))\n    }\n\n    @State"
            )
            try? staged.write(toFile: path + "/web/ChatFolder.swift", atomically: true, encoding: .utf8)
            git(["add", "web/ChatFolder.swift"], in: path)
            let edited = staged.replacingOccurrences(of: "ForEach(chats)", with: "ForEach(visible)")
                .replacingOccurrences(
                    of: "        }\n    }\n}",
                    with:
                        "            if chats.count > foldThreshold {\n                ShowMoreRow(count: chats.count - foldThreshold) { expanded.toggle() }\n            }\n        }\n    }\n}"
                )
            try? edited.write(toFile: path + "/web/ChatFolder.swift", atomically: true, encoding: .utf8)
            try? "# Isolated E2E\n\nChats fold to five per project.\n".write(
                toFile: path + "/README.md", atomically: true, encoding: .utf8)
            try? "Review keyboard navigation and expanded chat rows.\n".write(
                toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: path + "/web/Legacy/OldChatList.swift")
            try?
                "import SwiftUI\n\nstruct ShowMoreRow: View {\n    let count: Int\n    let action: () -> Void\n    var body: some View { Button(\"Show more\", action: action) }\n}\n"
                .write(toFile: path + "/web/ShowMoreRow.swift", atomically: true, encoding: .utf8)
            window.setContentSize(NSSize(width: 1_440, height: 900))
            window.center()
            store.themeSelection.appearance = .dark
            let refreshed = await NativeUIAccessibility.wait {
                model.changes?.files.first(where: { $0.path == "web/ChatFolder.swift" }).map {
                    $0.staged && $0.unstaged
                } == true
                    && model.changes?.files.first(where: { $0.path == "web/Legacy/OldChatList.swift" })?.worktreeStatus
                        == "deleted"
                    && !model.busy
            }
            let selected = NativeUIAccessibility.click("project-changes.unstaged.web/ChatFolder.swift", in: window)
            _ = NativeUIAccessibility.click("project-changes.diff-mode", in: window, horizontalFraction: 0.75)
            let visible = await NativeUIAccessibility.wait {
                model.diff?.path == "web/ChatFolder.swift" && model.diff?.section == "unstaged"
                    && NativeUISmokeTargets.diffSplit == true
            }
            _ = NativeUIAccessibility.click("project-changes.commit-subject", in: window)
            await NativeUIAccessibility.type("Fold chats to five per project", in: window)
            _ = NativeUIAccessibility.click("project-changes.commit-body", in: window)
            await NativeUIAccessibility.type("Keep projects compact and make every chat reachable.", in: window)
            _ = NativeUIAccessibility.click("project-changes.unstaged.web/ChatFolder.swift", in: window)
            try? await DieterTaskSleep.milliseconds(300)
            capture(window, to: output.appending(path: "11-design-dark-split.png"))
            let hunkID = UnifiedDiffParser.parse(model.diff?.patch ?? "").first { $0.kind == .hunk }?.id ?? -1
            let hunkTarget = "workspace-diff.hunk.\(hunkID)"
            let hunkBefore = NativeUIAccessibility.find(hunkTarget, in: window)?.recordedFrame
            let scrolled = NativeUIAccessibility.scrollHorizontally("project-changes.diff", in: window, delta: -220)
            let offsetChanged = await NativeUIAccessibility.wait {
                (NativeUIAccessibility.horizontalScrollView("project-changes.diff", in: window)?.contentView.bounds
                    .origin.x ?? 0) > 50
            }
            try? await DieterTaskSleep.milliseconds(200)
            capture(window, to: output.appending(path: "11a-design-horizontal-scroll.png"))
            let hunkAfter = NativeUIAccessibility.find(hunkTarget, in: window)?.recordedFrame
            let pinned = hunkBefore != nil && hunkAfter != nil && abs(hunkBefore!.minX - hunkAfter!.minX) < 2
            results["project-split-horizontal-scroll"] =
                scrolled && offsetChanged && pinned
                ? "passed" : "failed: long split lines did not scroll with pinned headers"
            _ = NativeUIAccessibility.scrollHorizontally("project-changes.diff", in: window, delta: 220)
            results["project-design-mixed-staging"] =
                refreshed && selected && visible ? "passed" : "failed: mixed staged and working-tree edits unavailable"
            _ = NativeUIAccessibility.click("project-changes.staged.web/ChatFolder.swift", in: window)
            let stagedVisible = await NativeUIAccessibility.wait {
                model.diff?.section == "staged" && NativeUISmokeTargets.diffText.contains("private let foldThreshold")
            }
            capture(window, to: output.appending(path: "12-design-staged.png"))
            results["project-design-staged-diff"] =
                stagedVisible ? "passed" : "failed: staged content did not match the index"
            store.themeSelection.appearance = .light
            _ = await NativeUIAccessibility.wait {
                window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            }
            try? await DieterTaskSleep.milliseconds(300)
            capture(window, to: output.appending(path: "13-design-light.png"))
            store.themeSelection.appearance = .dark
            _ = await NativeUIAccessibility.wait {
                window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            _ = NativeUIAccessibility.click("project-changes.unstaged.web/ChatFolder.swift", in: window)
            _ = NativeUIAccessibility.click("project-changes.diff-mode", in: window, horizontalFraction: 0.25)
            _ = await NativeUIAccessibility.wait {
                NativeUISmokeTargets.diffSplit == false && model.diff?.section == "unstaged"
            }
            capture(window, to: output.appending(path: "14-design-inline.png"))
            window.setContentSize(NSSize(width: 1_080, height: 680))
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("project-changes.back", in: window) != nil
            }
            let back = NativeUIAccessibility.click("project-changes.back", in: window)
            let composerVisible = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("project-changes.commit-subject", in: window) != nil
            }
            results["project-inline-draft-persists"] =
                back && composerVisible && model.commitSubject == "Fold chats to five per project"
                    && model.commitBody == "Keep projects compact and make every chat reachable."
                ? "passed" : "failed: inline draft or compact back navigation lost"
            capture(window, to: output.appending(path: "15-design-compact-composer.png"))
        }

        // MARK: Phase A

        private static func runMergePhase(
            store: DieterStore,
            window: NSWindow,
            board: Dieter_V1_Board,
            project: Dieter_V1_Project,
            results: inout [String: String],
            output: URL
        ) async {
            let title = "Fold chats to five per project"
            guard let card = await createWorktreeCard(store: store, board: board, title: title, output: output) else {
                results["card"] = "failed: card did not become server-backed"
                return
            }
            results["card"] = card.id

            guard let workspace = await provisionWorkspace(store: store, output: output) else {
                results["workspace"] = "failed: worktree was not provisioned (\(store.workspaceError ?? "no error"))"
                return
            }
            results["workspace"] = "\(workspace.mode) · \(workspace.state) · \(workspace.branch)"

            seedReviewContent(at: workspace.path)
            await store.loadWorkspaceSurface()
            try? await DieterTaskSleep.seconds(1)

            let changes = store.conversationChangeset
            results["changeset"] =
                "\(changes?.files.count ?? 0) local files · dirty=\(store.conversationWorkspace?.dirty == true)"
            results["changeset-check"] =
                (changes?.files.count ?? 0) >= 2 && (changes?.commits.isEmpty == true)
                    && store.conversationWorkspace?.dirty == true
                ? "passed"
                : "failed: expected local-only files, no commit history, and a dirty tree"

            _ = NativeUIAccessibility.click("conversation-tab-changes", in: window)
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("changes.file.README.md", in: window) != nil
            }
            _ = NativeUIAccessibility.click("changes.file.README.md", in: window)
            let inlineVisible = await NativeUIAccessibility.wait {
                store.conversationDiff?.path == "README.md"
                    && NativeUIAccessibility.containsText("Chats now fold", in: window)
            }
            results["inline-diff-visible"] = inlineVisible ? "passed" : "failed: selected diff did not render"
            capture(window, to: output.appending(path: "01-changes-inline.png"))
            _ = NativeUIAccessibility.click("changes.view-mode-split", in: window)
            let splitVisible = await NativeUIAccessibility.wait {
                UserDefaults.standard.string(forKey: "DieterDiffViewMode") == "Split"
                    && NativeUISmokeTargets.diffSplit == true
                    && NativeUIAccessibility.containsText("Chats now fold", in: window)
            }
            results["split-diff-visible"] = splitVisible ? "passed" : "failed: split diff did not render"
            capture(window, to: output.appending(path: "02-changes-split.png"))
            _ = NativeUIAccessibility.click("changes.view-mode-inline", in: window)

            NotificationCenter.default.post(name: openMergeSheetNotification, object: nil)
            let mergeSheet = await waitForSheet(of: window)
            captureSheet(mergeSheet, to: output.appending(path: "04-merge-sheet.png"))
            results["merge-sheet"] = mergeSheet != nil ? "passed" : "failed: merge sheet did not present"
            NotificationCenter.default.post(name: closeMergeSheetNotification, object: nil)
            try? await DieterTaskSleep.milliseconds(600)

            progress("starting merge flow", in: output)
            let merged = await store.performMergeFlow(
                strategy: "squash",
                subject: title,
                body: "Pinned chats stay visible; each project folds to its five most recent.",
                validate: false,
                removeWorkspace: true,
                moveCardToDone: true
            )
            results["merge-flow"] =
                merged ? "passed" : "failed: \(store.workspaceError ?? store.gitOperation?.error ?? "unknown")"
            try? await DieterTaskSleep.milliseconds(700)
            capture(window, to: output.appending(path: "05-merged-toast.png"))
            results["merge-toast"] = store.workspaceToast != nil ? "passed" : "failed: no toast after merge"

            let head = git(["log", "-1", "--pretty=%s"], in: project.path)
            results["base-head"] = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            results["base-head-check"] =
                head.output.contains(title) ? "passed" : "failed: base branch head is not the squash commit"

            try? await DieterTaskSleep.seconds(1)
            let lane = store.state.cards.first { $0.id == card.id }?.lane ?? ""
            results["card-lane"] = lane == "done" ? "passed" : "failed: lane is \(lane)"
        }

        // MARK: Phase C

        private static func runProjectChangesPhase(
            store: DieterStore, window: NSWindow, project: Dieter_V1_Project,
            results: inout [String: String], output: URL
        ) async {
            guard let rpc = store.rpc else { results["project-changes"] = "failed: RPC unavailable"; return }
            try? "# Isolated E2E\n\nProject checkout local edit.\n".write(
                toFile: project.path + "/README.md", atomically: true, encoding: .utf8)
            try? "temporary project note\n".write(
                toFile: project.path + "/project-scratch.txt", atomically: true, encoding: .utf8)
            if NativeUIAccessibility.find("sidebar.changes.\(project.id)", in: window) == nil {
                _ = NativeUIAccessibility.click("sidebar.project.\(project.id).toggle", in: window)
            }
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("sidebar.changes.\(project.id)", in: window) != nil
            }
            let navigated = NativeUIAccessibility.click("sidebar.changes.\(project.id)", in: window)
            let model = store.projectChanges
            let loaded = await NativeUIAccessibility.wait {
                store.section == .changes && model.projectID == project.id && model.changes?.files.count == 2
                    && model.diff != nil && !model.mutationsDisabled
            }
            results["project-navigation"] =
                navigated && loaded ? "passed" : "failed: Changes subnavigation did not load the checkout"
            guard loaded else { capture(window, to: output.appending(path: "08-project-load-failure.png")); return }
            results["project-four-destinations"] =
                [
                    "sidebar.board.\(store.selectedBoardID)", "sidebar.files.\(project.id)",
                    "sidebar.changes.\(project.id)", "sidebar.schedules.\(project.id)",
                ].allSatisfy {
                    NativeUIAccessibility.find($0, in: window) != nil
                } ? "passed" : "failed: expected board, Files, Changes, Schedules"

            _ = NativeUIAccessibility.click("project-changes.unstaged.project-scratch.txt", in: window)
            let scratchVisible = await NativeUIAccessibility.wait {
                model.diff?.path == "project-scratch.txt"
                    && NativeUIAccessibility.containsText("temporary project note", in: window)
            }
            _ = NativeUIAccessibility.click("project-changes.unstaged.README.md", in: window)
            let readmeVisible = await NativeUIAccessibility.wait {
                model.diff?.path == "README.md"
                    && NativeUIAccessibility.containsText("Project checkout local edit", in: window)
            }
            results["project-file-selection"] =
                scratchVisible && readmeVisible ? "passed" : "failed: native selection did not show matching patches"
            NativeUIAccessibility.arrow(down: true, in: window)
            let keyboardDown = await NativeUIAccessibility.wait {
                model.selection?.path == "project-scratch.txt"
                    && NativeUIAccessibility.containsText("temporary project note", in: window)
            }
            NativeUIAccessibility.arrow(down: false, in: window)
            let keyboardUp = await NativeUIAccessibility.wait {
                model.selection?.path == "README.md"
                    && NativeUIAccessibility.containsText("Project checkout local edit", in: window)
            }
            results["project-keyboard-selection"] =
                keyboardDown && keyboardUp ? "passed" : "failed: arrow keys did not select matching diffs"
            capture(window, to: output.appending(path: "08-project-changes.png"))
            let originalTheme = store.themeSelection
            let originalAppearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            store.themeSelection.appearance = .light
            _ = await NativeUIAccessibility.wait {
                window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            }
            capture(window, to: output.appending(path: "08d-project-light.png"))
            store.themeSelection = originalTheme
            _ = await NativeUIAccessibility.wait {
                window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == originalAppearance
            }
            // Native text controls repaint after the appearance transaction commits.
            try? await DieterTaskSleep.milliseconds(200)
            _ = NativeUIAccessibility.click("project-changes.diff-mode", in: window, horizontalFraction: 0.75)
            let projectSplit = await NativeUIAccessibility.wait {
                UserDefaults.standard.string(forKey: "DieterDiffViewMode") == "Split"
                    && NativeUISmokeTargets.diffSplit == true
            }
            results["project-split-rendered"] = projectSplit ? "passed" : "failed: split projection did not render"
            capture(window, to: output.appending(path: "08a-project-split.png"))
            _ = NativeUIAccessibility.click("project-changes.diff-mode", in: window, horizontalFraction: 0.25)

            for (identifier, expectedStaged, key) in [
                ("project-changes.stage-all", 2, "project-stage-all"),
                ("project-changes.unstage-all", 0, "project-unstage-all"),
                ("project-changes.stage.README.md", 1, "project-stage"),
                ("project-changes.unstage.README.md", 0, "project-unstage"),
                ("project-changes.stage-file", 1, "project-restage"),
            ] {
                _ = await NativeUIAccessibility.wait {
                    !model.mutationsDisabled && NativeUIAccessibility.find(identifier, in: window) != nil
                }
                // Let the accepted snapshot's SwiftUI transaction enable and place
                // the next control before delivering its native mouse-down.
                try? await DieterTaskSleep.milliseconds(100)
                let clicked = NativeUIAccessibility.click(identifier, in: window)
                let reconciled = await NativeUIAccessibility.wait {
                    model.stagedFiles.count == expectedStaged && !model.busy && !model.refreshing
                }
                results[key] = clicked && reconciled ? "passed" : "failed: button did not reconcile staging"
                if !clicked || !reconciled { capture(window, to: output.appending(path: key + "-failure.png")); return }
            }
            results["project-selection-follows-stage"] =
                model.selection == .init(path: "README.md", section: "staged")
                ? "passed" : "failed: selected file was lost after staging"
            capture(window, to: output.appending(path: "08b-project-staged.png"))
            _ = NativeUIAccessibility.click("project-changes.commit-subject", in: window)
            await NativeUIAccessibility.type("project checkout smoke", in: window)
            let entered = await NativeUIAccessibility.wait { model.commitSubject == "project checkout smoke" }
            capture(window, to: output.appending(path: "08c-project-commit-composer.png"))
            let committed = entered && NativeUIAccessibility.click("project-changes.commit", in: window)
            let reconciled = await NativeUIAccessibility.wait {
                model.changes?.files.count == 1 && model.changes?.files.first?.path == "project-scratch.txt"
                    && !model.busy
            }
            let head = git(["log", "-1", "--pretty=%s"], in: project.path)
            results["project-commit"] =
                committed && reconciled && head.output.contains("project checkout smoke")
                ? "passed" : "failed: native staged-only commit did not converge"
            guard reconciled else { return }
            _ = await NativeUIAccessibility.wait { window.attachedSheet == nil && !model.mutationsDisabled }
            _ = NativeUIAccessibility.click("project-changes.discard", in: window)
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find(
                    "project-changes.confirm-discard", in: window.attachedSheet ?? window,
                    fallbackLabel: "Discard changes") != nil
            }
            let discarded = NativeUIAccessibility.click(
                "project-changes.confirm-discard", in: window.attachedSheet ?? window, fallbackLabel: "Discard changes")
            let clean = await NativeUIAccessibility.wait {
                model.changes?.files.isEmpty == true
                    && NativeUIAccessibility.find("project-changes.clean", in: window) != nil
            }
            results["project-discard"] =
                discarded && clean ? "passed" : "failed: native discard did not render clean checkout"
            capture(window, to: output.appending(path: "09-project-changes-clean.png"))
            do {
                let changes = try await rpc.changeset(projectID: project.id)
                results["project-changes"] =
                    changes.files.isEmpty && clean ? "passed" : "failed: UI and daemon disagree"
                results["project-branch"] = changes.branch
            } catch { results["project-changes"] = "failed: \(error)" }

            // External edits must appear without a refresh click or view recreation.
            try? "external editor change\n".write(
                toFile: project.path + "/external.txt", atomically: true, encoding: .utf8)
            let external = await NativeUIAccessibility.wait {
                model.changes?.files.contains(where: { $0.path == "external.txt" }) == true
            }
            results["project-external-refresh"] = external ? "passed" : "failed: external edit remained invisible"
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("project-changes.unstaged.external.txt", in: window) != nil
            }
            _ = NativeUIAccessibility.click("project-changes.unstaged.external.txt", in: window)
            _ = await NativeUIAccessibility.wait {
                model.selection?.path == "external.txt"
                    && NativeUIAccessibility.containsText("external editor change", in: window)
            }
            window.setContentSize(NSSize(width: 1_080, height: 680))
            _ = await NativeUIAccessibility.wait {
                NativeUIAccessibility.find("project-changes.unstaged.external.txt", in: window) != nil
                    || NativeUIAccessibility.find("project-changes.back", in: window) != nil
            }
            if NativeUIAccessibility.find("project-changes.unstaged.external.txt", in: window) != nil {
                _ = NativeUIAccessibility.click("project-changes.unstaged.external.txt", in: window)
            }
            let compact = await NativeUIAccessibility.wait {
                NativeUIAccessibility.containsText("external editor change", in: window)
                    && NativeUIAccessibility.find("project-changes.back", in: window) != nil
            }
            results["project-compact-diff"] = compact ? "passed" : "failed: selected diff lost on resize"
            capture(window, to: output.appending(path: "10-project-compact.png"))
        }

        private enum WorkspaceSmokeFailure: Error {
            case operation(Dieter_V1_GitOperation)
            case timeout
        }

        // MARK: Phase B

        private static func runConflictPhase(
            store: DieterStore,
            window: NSWindow,
            board: Dieter_V1_Board,
            results: inout [String: String],
            output: URL
        ) async {
            guard
                let card = await createWorktreeCard(
                    store: store, board: board, title: "Conflicting transcript fix", output: output)
            else {
                results["conflict-card"] = "failed: card did not become server-backed"
                return
            }
            guard let workspace = await provisionWorkspace(store: store, output: output) else {
                results["conflict-workspace"] = "failed: worktree was not provisioned"
                return
            }

            // The same README line diverges on both sides of the merge.
            let readme = workspace.path + "/README.md"
            try? "# Isolated E2E\n\nWorktree rewrite of the introduction.\n".write(
                toFile: readme, atomically: true, encoding: .utf8)
            git(["add", "-A"], in: workspace.path)
            let worktreeCommit = git(["commit", "-m", "rewrite introduction in worktree"], in: workspace.path)
            progress("worktree commit \(worktreeCommit.status): \(worktreeCommit.output)", in: output)

            guard let project = store.projects.first else { return }
            try? "# Isolated E2E\n\nMain rewrote the introduction differently.\n".write(
                toFile: project.path + "/README.md", atomically: true, encoding: .utf8)
            git(["add", "-A"], in: project.path)
            let mainCommit = git(["commit", "-m", "rewrite introduction on main"], in: project.path)
            progress("main commit \(mainCommit.status): \(mainCommit.output)", in: output)
            await store.loadWorkspaceSurface()

            progress("starting update to provoke conflict", in: output)
            guard await store.startGitOperation(.update, parameters: ["fetch": "false", "validate": "false"]) else {
                results["conflict-update"] = "failed: update did not start (\(store.workspaceError ?? ""))"
                return
            }
            var waited = 0
            while waited < 30 {
                if let operation = store.gitOperation,
                    GitOperationStatus.terminal(operation.status) || operation.status == "waiting_for_resolution"
                {
                    break
                }
                try? await DieterTaskSleep.milliseconds(500)
                waited += 1
            }
            let operation = store.gitOperation
            results["conflict-update"] =
                operation?.status == "waiting_for_resolution"
                ? "passed"
                : "failed: update finished as \(operation?.status ?? "missing") (\(operation?.error ?? "no error"))"
            results["conflict-files"] = "\(operation?.conflicts.count ?? 0) conflicting file(s)"

            await store.loadWorkspaceSurface()
            NotificationCenter.default.post(name: selectTabNotification, object: "Changes")
            try? await DieterTaskSleep.seconds(1)
            capture(window, to: output.appending(path: "06-conflict-banner.png"))

            NotificationCenter.default.post(name: openMergeSheetNotification, object: nil)
            let conflictSheet = await waitForSheet(of: window)
            captureSheet(conflictSheet, to: output.appending(path: "07-merge-sheet-conflict.png"))
            results["conflict-sheet"] = conflictSheet != nil ? "passed" : "failed: conflict sheet did not present"
            NotificationCenter.default.post(name: closeMergeSheetNotification, object: nil)
            try? await DieterTaskSleep.milliseconds(600)

            // Restore a quiet state so the fixture shuts down cleanly.
            if operation?.status == "waiting_for_resolution" {
                _ = await store.startGitOperation(
                    .abortConflict, parameters: ["conflicted_operation_id": operation?.id ?? ""])
                try? await DieterTaskSleep.seconds(2)
            }
            _ = card
        }

        // MARK: Fixture helpers

        private static func createWorktreeCard(
            store: DieterStore,
            board: Dieter_V1_Board,
            title: String,
            output: URL
        ) async -> Dieter_V1_Card? {
            let lane = board.lanes.first { $0.id == "running" }?.id ?? board.lanes.first?.id ?? "todo"
            await store.createConversation(
                title: title,
                prompt: title,
                chat: false,
                provider: "claude-code",
                model: "sonnet",
                effort: "medium",
                deferred: true,
                lane: lane,
                workspace: ConversationWorkspaceDraft(mode: .worktree, branch: "", baseBranch: "main")
            )
            var waited = 0
            while waited < 30 {
                // Match on the fixture project too: the app's persisted sync cache
                // can still hold a same-titled card from an earlier isolated run.
                if let card = store.state.cards.first(where: {
                    $0.title == title && $0.projectID == board.projectID && DieterConversationID.isServerBacked($0.id)
                }) {
                    await store.openConversation(cardID: card.id)
                    return card
                }
                try? await DieterTaskSleep.milliseconds(500)
                waited += 1
            }
            progress("card \(title) never became server-backed", in: output)
            return nil
        }

        private static func provisionWorkspace(store: DieterStore, output: URL) async -> Dieter_V1_Workspace? {
            var waited = 0
            while waited < 45 {
                await store.loadWorkspaceSurface()
                if let workspace = store.conversationWorkspace, workspace.state == "ready", !workspace.path.isEmpty {
                    return workspace
                }
                try? await DieterTaskSleep.seconds(1)
                waited += 1
            }
            return nil
        }

        /// Two commits, one uncommitted modification, and one untracked file — the
        /// mix the reference plates show: committed work plus working changes.
        private static func seedReviewContent(at path: String) {
            let folder = """
                import SwiftUI

                struct ChatFolder: View {
                    let chats: [String]
                    let limit: Int

                    var body: some View {
                        VStack(alignment: .leading) {
                            ForEach(visible, id: \\.self) { chat in
                                Text(chat)
                            }
                            if hidden > 0 {
                                Text("Show \\(hidden) more")
                            }
                        }
                    }

                    private var visible: [String] { Array(chats.prefix(limit)) }
                    private var hidden: Int { max(0, chats.count - limit) }
                }
                """
            try? FileManager.default.createDirectory(atPath: path + "/web", withIntermediateDirectories: true)
            try? folder.write(toFile: path + "/web/ChatFolder.swift", atomically: true, encoding: .utf8)
            git(["add", "-A"], in: path)
            git(["commit", "-m", "scaffold ChatFolder component"], in: path)

            let showMore = """
                import SwiftUI

                struct ShowMoreRow: View {
                    let count: Int
                    let action: () -> Void

                    var body: some View {
                        Button("Show \\(count) more", action: action)
                    }
                }
                """
            try? showMore.write(toFile: path + "/web/ShowMoreRow.swift", atomically: true, encoding: .utf8)
            try? (folder + "\n// Folds each project to its five most recent chats.\n")
                .write(toFile: path + "/web/ChatFolder.swift", atomically: true, encoding: .utf8)
            git(["add", "-A"], in: path)
            git(["commit", "-m", "fold sidebar groups to five recent"], in: path)

            try? "# Isolated E2E\n\nChats now fold to five per project.\n".write(
                toFile: path + "/README.md", atomically: true, encoding: .utf8)
            try? "Reviewed the fold behavior by hand.\n".write(
                toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
        }

        @discardableResult
        private static func git(_ arguments: [String], in directory: String) -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (1, "\(error)") }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }

        // MARK: Output

        static func progress(_ message: String, in directory: URL) {
            let url = directory.appending(path: "progress.log")
            let line = "\(Date()) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }

        static func outputDirectory() -> URL {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--ui-smoke-output"), arguments.indices.contains(index + 1) {
                return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            }
            return URL(filePath: NSTemporaryDirectory()).appending(
                path: "dieter-workspace-ui-smoke", directoryHint: .isDirectory)
        }

        private static func capture(_ window: NSWindow, to url: URL) {
            guard let view = window.contentView,
                let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url, options: .atomic)
        }

        private static func waitForSheet(of window: NSWindow) async -> NSWindow? {
            for _ in 0..<12 {
                if let sheet = window.attachedSheet ?? NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) {
                    try? await DieterTaskSleep.milliseconds(400)
                    return sheet
                }
                try? await DieterTaskSleep.milliseconds(250)
            }
            return nil
        }

        private static func captureSheet(_ sheet: NSWindow?, to url: URL) {
            guard let view = sheet?.contentView,
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
