import AppKit
import DieterAPI
import Foundation

/// An in-process end-to-end driver for the card-scoped review surface.
///
/// Against the isolated gateway fixture it creates a board card with a
/// worktree workspace, seeds real commits and uncommitted changes through Git,
/// then exercises the redesigned Changes tab: file list, inline and split
/// diffs, the commit list, the merge sheet, the full merge flow (commit →
/// merge → cleanup → card to Done → toast), and the conflict experience.
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
        while !(store.phase.isConnected && !store.projects.isEmpty && store.projects.contains(where: { !store.boards(for: $0.id).isEmpty })) && waited < 30 {
            try? await DieterTaskSleep.seconds(1)
            waited += 1
        }
        guard store.phase.isConnected, let project = store.projects.first,
              let board = store.boards(for: project.id).first else {
            results["connection"] = "failed: fixture project did not become ready (\(store.phase.label))"
            writeReport(results, to: output)
            return
        }
        results["connection"] = "passed"

        var mainWindow: NSWindow?
        for _ in 0..<20 {
            mainWindow = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title == "Dieter" }
                ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width >= 600 && $0.frame.height >= 400 }
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
        await runMergePhase(store: store, window: window, board: board, project: project, results: &results, output: output)
        // Phase B — the blocked path: conflicting histories → conflict UX.
        await runConflictPhase(store: store, window: window, board: board, results: &results, output: output)

        writeReport(results, to: output)
        progress("runner finished", in: output)
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
        results["changeset"] = "\(changes?.files.count ?? 0) files · \(changes?.commits.count ?? 0) commits · dirty=\(store.conversationWorkspace?.dirty == true)"
        results["changeset-check"] = (changes?.files.count ?? 0) >= 4 && (changes?.commits.count ?? 0) == 2 && store.conversationWorkspace?.dirty == true
            ? "passed"
            : "failed: expected ≥4 files, 2 commits, dirty tree"

        NotificationCenter.default.post(name: selectTabNotification, object: "Changes")
        try? await DieterTaskSleep.seconds(1)
        if let first = changes?.files.first {
            await store.loadConversationDiff(path: first.path)
        }
        try? await DieterTaskSleep.milliseconds(600)
        capture(window, to: output.appending(path: "01-changes-inline.png"))

        UserDefaults.standard.set("Split", forKey: "DieterDiffViewMode")
        try? await DieterTaskSleep.milliseconds(800)
        capture(window, to: output.appending(path: "02-changes-split.png"))
        UserDefaults.standard.set("Inline", forKey: "DieterDiffViewMode")

        if let commit = changes?.commits.first {
            await store.loadConversationDiff(path: "", commitSHA: commit.sha)
            try? await DieterTaskSleep.milliseconds(600)
            capture(window, to: output.appending(path: "03-commit-diff.png"))
        }

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
        results["merge-flow"] = merged ? "passed" : "failed: \(store.workspaceError ?? store.gitOperation?.error ?? "unknown")"
        try? await DieterTaskSleep.milliseconds(700)
        capture(window, to: output.appending(path: "05-merged-toast.png"))
        results["merge-toast"] = store.workspaceToast != nil ? "passed" : "failed: no toast after merge"

        let head = git(["log", "-1", "--pretty=%s"], in: project.path)
        results["base-head"] = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        results["base-head-check"] = head.output.contains(title) ? "passed" : "failed: base branch head is not the squash commit"

        try? await DieterTaskSleep.seconds(1)
        let lane = store.state.cards.first { $0.id == card.id }?.lane ?? ""
        results["card-lane"] = lane == "done" ? "passed" : "failed: lane is \(lane)"
    }

    // MARK: Phase B

    private static func runConflictPhase(
        store: DieterStore,
        window: NSWindow,
        board: Dieter_V1_Board,
        results: inout [String: String],
        output: URL
    ) async {
        guard let card = await createWorktreeCard(store: store, board: board, title: "Conflicting transcript fix", output: output) else {
            results["conflict-card"] = "failed: card did not become server-backed"
            return
        }
        guard let workspace = await provisionWorkspace(store: store, output: output) else {
            results["conflict-workspace"] = "failed: worktree was not provisioned"
            return
        }

        // The same README line diverges on both sides of the merge.
        let readme = workspace.path + "/README.md"
        try? "# Isolated E2E\n\nWorktree rewrite of the introduction.\n".write(toFile: readme, atomically: true, encoding: .utf8)
        git(["add", "-A"], in: workspace.path)
        let worktreeCommit = git(["commit", "-m", "rewrite introduction in worktree"], in: workspace.path)
        progress("worktree commit \(worktreeCommit.status): \(worktreeCommit.output)", in: output)

        guard let project = store.projects.first else { return }
        try? "# Isolated E2E\n\nMain rewrote the introduction differently.\n".write(toFile: project.path + "/README.md", atomically: true, encoding: .utf8)
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
               GitOperationStatus.terminal(operation.status) || operation.status == "waiting_for_resolution" { break }
            try? await DieterTaskSleep.milliseconds(500)
            waited += 1
        }
        let operation = store.gitOperation
        results["conflict-update"] = operation?.status == "waiting_for_resolution"
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
            _ = await store.startGitOperation(.abortConflict, parameters: ["conflicted_operation_id": operation?.id ?? ""])
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

        try? "# Isolated E2E\n\nChats now fold to five per project.\n".write(toFile: path + "/README.md", atomically: true, encoding: .utf8)
        try? "Reviewed the fold behavior by hand.\n".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
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
        return URL(filePath: NSTemporaryDirectory()).appending(path: "dieter-workspace-ui-smoke", directoryHint: .isDirectory)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
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
