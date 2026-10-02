import DieterAPI
import Foundation

/// The review surface's view models over the shared core's presentation:
/// diffs as the core lays them out, the merge flow's steps, and toasts.

// MARK: - Diff display rows

/// A diff as the core laid it out for one view: its rows, widest code line,
/// layout, and whether more of it can load.
struct WorkspaceDiffLayout: Equatable, Sendable {
    var rows: [WorkspaceDiffRow] = []
    /// The widest code line in columns, for the split layout's width.
    var maxColumns = 0
    var split = false
    /// Another page of the diff can load.
    var more = false
    /// Why the rest of the diff is not shown (its size limit); empty otherwise.
    var note = ""
    /// Changes whenever the rows do, so a view can reset the folds it expanded.
    var revision = 0

    /// This layout after an update; an unchanged one keeps the rows the view has.
    func folding(
        rows: [ClientDiffDisplayRow], unchanged: Bool, maxColumns: Int32, split: Bool, more: Bool, note: String
    ) -> Self {
        var next = self
        if !unchanged {
            let mapped = rows.compactMap(WorkspaceDiffRow.init)
            if mapped != next.rows {
                next.rows = mapped
                next.revision &+= 1
            }
        }
        if !unchanged || maxColumns > 0 { next.maxColumns = Int(maxColumns) }
        next.split = split
        next.more = more
        next.note = note
        return next
    }
}

/// One unified line with the review comments on it.
struct WorkspaceDiffLine: Identifiable, Equatable, Sendable {
    let line: UnifiedDiffLine
    let comments: [Dieter_V1_ChangeComment]
    /// A review comment can attach to this line.
    let commentable: Bool
    var id: Int { line.id }

    init(_ value: ClientDiffDisplayLine) {
        line = UnifiedDiffLine(value.row)
        comments = value.comments
        commentable = value.commentable
    }
}

/// A row of the diff pane as the core laid it out.
enum WorkspaceDiffRow: Identifiable, Equatable, Sendable {
    case line(WorkspaceDiffLine)
    case pair(WorkspaceSplitPair)
    /// A file boundary inside a whole-commit patch.
    case file(id: Int, path: String)
    /// A hunk boundary; `skipped` counts the unchanged lines since the previous hunk.
    case hunk(id: Int, text: String, skipped: Int, additions: Int, deletions: Int)
    /// A folded run of unchanged context: `lines` in one column, `pairs` side by side.
    case fold(id: Int, count: Int, lines: [WorkspaceDiffLine], pairs: [WorkspaceSplitPair])

    var id: Int {
        switch self {
        case .line(let line): line.id
        case .pair(let pair): pair.id
        case .file(let id, _): id
        case .hunk(let id, _, _, _, _): id
        case .fold(let id, _, _, _): id
        }
    }

    init?(_ row: ClientDiffDisplayRow) {
        switch row.item {
        case .line(let line): self = .line(WorkspaceDiffLine(line))
        case .pair(let pair): self = .pair(WorkspaceSplitPair(pair))
        case .fileBoundary(let file): self = .file(id: Int(file.id), path: file.path)
        case .hunk(let hunk):
            self = .hunk(
                id: Int(hunk.id), text: hunk.text, skipped: Int(hunk.skippedLines), additions: Int(hunk.additions),
                deletions: Int(hunk.deletions))
        case .fold(let fold):
            self = .fold(
                id: Int(fold.id), count: Int(fold.count), lines: fold.lines.map(WorkspaceDiffLine.init),
                pairs: fold.pairs.map(WorkspaceSplitPair.init))
        case nil: return nil
        }
    }
}

/// One side-by-side row: a deletion beside an addition, or context on both sides.
struct WorkspaceSplitPair: Identifiable, Equatable, Sendable {
    let id: Int
    let old: UnifiedDiffLine?
    let new: UnifiedDiffLine?

    init(_ pair: ClientDiffPair) {
        id = Int(pair.id)
        old = pair.hasBefore ? UnifiedDiffLine(pair.before) : nil
        new = pair.hasAfter ? UnifiedDiffLine(pair.after) : nil
    }
}

// MARK: - Merge flow

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
