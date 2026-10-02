import DieterAPI
import DieterShared
import Foundation

enum ConversationWorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case worktree
    case project

    var id: String { rawValue }

    /// "Worktree" or "Project directory", as the shared core words it.
    var title: String { SharedRules.shared.workspaceModeTitle(mode: rawValue) }

    /// "Worktree" or "Project".
    var shortTitle: String { SharedRules.shared.workspaceModeShortTitle(mode: rawValue) }

    /// What the mode does.
    var detail: String { SharedRules.shared.workspaceModeDetail(mode: rawValue) }

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

    /// The workspace as chosen; the core uses the overrides in worktree mode only.
    func apply(to intent: inout ClientCreationIntent) {
        intent.workspaceMode = mode.rawValue
        intent.workspaceBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        intent.workspaceBaseBranch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        intent.workspaceBaseRemote = baseRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        intent.remotePublishMode = remotePublishMode
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

    /// The operation's form as the shared core describes it, filled from `card`.
    func form(card: Dieter_V1_Card? = nil, baseBranch: String = "") -> ClientGitOperationFormSpec {
        ClientGitOperationFormSpec(
            rules: SharedRules.shared.gitOperationForm(
                kind: rawValue, cardTitle: card?.title ?? "", cardPrompt: card?.initialPrompt ?? "",
                pullRequestHeadSha: card?.pullRequest.headSha ?? "", baseBranch: baseBranch))
    }

    /// "Commit changes", as the core words the operation.
    var title: String { form().title }
}

/// What a workspace allows now. The shared core decides it from the card,
/// workspace, changes, and source control state.
struct WorkspaceActionAvailability: Equatable {
    var allowed: Set<String> = []
    var allowsMergeFlow = false
    var hasReviewBranch = false
    var workspaceMode = ConversationWorkspaceMode.project.rawValue
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

extension ClientChangedFileLabel {
    /// A changed file as lists show it: its badge, title, name, and folder.
    static func of(_ path: String, status: String = "", conflicted: Bool = false, untracked: Bool = false) -> Self {
        Self(
            rules: SharedRules.shared.changedFile(
                path: path, status: status, conflicted: conflicted, untracked: untracked))
    }
}
