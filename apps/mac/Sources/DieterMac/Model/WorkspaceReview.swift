import DieterAPI
import Foundation

/// Presentation models for the card/chat-scoped review surface: folded diffs,
/// side-by-side pairing, merge readiness, and pull-request state mapping.

// MARK: - Diff display rows

/// A renderable row of the diff pane. The builder folds noise away so the view
/// only ever renders meaningful rows: changed lines, hunk pills with the count
/// of unchanged lines they skip, and collapsible context runs.
enum WorkspaceDiffRow: Identifiable, Equatable, Sendable {
    case line(UnifiedDiffLine)
    case pair(WorkspaceSplitPair)
    /// A file boundary inside a whole-commit patch.
    case file(id: Int, path: String)
    /// A hunk boundary. `skipped` counts the unchanged lines between this hunk
    /// and the previous one (0 for the first hunk).
    case hunk(id: Int, text: String, skipped: Int)
    /// A folded run of unchanged context. Expanding reveals `lines` (inline
    /// mode) or `pairs` (split mode) in place.
    case fold(id: Int, count: Int, lines: [UnifiedDiffLine], pairs: [WorkspaceSplitPair])

    var id: Int {
        switch self {
        case .line(let line): line.id
        case .pair(let pair): pair.id
        case .file(let id, _): id
        case .hunk(let id, _, _): id
        case .fold(let id, _, _, _): id
        }
    }
}

/// One side-by-side row: deletions pair with additions, context mirrors both.
struct WorkspaceSplitPair: Identifiable, Equatable, Sendable {
    let id: Int
    let old: UnifiedDiffLine?
    let new: UnifiedDiffLine?
}

enum WorkspaceDiffDisplay {
    /// Context runs longer than this fold down to their edges.
    static let foldThreshold = 16
    /// Context lines kept visible on each side of a fold.
    static let foldMargin = 5

    static func inlineRows(_ lines: [UnifiedDiffLine], foldThreshold: Int = foldThreshold, fileRows: Bool = false) -> [WorkspaceDiffRow] {
        rows(lines, foldThreshold: foldThreshold, split: false, fileRows: fileRows)
    }

    static func splitRows(_ lines: [UnifiedDiffLine], foldThreshold: Int = foldThreshold, fileRows: Bool = false) -> [WorkspaceDiffRow] {
        rows(lines, foldThreshold: foldThreshold, split: true, fileRows: fileRows)
    }

    /// "diff --git a/web/App.jsx b/web/App.jsx" → "web/App.jsx".
    static func filePath(fromDiffHeader header: String) -> String? {
        guard header.hasPrefix("diff ") else { return nil }
        let pieces = header.split(separator: " ")
        guard let last = pieces.last else { return nil }
        let raw = String(last)
        return raw.hasPrefix("b/") ? String(raw.dropFirst(2)) : raw
    }

    private static func rows(_ lines: [UnifiedDiffLine], foldThreshold: Int, split: Bool, fileRows: Bool) -> [WorkspaceDiffRow] {
        var result: [WorkspaceDiffRow] = []
        var context: [UnifiedDiffLine] = []
        var changes: [UnifiedDiffLine] = []
        var previousHunkOldEnd: Int?

        func flushChanges() {
            guard !changes.isEmpty else { return }
            if split {
                result.append(contentsOf: pairRows(changes))
            } else {
                result.append(contentsOf: changes.map(WorkspaceDiffRow.line))
            }
            changes = []
        }

        func emit(_ run: ArraySlice<UnifiedDiffLine>) {
            if split {
                result.append(contentsOf: run.map { WorkspaceDiffRow.pair(.init(id: $0.id, old: $0, new: $0)) })
            } else {
                result.append(contentsOf: run.map(WorkspaceDiffRow.line))
            }
        }

        func flushContext(trailing: Bool) {
            guard !context.isEmpty else { return }
            defer { context = [] }
            guard context.count > foldThreshold else {
                emit(context[...])
                return
            }
            let head = result.isEmpty ? 0 : foldMargin
            let tail = trailing ? 0 : foldMargin
            let hidden = Array(context.dropFirst(head).dropLast(tail))
            emit(context.prefix(head))
            result.append(.fold(
                id: hidden.first?.id ?? context.first!.id,
                count: hidden.count,
                lines: hidden,
                pairs: hidden.map { .init(id: $0.id, old: $0, new: $0) }
            ))
            emit(context.suffix(tail))
        }

        for line in lines {
            switch line.kind {
            case .header:
                if fileRows, let path = filePath(fromDiffHeader: line.text) {
                    flushChanges()
                    flushContext(trailing: true)
                    previousHunkOldEnd = nil
                    result.append(.file(id: line.id, path: path))
                }
            case .hunk:
                flushChanges()
                flushContext(trailing: true)
                let ranges = hunkSummary(line.text)
                var skipped = 0
                if let previousHunkOldEnd, let start = ranges?.oldStart {
                    skipped = max(0, start - previousHunkOldEnd)
                }
                previousHunkOldEnd = ranges.map { $0.oldStart + $0.oldCount }
                result.append(.hunk(id: line.id, text: hunkDisplayText(line.text), skipped: skipped))
            case .context:
                flushChanges()
                context.append(line)
            case .addition, .deletion:
                flushContext(trailing: false)
                changes.append(line)
            }
        }
        flushChanges()
        flushContext(trailing: true)
        return result
    }

