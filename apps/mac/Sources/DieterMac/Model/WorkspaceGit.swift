import DieterAPI
import Foundation

enum ConversationWorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case worktree
    case project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .worktree: "Worktree"
        case .project: "Project directory"
        }
    }

    var shortTitle: String {
        switch self {
        case .worktree: "Worktree"
        case .project: "Project"
        }
    }

    var detail: String {
        switch self {
        case .worktree: "Create a new isolated Git worktree and branch for this conversation."
        case .project:
            "Use the registered project directory on whichever branch it currently has checked out."
        }
    }

    static func projectMode(_ value: String) -> ConversationWorkspaceMode {
        selectable(value)
    }

    static func selectable(_ rawValue: String?) -> ConversationWorkspaceMode {
        rawValue?.lowercased() == Self.worktree.rawValue ? .worktree : .project
    }

    var symbol: String {
        switch self {
        case .worktree: "point.3.connected.trianglepath.dotted"
        case .project: "folder"
        }
    }
}

struct ConversationWorkspaceDraft: Equatable, Sendable {
    var mode: ConversationWorkspaceMode = .worktree
    var branch = ""
    var baseBranch = ""
    var baseRemote = ""
    var remotePublishMode = RemotePublishMode.manual.rawValue

    func apply(to request: inout Dieter_V1_CreateConversationRequest) {
        request.workspaceMode = mode.rawValue
        request.workspaceBranch =
            mode == .worktree ? branch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        request.workspaceBaseBranch =
            mode == .worktree ? baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        request.workspaceBaseRemote = baseRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        request.remotePublishMode = remotePublishMode
    }
}

enum RemotePublishMode: String, CaseIterable, Identifiable, Sendable {
    case manual
    case pullRequest = "pull_request"
    case pushBase = "push_base"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .pullRequest: "Pull request"
        case .pushBase: "Push base branch"
        }
    }

    var detail: String {
        switch self {
        case .manual: "Choose local merge, branch push, or pull request when publishing."
        case .pullRequest: "Publish the conversation branch through a pull request."
        case .pushBase: "Push the validated integration result directly to the base branch."
        }
    }
}

struct ValidationCommandDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var executable = ""
    var arguments = ""
    var workingDirectory = ""
    var environment = ""
    var timeoutSeconds: Int32 = 600

    init() {}

    init(_ value: Dieter_V1_ValidationCommand) {
        name = value.name
        executable = value.executable
        arguments = value.arguments.joined(separator: "\n")
        workingDirectory = value.workingDirectory
        environment = value.environment.keys.sorted().map { "\($0)=\(value.environment[$0] ?? "")" }
            .joined(
                separator: "\n")
        timeoutSeconds = value.timeoutSeconds
    }

    var value: Dieter_V1_ValidationCommand {
        var result = Dieter_V1_ValidationCommand()
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        result.arguments = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
        result.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        result.timeoutSeconds = timeoutSeconds
        for line in environment.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty { result.environment[parts[0]] = parts[1] }
        }
        return result
    }
}

enum GitOperationKind: String, CaseIterable, Identifiable, Sendable {
    case commit
    case update
    case validate
    case mergeLocal = "merge_local"
    case push
    case createPullRequest = "create_pr"
    case refreshPullRequest = "refresh_pr"
    case mergePullRequest = "merge_pr"
    case continueConflict = "continue_conflict"
    case abortConflict = "abort_conflict"
    case adopt
    case cleanup
    case discard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commit: "Commit changes"
        case .update: "Update from base"
        case .validate: "Run validation"
        case .mergeLocal: "Merge locally"
        case .push: "Push branch"
        case .createPullRequest: "Create pull request"
        case .refreshPullRequest: "Refresh pull request"
        case .mergePullRequest: "Merge pull request"
        case .continueConflict: "Continue after resolving"
        case .abortConflict: "Abort conflicted operation"
        case .adopt: "Move workspace"
        case .cleanup: "Clean up workspace"
        case .discard: "Discard workspace"
        }
    }

    var destructive: Bool { self == .discard || self == .abortConflict }
}

enum GitOperationStatus {
    static func terminal(_ value: String) -> Bool {
        ["succeeded", "failed", "canceled", "interrupted"].contains(value)
    }

    static func active(_ value: String) -> Bool {
        ["queued", "running", "waiting_for_resolution"].contains(value)
    }
}

/// What a workspace allows now. The shared core decides it from the card,
/// workspace, changes, and source control state.
struct WorkspaceActionAvailability: Equatable {
    var allowed: Set<String> = []
    var allowsMergeFlow = false
    var hasReviewBranch = false
    var workspaceMode = ConversationWorkspaceMode.project.rawValue
    var remotePublishMode = RemotePublishMode.manual.rawValue
    /// Where a merge's result ends up.
    var mergeDestination = ""

    func allows(_ kind: GitOperationKind) -> Bool { allowed.contains(kind.rawValue) }
}

struct UnifiedDiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, addition, deletion, header, hunk }
    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

enum WorkspaceReviewLayout {
    static let compactBreakpoint: CGFloat = 680

    static func isCompact(width: CGFloat) -> Bool {
        width < compactBreakpoint
    }
}

enum WorkspaceChangePresentation {
    static func badge(status: String, conflicted: Bool = false, untracked: Bool = false) -> String {
        if conflicted { return "!" }
        if untracked { return "U" }
        return switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "a", "add", "added": "A"
        case "d", "delete", "deleted": "D"
        case "r", "rename", "renamed": "R"
        case "c", "copy", "copied": "C"
        case "u", "unmerged", "conflicted": "!"
        default: "M"
        }
    }

    static func title(status: String, conflicted: Bool = false, untracked: Bool = false) -> String {
        if conflicted { return "Conflicted" }
        if untracked { return "Untracked" }
        return switch badge(status: status) {
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        default: "Modified"
        }
    }

    static func filename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func directory(_ path: String) -> String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }
}

extension Dieter_V1_WorkspaceSummary {
    var hasMaterialChanges: Bool { changedFiles > 0 || additions > 0 || deletions > 0 }
}
