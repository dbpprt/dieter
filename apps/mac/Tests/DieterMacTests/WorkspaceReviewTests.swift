import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private func parsed(_ patch: String) -> [UnifiedDiffLine] {
    UnifiedDiffParser.parse(patch)
}

@Test func diffDisplayDropsHeaderNoiseAndKeepsChanges() {
    let rows = WorkspaceDiffDisplay.inlineRows(parsed("""
    diff --git a/a.swift b/a.swift
    index 123..456 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,3 +1,3 @@
     context
    -old
    +new
    """))

    let hunks = rows.filter { if case .hunk = $0 { true } else { false } }
    let lines = rows.compactMap { if case .line(let line) = $0 { line } else { nil } }
    #expect(hunks.count == 1)
    #expect(lines.map(\.kind) == [.context, .deletion, .addition])
    #expect(!lines.contains { $0.kind == .header })
}

@Test func diffDisplayCountsUnchangedLinesBetweenHunks() {
    let rows = WorkspaceDiffDisplay.inlineRows(parsed("""
    @@ -10,4 +10,5 @@ func first()
     context
    -old
    +new
    +extra
     tail
    @@ -228,3 +229,4 @@ func second()
     context
    +added
     tail
    """))

    let skips = rows.compactMap { if case .hunk(_, _, let skipped) = $0 { skipped } else { nil } }
    #expect(skips.count == 2)
    #expect(skips[0] == 0)
    // Previous hunk covers old lines 10..<14; the next opens at 228.
    #expect(skips[1] == 228 - 14)
}

@Test func diffDisplayFoldsLongContextRuns() {
    let context = (1...40).map { "line \($0)" }.joined(separator: "\n ")
    let rows = WorkspaceDiffDisplay.inlineRows(parsed("""
    @@ -1,41 +1,41 @@
     \(context)
    -old
    +new
    """))

    let folds = rows.compactMap { row -> (count: Int, lines: [UnifiedDiffLine])? in
        if case .fold(_, let count, let lines, _) = row { (count, lines) } else { nil }
    }
    #expect(folds.count == 1)
    // 40 context lines with a 5-line margin kept on each side.
    #expect(folds[0].count == 30)
    #expect(folds[0].lines.count == 30)
    let visibleContext = rows.compactMap { if case .line(let line) = $0, line.kind == .context { line } else { nil } }
    #expect(visibleContext.count == 10)
}

@Test func diffDisplayKeepsShortContextUnfolded() {
    let rows = WorkspaceDiffDisplay.inlineRows(parsed("""
    @@ -1,6 +1,6 @@
     one
     two
     three
    -old
    +new
     four
    """))

    #expect(!rows.contains { if case .fold = $0 { true } else { false } })
}

@Test func splitRowsPairDeletionsWithAdditions() {
    let rows = WorkspaceDiffDisplay.splitRows(parsed("""
    @@ -1,3 +1,4 @@
     context
    -removed
    +replaced
    +added
     tail
    """))

    let pairs = rows.compactMap { if case .pair(let pair) = $0 { pair } else { nil } }
    #expect(pairs.count == 4)
    // Context mirrors both sides.
    #expect(pairs[0].old?.kind == .context && pairs[0].new?.kind == .context)
    // The deletion pairs with the first addition.
    #expect(pairs[1].old?.kind == .deletion && pairs[1].new?.kind == .addition)
    // The surplus addition renders one-sided.
    #expect(pairs[2].old == nil && pairs[2].new?.kind == .addition)
    #expect(pairs[3].old?.kind == .context)
}

@Test func parserClassifiesCommitMetadataAndResetsBetweenFiles() {
    let lines = parsed("""
    diff --git a/one.txt b/one.txt
    new file mode 100644
    index 0000000..5626abf
    --- /dev/null
    +++ b/one.txt
    @@ -0,0 +1 @@
    +one
    diff --git a/two.txt b/two.txt
    new file mode 100644
    index 0000000..f719efd
    --- /dev/null
    +++ b/two.txt
    @@ -0,0 +1 @@
    +two
    """)

    // Every metadata line stays out of the content stream for both files.
    #expect(lines.filter { $0.kind == .header }.count == 10)
    #expect(lines.filter { $0.kind == .addition }.count == 2)
    #expect(!lines.contains { $0.kind == .context })
    #expect(lines.last?.newLine == 1)
}

@Test func diffDisplayEmitsFileRowsForWholeCommitPatches() {
    let lines = parsed("""
    diff --git a/one.txt b/one.txt
    @@ -0,0 +1 @@
    +one
    diff --git a/two.txt b/two.txt
    @@ -0,0 +1 @@
    +two
    """)

    let rows = WorkspaceDiffDisplay.inlineRows(lines, fileRows: true)
    let files = rows.compactMap { if case .file(_, let path) = $0 { path } else { nil } }
    #expect(files == ["one.txt", "two.txt"])
    let skips = rows.compactMap { if case .hunk(_, _, let skipped) = $0 { skipped } else { nil } }
    // Gap math never spans file boundaries.
    #expect(skips == [0, 0])
    #expect(WorkspaceDiffDisplay.inlineRows(lines).allSatisfy { if case .file = $0 { false } else { true } })
}

@Test func hunkDisplayTextKeepsFunctionContext() {
    #expect(WorkspaceDiffDisplay.hunkDisplayText("@@ -1284,9 +1284,16 @@ function ChatSidebar({ projects })")
        == "@@ -1284,9 +1284,16 @@ function ChatSidebar({ projects })")
    #expect(WorkspaceDiffDisplay.hunkDisplayText("@@ -1,3 +1,4 @@") == "@@ -1,3 +1,4 @@")
    #expect(WorkspaceDiffDisplay.hunkSummary("@@ -1284,9 +1284,16 @@ fn")?.oldCount == 9)
    #expect(WorkspaceDiffDisplay.hunkSummary("@@ -5 +6 @@")?.oldCount == 1)
}