    /// Pairs a run of deletions and additions into side-by-side rows.
    static func pairRows(_ changes: [UnifiedDiffLine]) -> [WorkspaceDiffRow] {
        let deletions = changes.filter { $0.kind == .deletion }
        let additions = changes.filter { $0.kind == .addition }
        return (0..<max(deletions.count, additions.count)).map { index in
            let old = index < deletions.count ? deletions[index] : nil
            let new = index < additions.count ? additions[index] : nil
            return .pair(.init(id: old?.id ?? new!.id, old: old, new: new))
        }
    }

    /// "@@ -1284,9 +1284,16 @@ function ChatSidebar({ projects })" → range info.
    static func hunkSummary(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let pieces = header.split(separator: " ")
        guard pieces.count >= 3, pieces[0] == "@@" else { return nil }
        func range(_ piece: Substring) -> (Int, Int)? {
            let parts = piece.dropFirst().split(separator: ",", maxSplits: 1)
            guard let start = Int(parts.first ?? "") else { return nil }
            return (start, Int(parts.count > 1 ? parts[1] : "1") ?? 1)
        }
        guard let old = range(pieces[1]), let new = range(pieces[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// Keeps the function context that trails a hunk header, dropping the raw
    /// range noise when context exists ("function ChatSidebar({ projects })").
    static func hunkDisplayText(_ header: String) -> String {
        guard let end = header.range(of: "@@", options: .backwards, range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex) else {
            return header
        }
        let context = header[end.upperBound...].trimmingCharacters(in: .whitespaces)
        let ranges = header[..<end.upperBound].trimmingCharacters(in: .whitespaces)
        return context.isEmpty ? ranges : "\(ranges) \(context)"
    }
}

// MARK: - Merge readiness

/// The pre-merge checklist shown in the merge sheet, mirroring the reference
/// "No conflicts with main / tests passed / uncommitted change committed first".
struct WorkspaceMergeReadiness: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case ready, note, blocked }

    struct Item: Equatable, Identifiable, Sendable {
        let id: String
        let tone: Tone
        let text: String
        var detail: String = ""
    }

    let items: [Item]
    let dirty: Bool
    let conflictedFiles: Int

    var blocked: Bool { items.contains { $0.tone == .blocked } }
    var commitsFirst: Bool { dirty }

    static func evaluate(
        workspaceState: String,
        baseBranch: String,
        behind: Int,
        dirty: Bool,
        conflictedFiles: Int,
        lastValidation: (name: String, passed: Bool, ago: String)?
    ) -> WorkspaceMergeReadiness {
        var items: [Item] = []
        let base = baseBranch.isEmpty ? "base" : baseBranch
        if workspaceState == "conflicted" || conflictedFiles > 0 {
            let count = max(conflictedFiles, 1)
            items.append(.init(
                id: "conflicts",
                tone: .blocked,
                text: count == 1 ? "1 file conflicts with \(base)" : "\(count) files conflict with \(base)",
                detail: "Merge is blocked until conflicts are resolved."
            ))
        } else {
            items.append(.init(id: "conflicts", tone: .ready, text: "No conflicts with \(base)", detail: "checked just now"))
        }
        if let validation = lastValidation {
            items.append(.init(
                id: "validation",
                tone: validation.passed ? .ready : .note,
                text: validation.passed ? "\(validation.name) passed on the workspace" : "\(validation.name) failed on the workspace",
                detail: validation.ago
            ))
        }
        if behind > 0 {
            items.append(.init(
                id: "behind",
                tone: .note,
                text: base + " moved · \(behind) new commit" + (behind == 1 ? "" : "s"),
                detail: "Update from \(base) to pick them up before merging."
            ))
        }
        if dirty {
            items.append(.init(
                id: "uncommitted",
                tone: .note,
                text: "Uncommitted changes will be committed first"
            ))
        }
        return .init(items: items, dirty: dirty, conflictedFiles: conflictedFiles)
    }
}

/// Sequential steps the merge orchestrator runs; drives sheet progress copy.
enum WorkspaceMergeStep: String, Equatable, Sendable {
    case commit
    case merge
    case cleanup

