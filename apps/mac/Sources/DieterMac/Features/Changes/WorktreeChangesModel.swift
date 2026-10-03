import DieterAPI
import DieterShared
import Foundation
import Observation
import SharedCore

/// A conversation workspace's review, kept by the shared core on the machine
/// that owns the conversation: changes, diffs, comments, Git operations, and
/// the merge flow. An active review refreshes itself.
@MainActor @Observable
final class WorktreeChangesModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    var card: Dieter_V1_Card?
    var authorName = ""
    var conversationWorkspace: Dieter_V1_Workspace?
    var conversationChangeset: Dieter_V1_Changeset?
    var conversationDiff: Dieter_V1_FileDiff?
    /// The diff laid out for this view, as the core lays it out.
    private(set) var diff = WorkspaceDiffLayout()
    var conversationChangeComments: [Dieter_V1_ChangeComment] = []
    var conversationSCMCapabilities: Dieter_V1_SCMCapabilities?
    var gitOperation: Dieter_V1_GitOperation?
    var gitOperationLogs: [Dieter_V1_GitOperationLogEntry] = []
    var workspaceLoading = false
    var workspaceError: String?
    var selectedChangePath = ""
    var selectedCommitSHA = ""
    var workspaceToast: WorkspaceToast?
    var mergeFlowStep: WorkspaceMergeStep?
    var conversationDiffLoading = false
    var gitOperationSubmitting = false
    var gitOperationNeedsReconciliation = false
    /// What the workspace allows now, as the core decides it.
    private(set) var availability = WorkspaceActionAvailability()
    /// The workspace has conflicts, or an operation waits for them to be resolved.
    private(set) var conflicted = false
    /// The workspace's state in words, e.g. "Ready" or "Conflicted".
    private(set) var workspaceState = ""
    /// The review's presentation, as the core decides it: the operation strip,
    /// the conflict's title and hand-off, the pull request, and the merge checklist.
    private(set) var operationVisible = false
    private(set) var operationCancelable = false
    private(set) var conflictTitle = ""
    private(set) var conflictPrompt = ""
    private(set) var movesToDone = false
    private(set) var pullRequest: ClientPullRequestView?
    private(set) var mergeReadiness = ClientMergeReadiness()
    @ObservationIgnored private var operationActive = false
    /// Visible and foregrounded: the core refreshes the review periodically.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            let on = active
            send { $0.active = .with { $0.on = on } }
        }
    }
    @ObservationIgnored var workspaceToastTask: Task<Void, Never>?
    private(set) var bindingGeneration: UInt64 = 0
    @ObservationIgnored var onOperationFinished: @MainActor (WorkspaceTarget) async -> Void = { _ in }
    @ObservationIgnored var onOpenFiles: @MainActor (Dieter_V1_Card, String?) async -> Void = { _, _ in }
    @ObservationIgnored var onOpenTerminal: @MainActor (Dieter_V1_Card) async -> Void = { _ in }
    @ObservationIgnored var onSendMessage: @MainActor (String, Dieter_V1_Card, WorkspaceTarget) async -> Bool = {
        _, _, _ in false
    }
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private let scope = "review-\(UUID().uuidString)"
    @ObservationIgnored private var subscription: SliceSubscription?
    /// What the core was last told to review; slices for another are stale.
    @ObservationIgnored private var bound = ClientReviewTarget()
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var shownToast = ""

    func openWorkspaceFiles(card: Dieter_V1_Card, opening path: String? = nil) async { await onOpenFiles(card, path) }
    func openWorkspaceTerminal(card: Dieter_V1_Card) async { await onOpenTerminal(card) }
    func sendAgentMessage(_ text: String) async -> Bool {
        guard let card else { return false }
        let binding = bindingGeneration
        let sent = await onSendMessage(text, card, target)
        return binding == bindingGeneration && sent
    }

    /// Reviews `target`'s conversation through `core`; a conversation not yet
    /// on its machine has nothing to review.
    func bind(target: WorkspaceTarget, core: CoreClient?, card: Dieter_V1_Card?) {
        if subscription == nil, let core {
            self.core = core
            subscription = SliceSubscription(client: core, slice: .review, scope: scope) { [weak self] update in
                guard let self, case .review(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        self.card = card
        guard self.target != target else { return }
        self.target = target
        resetWorkspaceSurface()
        let id = target.conversationID
        bound = ClientReviewTarget.with {
            $0.cardID = SharedRules.shared.isServerBacked(conversationId: id) ? id : ""
            $0.daemonID = target.daemonID
        }
        let review = bound, on = active
        send { $0.bind = review }
        send { $0.active = .with { $0.on = on } }
    }

    /// Clears what the view shows until the core reports the new workspace.
    func resetWorkspaceSurface() {
        bindingGeneration &+= 1
        workspaceToastTask?.cancel(); workspaceToastTask = nil
        workspaceToast = nil; mergeFlowStep = nil; shownToast = ""
        conversationWorkspace = nil; conversationChangeset = nil; conversationDiff = nil; diff = WorkspaceDiffLayout()
        conversationChangeComments = []; conversationSCMCapabilities = nil
        gitOperation = nil; gitOperationLogs = []
        workspaceLoading = false; workspaceError = nil; conversationDiffLoading = false
        gitOperationSubmitting = false; gitOperationNeedsReconciliation = false
        selectedChangePath = ""; selectedCommitSHA = ""
        availability = WorkspaceActionAvailability(); conflicted = false; workspaceState = ""
        operationVisible = false; operationCancelable = false; operationActive = false
        conflictTitle = ""; conflictPrompt = ""; movesToDone = false; pullRequest = nil
        mergeReadiness = ClientMergeReadiness()
    }

    /// Lays the diff out side by side or in one column; the core keeps the choice.
    func setLayout(split: Bool) {
        send { $0.layout = .with { $0.split = split } }
    }

    private func fold(_ slice: ClientReviewSlice) {
        guard slice.cardID == bound.cardID, slice.daemonID == bound.daemonID else { return }
        let workspace = slice.hasWorkspace ? slice.workspace : nil
        if conversationWorkspace != workspace { conversationWorkspace = workspace }
        if workspaceState != slice.workspaceState { workspaceState = slice.workspaceState }
        let changeset = slice.hasChangeset ? slice.changeset : nil
        if conversationChangeset != changeset { conversationChangeset = changeset }
        let scm = slice.hasScm ? slice.scm : nil
        if conversationSCMCapabilities != scm { conversationSCMCapabilities = scm }
        if conversationChangeComments != slice.comments { conversationChangeComments = slice.comments }
        if workspaceLoading != slice.loading { workspaceLoading = slice.loading }
        let error = slice.error.isEmpty ? nil : slice.error
        if workspaceError != error { workspaceError = error }
        if selectedChangePath != slice.selectedPath { selectedChangePath = slice.selectedPath }
        if selectedCommitSHA != slice.selectedCommit { selectedCommitSHA = slice.selectedCommit }
        let fileDiff = slice.hasDiff ? slice.diff : nil
        if conversationDiff != fileDiff { conversationDiff = fileDiff }
        let layout = diff.folding(
            rows: slice.displayRows, unchanged: slice.diffUnchanged, maxColumns: slice.diffMaxColumns,
            split: slice.split, more: slice.diffMore, note: slice.diffTooLarge ? slice.diffNote : "")
        if diff != layout { diff = layout }
        if conversationDiffLoading != slice.diffLoading { conversationDiffLoading = slice.diffLoading }
        let previous = gitOperation, wasActive = operationActive
        let operation = slice.hasOperation ? slice.operation : nil
        if gitOperation != operation { gitOperation = operation }
        if gitOperationLogs != slice.logs { gitOperationLogs = slice.logs }
        if gitOperationSubmitting != slice.submitting { gitOperationSubmitting = slice.submitting }
        if gitOperationNeedsReconciliation != slice.needsReconciliation {
            gitOperationNeedsReconciliation = slice.needsReconciliation
        }
        let step = WorkspaceMergeStep(rawValue: slice.mergeStep)
        if mergeFlowStep != step { mergeFlowStep = step }
        let next =
            slice.hasAvailability ? WorkspaceActionAvailability(slice.availability) : WorkspaceActionAvailability()
        if availability != next { availability = next }
        if conflicted != slice.conflicted { conflicted = slice.conflicted }
        operationActive = slice.operationActive
        if operationVisible != slice.operationVisible { operationVisible = slice.operationVisible }
        if operationCancelable != slice.operationCancelable { operationCancelable = slice.operationCancelable }
        if conflictTitle != slice.conflictTitle { conflictTitle = slice.conflictTitle }
        if conflictPrompt != slice.conflictPrompt { conflictPrompt = slice.conflictPrompt }
        if movesToDone != slice.movesToDone { movesToDone = slice.movesToDone }
        let pull = slice.hasPullRequest ? slice.pullRequest : nil
        if pullRequest != pull { pullRequest = pull }
        if mergeReadiness != slice.mergeReadiness { mergeReadiness = slice.mergeReadiness }
        if !slice.toast.isEmpty, slice.toast != shownToast {
            shownToast = slice.toast
            showWorkspaceToast(slice.toast)
            send { $0.clearToast_p = ClientStep() }
        }
        // A finished operation can change the project's workspaces and board.
        if let previous, let operation, previous.id == operation.id, wasActive, !slice.operationActive,
            !slice.conflicted
        {
            let target = target
            Task { await onOperationFinished(target) }
        }
    }

    /// Sends a command without waiting for it, after those sent before.
    private func send(_ build: @escaping (inout ClientReviewCommand) -> Void) {
        guard core != nil else { return }
        let previous = queued
        queued = Task { [weak self] in
            await previous?.value
            await self?.run(afterQueued: false, build)
        }
    }

    /// Runs a review command and folds the review it returns; a failure
    /// shows as the workspace error.
    @discardableResult
    private func run(
        afterQueued: Bool = true, _ build: (inout ClientReviewCommand) -> Void
    ) async -> ClientResult? {
        guard let core else { return nil }
        if afterQueued, let queued { await queued.value }
        var command = ClientReviewCommand()
        command.scope = scope
        build(&command)
        let sent = command, binding = bindingGeneration
        do {
            let result = try await core.dispatch(.with { $0.review = sent })
            if case .review(let slice)? = result.result { fold(slice) }
            return result
        } catch let failure as CoreFailure {
            if binding == bindingGeneration { workspaceError = failure.message }
            return nil
        } catch {
            return nil
        }
    }

    /// Reads the workspace; on return the review is at least as new as the call.
    func loadWorkspaceSurface() async {
        guard !bound.cardID.isEmpty else { return }
        await run { $0.refresh = ClientStep() }
    }

    func loadConversationDiff(path: String, commitSHA: String = "", append: Bool = false, retryStale: Bool = true) async
    {
        if append {
            await run { $0.loadMoreDiff = ClientStep() }
            return
        }
        if selectedChangePath != path || selectedCommitSHA != commitSHA {
            selectedChangePath = path; selectedCommitSHA = commitSHA
            conversationDiff = nil; diff = WorkspaceDiffLayout()
        }
        await run { command in
            command.select = .with {
                $0.path = path
                $0.commit = commitSHA
            }
        }
    }

    /// Comments on one line of the current revision.
    func addChangeComment(line: UnifiedDiffLine, body: String) async -> Bool {
        let author = authorName
        let result = await run { command in
            command.addComment = .with {
                $0.rowID = Int32(line.id)
                $0.body = body
                $0.author = author
            }
        }
        guard case .changeComment? = result?.result else { return false }
        return true
    }

    /// Starts a Git operation against the current revision from its form;
    /// the core builds the parameters and refuses a form that is not ready.
    func startGitOperation(form: ClientGitOperationForm) async -> Bool {
        guard !bound.cardID.isEmpty, !gitOperationSubmitting else { return false }
        let result = await run { command in command.start = form }
        guard case .gitOperation? = result?.result else { return false }
        return true
    }

    /// Starts `kind` with the form the core fills from the conversation.
    func startGitOperation(_ kind: GitOperationKind) async -> Bool {
        await startGitOperation(form: kind.form(card: card).initial)
    }

    func cancelCurrentGitOperation() async {
        guard operationCancelable else { return }
        await run { $0.cancelOperation = ClientStep() }
    }

    func showWorkspaceToast(_ message: String) {
        workspaceToast = WorkspaceToast(message: message)
        workspaceToastTask?.cancel()
        workspaceToastTask = Task { [weak self] in
            try? await DieterTaskSleep.seconds(6)
            guard !Task.isCancelled else { return }
            self?.workspaceToast = nil
        }
    }

    /// Commits dirty work when needed, merges into the base branch, then
    /// optionally removes the workspace and moves the card to Done. Each
    /// stage is an ordinary Git operation, so progress, logs, and failures
    /// show through the usual operation state.
    @discardableResult
    func performMergeFlow(
        strategy: String,
        subject: String,
        body: String,
        validate: Bool,
        removeWorkspace: Bool,
        moveCardToDone: Bool
    ) async -> Bool {
        guard mergeFlowStep == nil, card != nil else { return false }
        let result = await run { command in
            command.merge = .with {
                $0.strategy = strategy
                $0.subject = subject
                $0.body = body
                $0.validate = validate
                $0.removeWorkspace = removeWorkspace
                $0.moveToDone = moveCardToDone
            }
        }
        guard case .outcome(let outcome)? = result?.result else { return false }
        return outcome.succeeded
    }

}

extension UnifiedDiffLine {
    /// A row of the core's numbered diff.
    init(_ row: ClientDiffRow) {
        let kind: Kind =
            switch row.kind {
            case .header: .header
            case .hunk: .hunk
            case .addition: .addition
            case .deletion: .deletion
            default: .context
            }
        self.init(
            id: Int(row.id), kind: kind, text: row.text, oldLine: row.oldLine == 0 ? nil : Int(row.oldLine),
            newLine: row.newLine == 0 ? nil : Int(row.newLine))
    }
}

extension WorkspaceActionAvailability {
    init(_ core: ClientWorkspaceAvailability) {
        self.init(
            allowed: Set(core.allowed), allowsMergeFlow: core.allowsMergeFlow, hasReviewBranch: core.hasReviewBranch_p,
            workspaceMode: core.mode, mergeDestination: core.mergeDestination)
    }
}