@Test func mergeReadinessReportsCleanWorkspace() {
    let readiness = WorkspaceMergeReadiness.evaluate(
        workspaceState: "ready",
        baseBranch: "main",
        behind: 0,
        dirty: false,
        conflictedFiles: 0,
        lastValidation: ("go test", true, "41s ago")
    )

    #expect(!readiness.blocked)
    #expect(!readiness.commitsFirst)
    #expect(readiness.items.map(\.id) == ["conflicts", "validation"])
    #expect(readiness.items[0].text == "No conflicts with main")
}

@Test func mergeReadinessBlocksOnConflictsAndNotesDirtyTree() {
    let readiness = WorkspaceMergeReadiness.evaluate(
        workspaceState: "conflicted",
        baseBranch: "main",
        behind: 2,
        dirty: true,
        conflictedFiles: 2,
        lastValidation: nil
    )

    #expect(readiness.blocked)
    #expect(readiness.commitsFirst)
    #expect(readiness.items[0].text == "2 files conflict with main")
    #expect(readiness.items.contains { $0.id == "behind" })
    #expect(readiness.items.contains { $0.id == "uncommitted" })
}

@Test func pullRequestPresentationMapsOpenRunningChecks() {
    let presentation = PullRequestPresentation.from(
        state: "open",
        draft: false,
        mergeable: true,
        checksState: "running",
        reviewDecision: "review_required",
        reviewer: "dbpprt"
    )

    #expect(presentation.stateLabel == "Open")
    #expect(presentation.mergeBlockedReason == "waiting on checks")
    #expect(presentation.signals.contains { $0.text == "checks running" })
    #expect(presentation.signals.contains { $0.text == "review requested · @dbpprt" })
    #expect(!presentation.canAskAgent)
}

@Test func pullRequestPresentationAsksAgentOnFailure() {
    let failing = PullRequestPresentation.from(
        state: "open", draft: false, mergeable: true,
        checksState: "failed", reviewDecision: "changes_requested"
    )
    #expect(failing.canAskAgent)
    #expect(failing.mergeBlockedReason == "checks failed")

    let ready = PullRequestPresentation.from(
        state: "open", draft: false, mergeable: true,
        checksState: "passed", reviewDecision: "approved"
    )
    #expect(ready.mergeBlockedReason == nil)
    #expect(!ready.canAskAgent)

    let merged = PullRequestPresentation.from(
        state: "merged", draft: false, mergeable: false,
        checksState: "passed", reviewDecision: ""
    )
    #expect(merged.stateLabel == "Merged")
    #expect(merged.mergeBlockedReason == "already merged")
}

@Test func mergeFlowAvailabilityAcceptsDirtyAndConflictedWorktrees() {
    func availability(state: String = "ready", mode: String = "worktree", files: Int, commits: Bool, dirty: Bool) -> WorkspaceActionAvailability {
        WorkspaceActionAvailability(
            agentActive: false, operationActive: false, workspaceState: state,
            workspaceMode: mode, changedFiles: files, hasCommits: commits,
            hasRemote: false, scmAuthenticated: false, hasPullRequest: false, dirty: dirty
        )
    }

    #expect(availability(files: 3, commits: false, dirty: true).allowsMergeFlow)
    #expect(availability(files: 0, commits: true, dirty: false).allowsMergeFlow)
    #expect(availability(state: "conflicted", files: 0, commits: false, dirty: false).allowsMergeFlow)
    #expect(!availability(mode: "main", files: 3, commits: true, dirty: true).allowsMergeFlow)
    #expect(!availability(files: 0, commits: false, dirty: false).allowsMergeFlow)
    // The raw merge gate still demands a clean tree.
    #expect(!availability(files: 3, commits: true, dirty: true).allows(.mergeLocal))
    // Committing needs a dirty tree or visible changes.
    #expect(availability(files: 0, commits: false, dirty: true).allows(.commit))
}

@Test func relativeTimeFormatsCompactStamps() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let formatter = ISO8601DateFormatter()
    func stamp(_ secondsAgo: TimeInterval) -> String {
        formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }

    #expect(WorkspaceRelativeTime.compact(stamp(41), now: now) == "41s ago")
    #expect(WorkspaceRelativeTime.compact(stamp(150), now: now) == "2m ago")
    #expect(WorkspaceRelativeTime.compact(stamp(7_200), now: now) == "2h ago")
    #expect(WorkspaceRelativeTime.compact(stamp(3 * 86_400), now: now) == "3d ago")
    #expect(WorkspaceRelativeTime.compact("", now: now) == "")
    #expect(WorkspaceRelativeTime.compact("2026-08-29T10:00:00.123456Z", now: Date(timeIntervalSince1970: 1_787_047_260)) != "")
}

@Test func agentPromptsDescribeConflictsAndReviews() {
    var conflict = Dieter_V1_GitConflict()
    conflict.path = "web/src/App.jsx"
    conflict.hunkCount = 3
    let prompt = WorkspaceAgentPrompt.resolveConflicts(baseBranch: "main", conflicts: [conflict])
    #expect(prompt.contains("main"))
    #expect(prompt.contains("web/src/App.jsx (3 hunks)"))

    let review = WorkspaceAgentPrompt.addressReview(number: 142, checksState: "failed", reviewDecision: "changes_requested")
    #expect(review.contains("#142"))
    #expect(review.contains("failing checks and requested review changes"))
}
