import DieterAPI
import Foundation

enum ConversationWorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case projectDefault = ""
    case worktree
    case branch
    case main

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectDefault: "Project default"
        case .worktree: "Isolated worktree"
        case .branch: "Dedicated branch"
        case .main: "Main checkout"
        }
    }

    var shortTitle: String {
        switch self {
        case .projectDefault: "Default"
        case .worktree: "Worktree"
        case .branch: "Branch"
        case .main: "Main"
        }
    }

    var detail: String {
        switch self {
        case .projectDefault: "Use the project’s configured workspace mode."
        case .worktree: "Create an isolated Git worktree and branch for this conversation."
        case .branch: "Use a dedicated branch in the registered checkout."
        case .main: "Share the registered checkout. Concurrent work is restricted."
        }
    }

    static func projectMode(_ value: String) -> ConversationWorkspaceMode {
        ConversationWorkspaceMode(rawValue: value) ?? .main
    }
}

struct ConversationWorkspaceDraft: Equatable, Sendable {
    var mode: ConversationWorkspaceMode = .projectDefault
    var branch = ""
    var baseBranch = ""

    func apply(to request: inout Dieter_V1_CreateConversationRequest) {
        request.workspaceMode = mode.rawValue
        request.workspaceBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        request.workspaceBaseBranch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
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
        environment = value.environment.keys.sorted().map { "\($0)=\(value.environment[$0] ?? "")" }.joined(separator: "\n")
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
    case migrate
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
        case .migrate: "Migrate to worktree"
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

enum GitOperationReconciliation {
    static func operationID(
        workspaceOperationID: String,
        observedOperationID: String?,
        observedStatus: String?
    ) -> String? {
        if !workspaceOperationID.isEmpty { return workspaceOperationID }
        guard let observedOperationID, !observedOperationID.isEmpty,
              let observedStatus, GitOperationStatus.active(observedStatus) else { return nil }
        return observedOperationID
    }
}

struct WorkspaceActionAvailability: Equatable {
    let agentActive: Bool
    let operationActive: Bool
    let workspaceState: String
    let workspaceMode: String
    let changedFiles: Int
    let hasCommits: Bool
    let hasRemote: Bool
    let scmAuthenticated: Bool
    let hasPullRequest: Bool

    func allows(_ kind: GitOperationKind) -> Bool {
        if agentActive || operationActive { return false }
        if workspaceState == "conflicted" {
            return kind == .continueConflict || kind == .abortConflict
        }
        return switch kind {
        case .commit: changedFiles > 0
        case .update, .validate: true
        case .mergeLocal: workspaceMode != "main" && hasCommits && changedFiles == 0
        case .push: workspaceMode != "main" && hasRemote && hasCommits
        case .createPullRequest: workspaceMode != "main" && hasRemote && hasCommits && scmAuthenticated && !hasPullRequest
        case .refreshPullRequest, .mergePullRequest: hasPullRequest && scmAuthenticated
        case .continueConflict, .abortConflict: false
        case .migrate: workspaceMode == "branch" && changedFiles == 0
        case .adopt: true
        case .cleanup: changedFiles == 0
        case .discard: true
        }
    }
}

struct UnifiedDiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, addition, deletion, header, hunk }
    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

enum UnifiedDiffParser {
    static func parse(_ patch: String) -> [UnifiedDiffLine] {
        var result: [UnifiedDiffLine] = []
        var oldLine: Int?
        var newLine: Int?
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).enumerated() {
            if raw.hasPrefix("@@"), let ranges = hunkRanges(raw) {
                oldLine = ranges.old
                newLine = ranges.new
                result.append(.init(id: index, kind: .hunk, text: raw, oldLine: nil, newLine: nil))
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") || raw.hasPrefix("\\ No newline") {
                result.append(.init(id: index, kind: .header, text: raw, oldLine: nil, newLine: nil))
            } else if raw.hasPrefix("+") {
                result.append(.init(id: index, kind: .addition, text: raw, oldLine: nil, newLine: newLine))
                newLine = newLine.map { $0 + 1 }
            } else if raw.hasPrefix("-") {
                result.append(.init(id: index, kind: .deletion, text: raw, oldLine: oldLine, newLine: nil))
                oldLine = oldLine.map { $0 + 1 }
            } else {
                result.append(.init(id: index, kind: .context, text: raw, oldLine: oldLine, newLine: newLine))
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
            }
        }
        return result
    }

    private static func hunkRanges(_ value: String) -> (old: Int, new: Int)? {
        let pieces = value.split(separator: " ")
        guard pieces.count >= 3 else { return nil }
        func start(_ piece: Substring) -> Int? {
            Int(piece.dropFirst().split(separator: ",", maxSplits: 1).first ?? "")
        }
        guard let old = start(pieces[1]), let new = start(pieces[2]) else { return nil }
        return (old, new)
    }
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

struct WorkspaceReviewSelection: Equatable, Sendable {
    var path: String
    var commitSHA: String
}

enum WorkspaceReviewSelectionResolver {
    static func resolve(
        currentPath: String,
        currentCommitSHA: String,
        filePaths: [String],
        commitSHAs: [String]
    ) -> WorkspaceReviewSelection {
        if !currentCommitSHA.isEmpty, commitSHAs.contains(currentCommitSHA) {
            return .init(path: "", commitSHA: currentCommitSHA)
        }
        if !currentPath.isEmpty, filePaths.contains(currentPath) {
            return .init(path: currentPath, commitSHA: "")
        }
        if let path = filePaths.first { return .init(path: path, commitSHA: "") }
        if let commitSHA = commitSHAs.first { return .init(path: "", commitSHA: commitSHA) }
        return .init(path: "", commitSHA: "")
    }
}

extension Dieter_V1_WorkspaceSummary {
    var hasMaterialChanges: Bool { changedFiles > 0 || additions > 0 || deletions > 0 }
}