    var progressLabel: String {
        switch self {
        case .commit: "Committing working changes…"
        case .merge: "Merging into the base branch…"
        case .cleanup: "Removing the worktree and branch…"
        }
    }
}

// MARK: - Pull request presentation

/// Maps provider fields (state/draft/checks/review) onto the reference PR card.
struct PullRequestPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case positive, active, warning, critical, neutral }

    struct Signal: Equatable, Identifiable, Sendable {
        let id: String
        let tone: Tone
        let text: String
    }

    let stateLabel: String
    let stateTone: Tone
    let signals: [Signal]
    /// Non-nil when merging should be prevented, e.g. "waiting on checks".
    let mergeBlockedReason: String?
    let canAskAgent: Bool

    static func from(
        state: String,
        draft: Bool,
        mergeable: Bool,
        checksState: String,
        reviewDecision: String,
        reviewer: String = ""
    ) -> PullRequestPresentation {
        let stateLabel: String
        let stateTone: Tone
        switch state.lowercased() {
        case "merged": stateLabel = "Merged"; stateTone = .neutral
        case "closed": stateLabel = "Closed"; stateTone = .critical
        default:
            stateLabel = draft ? "Draft" : "Open"
            stateTone = draft ? .neutral : .positive
        }

        var signals: [Signal] = []
        switch checksState {
        case "passed": signals.append(.init(id: "checks", tone: .positive, text: "checks passed"))
        case "running": signals.append(.init(id: "checks", tone: .active, text: "checks running"))
        case "failed": signals.append(.init(id: "checks", tone: .critical, text: "checks failed"))
        default: break
        }
        switch reviewDecision {
        case "approved":
            signals.append(.init(id: "review", tone: .positive, text: "approved"))
        case "changes_requested":
            signals.append(.init(id: "review", tone: .warning, text: "changes requested"))
        case "review_required":
            signals.append(.init(
                id: "review",
                tone: .warning,
                text: reviewer.isEmpty ? "review requested" : "review requested · @\(reviewer)"
            ))
        default: break
        }

        var mergeBlockedReason: String?
        if state.lowercased() != "open" {
            mergeBlockedReason = "already \(stateLabel.lowercased())"
        } else if draft {
            mergeBlockedReason = "draft"
        } else if checksState == "running" {
            mergeBlockedReason = "waiting on checks"
        } else if checksState == "failed" {
            mergeBlockedReason = "checks failed"
        } else if !mergeable {
            mergeBlockedReason = "not mergeable"
        }

        let canAskAgent = state.lowercased() == "open"
            && (checksState == "failed" || reviewDecision == "changes_requested")
        return .init(
            stateLabel: stateLabel,
            stateTone: stateTone,
            signals: signals,
            mergeBlockedReason: mergeBlockedReason,
            canAskAgent: canAskAgent
        )
    }
}

// MARK: - Relative time

enum WorkspaceRelativeTime {
    static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// Compact "41s ago" / "2m ago" / "1h ago" / "3d ago" stamps for rows.
    static func compact(_ value: String, now: Date = Date()) -> String {
        guard let date = parse(value) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d ago"
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

// MARK: - Toast

/// A transient confirmation shown after a workflow completes, e.g.
/// "Merged fold-chats into main · card moved to Done".
struct WorkspaceToast: Equatable, Identifiable, Sendable {
    let id: UUID
    let message: String

    init(message: String) {
        id = UUID()
        self.message = message
    }
}

// MARK: - Agent handoff prompts

/// Prompts sent into the conversation when the person hands Git trouble to the
/// agent instead of resolving it by hand.
enum WorkspaceAgentPrompt {
    static func resolveConflicts(baseBranch: String, conflicts: [Dieter_V1_GitConflict]) -> String {
        let base = baseBranch.isEmpty ? "the base branch" : baseBranch
        var text = "The merge into \(base) is blocked by conflicts."
        if !conflicts.isEmpty {
            let files = conflicts.map { conflict in
                conflict.hunkCount > 0 ? "\(conflict.path) (\(conflict.hunkCount) hunk\(conflict.hunkCount == 1 ? "" : "s"))" : conflict.path
            }
            text += " Conflicting files: " + files.joined(separator: ", ") + "."
        }
        text += " Please resolve every conflict marker, run the project validation, and report back when the workspace is clean."
        return text
    }

    static func addressReview(number: Int32, checksState: String, reviewDecision: String) -> String {
        var reasons: [String] = []
        if checksState == "failed" { reasons.append("failing checks") }
        if reviewDecision == "changes_requested" { reasons.append("requested review changes") }
        let cause = reasons.isEmpty ? "the open review feedback" : reasons.joined(separator: " and ")
        return "Pull request #\(number) needs attention: please address \(cause), push the fixes to the pull request branch, and summarize what changed."
    }
}
