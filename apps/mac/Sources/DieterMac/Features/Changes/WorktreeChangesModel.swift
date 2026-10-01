import DieterAPI
import DieterCore
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
    var doneLaneID: String?
    var authorName = ""
    var conversationWorkspace: Dieter_V1_Workspace?
    var conversationChangeset: Dieter_V1_Changeset?
    var conversationDiff: Dieter_V1_FileDiff?
    /// The diff's lines as the core numbers them; comments attach to one.
    var diffLines: [UnifiedDiffLine] = []
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
    /// A cleanup, discard, or adopt removed the workspace here.
    private(set) var surfaceRemoved = false
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
    @ObservationIgnored var onCard: @MainActor (Dieter_V1_Card) -> Void = { _ in }
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
    func bind(target: WorkspaceTarget, core: CoreClient?, card: Dieter_V1_Card?, doneLaneID: String?) {
        if subscription == nil, let core {
            self.core = core
            subscription = SliceSubscription(client: core, slice: .review, scope: scope) { [weak self] update in
                guard let self, case .review(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        self.card = card
        self.doneLaneID = doneLaneID
        guard self.target != target else { return }
        self.target = target
        resetWorkspaceSurface()
        let id = target.conversationID
        bound = ClientReviewTarget.with {
            $0.cardID = DieterConversationID.isServerBacked(id) ? id : ""
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
        conversationWorkspace = nil; conversationChangeset = nil; conversationDiff = nil; diffLines = []
        conversationChangeComments = []; conversationSCMCapabilities = nil
        gitOperation = nil; gitOperationLogs = []
        workspaceLoading = false; workspaceError = nil; conversationDiffLoading = false
        gitOperationSubmitting = false; gitOperationNeedsReconciliation = false
        selectedChangePath = ""; selectedCommitSHA = ""
        availability = WorkspaceActionAvailability(); surfaceRemoved = false
    }

    private func fold(_ slice: ClientReviewSlice) {
        guard slice.cardID == bound.cardID, slice.daemonID == bound.daemonID else { return }
        let workspace = slice.hasWorkspace ? slice.workspace : nil
        if conversationWorkspace != workspace { conversationWorkspace = workspace }
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
        let diff = slice.hasDiff ? slice.diff : nil
        if conversationDiff != diff { conversationDiff = diff }
        let lines = slice.diffRows.map(UnifiedDiffLine.init)
        if diffLines != lines { diffLines = lines }
        if conversationDiffLoading != slice.diffLoading { conversationDiffLoading = slice.diffLoading }
        let previous = gitOperation
        let operation = slice.hasOperation ? slice.operation : nil
        if gitOperation != operation { gitOperation = operation }
        if gitOperationLogs != slice.logs { gitOperationLogs = slice.logs }
        if gitOperationSubmitting != slice.submitting { gitOperationSubmitting = slice.submitting }
        if gitOperationNeedsReconciliation != slice.needsReconciliation {
            gitOperationNeedsReconciliation = slice.needsReconciliation
        }
        if surfaceRemoved != slice.surfaceRemoved { surfaceRemoved = slice.surfaceRemoved }
        let step = WorkspaceMergeStep(rawValue: slice.mergeStep)
        if mergeFlowStep != step { mergeFlowStep = step }
        let next =
            slice.hasAvailability ? WorkspaceActionAvailability(slice.availability) : WorkspaceActionAvailability()
        if availability != next { availability = next }
        if !slice.toast.isEmpty, slice.toast != shownToast {
            shownToast = slice.toast
            showWorkspaceToast(slice.toast)
            send { $0.clearToast_p = ClientReviewStep() }
        }
        // A finished operation can change the project's workspaces and board.
        if let previous, let operation, previous.id == operation.id,
            GitOperationStatus.active(previous.status), GitOperationStatus.terminal(operation.status)
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
        await run { $0.refresh = ClientReviewStep() }
    }

    func loadConversationDiff(path: String, commitSHA: String = "", append: Bool = false, retryStale: Bool = true) async
    {
        if append {
            await run { $0.loadMoreDiff = ClientReviewStep() }
            return
        }
        if selectedChangePath != path || selectedCommitSHA != commitSHA {
            selectedChangePath = path; selectedCommitSHA = commitSHA
            conversationDiff = nil; diffLines = []
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

    /// Changes the workspace before the first turn.
    func updateConversationWorkspace(_ draft: ConversationWorkspaceDraft) async -> Bool {
        guard !bound.cardID.isEmpty else { return false }
        let result = await run { command in
            command.updateSettings = .with {
                $0.mode = draft.mode.rawValue
                $0.branch = draft.branch
                $0.baseBranch = draft.baseBranch
                $0.baseRemote = draft.baseRemote
                $0.publishMode = draft.remotePublishMode
            }
        }
        return result != nil
    }

    /// Starts a Git operation against the current revision.
    func startGitOperation(_ kind: GitOperationKind, parameters: [String: String] = [:]) async -> Bool {
        guard !bound.cardID.isEmpty, !gitOperationSubmitting else { return false }
        let result = await run { command in
            command.start = .with {
                $0.kind = kind.rawValue
                $0.parameters = parameters
            }
        }
        guard case .gitOperation? = result?.result else { return false }
        return true
    }

    func cancelCurrentGitOperation() async {
        guard let operation = gitOperation, GitOperationStatus.active(operation.status) else { return }
        await run { $0.cancelOperation = ClientReviewStep() }
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

    /// Waits for the operation started last to settle.
    func awaitCurrentGitOperationSuccess() async -> Bool {
        guard let id = gitOperation?.id else { return false }
        let binding = bindingGeneration
        let deadline = ContinuousClock.now + .seconds(3_600)
        while binding == bindingGeneration, ContinuousClock.now < deadline, !Task.isCancelled {
            if let current = gitOperation, current.id == id,
                GitOperationStatus.terminal(current.status) || current.status == "waiting_for_resolution"
            {
                return current.status == "succeeded"
            }
            try? await DieterTaskSleep.milliseconds(100)
        }
        return false
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
            workspaceMode: core.mode, remotePublishMode: core.publish, mergeDestination: core.mergeDestination)
    }
}
