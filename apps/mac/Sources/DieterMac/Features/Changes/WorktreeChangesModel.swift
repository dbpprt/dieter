import DieterAPI
import DieterCore
import Foundation
import Observation

@MainActor @Observable
final class WorktreeChangesModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    var card: Dieter_V1_Card?
    var doneLaneID: String?
    var authorName = ""
    var conversationWorkspace: Dieter_V1_Workspace?
    var conversationChangeset: Dieter_V1_Changeset?
    var conversationDiff: Dieter_V1_FileDiff?
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
    var gitReconciliationGeneration: UInt64 = 0
    var gitOperationSubmissionID: UUID?
    @ObservationIgnored var workspaceRequestGeneration: UInt64 = 0
    @ObservationIgnored var diffRequestGeneration: UInt64 = 0
    @ObservationIgnored var workspaceRefreshTask: Task<Void, Never>?
    @ObservationIgnored var workspaceRefreshAgain = false
    @ObservationIgnored var gitOperationTask: Task<Void, Never>?
    @ObservationIgnored var workspaceToastTask: Task<Void, Never>?
    @ObservationIgnored private var rpc: (any WorktreeRPC)?
    private(set) var bindingGeneration: UInt64 = 0
    @ObservationIgnored var onCard: @MainActor (Dieter_V1_Card) -> Void = { _ in }
    @ObservationIgnored var onTransportFailure: @MainActor (Error, any WorktreeRPC) -> Void = { _, _ in }
    @ObservationIgnored var onOperationFinished: @MainActor (WorkspaceTarget) async -> Void = { _ in }
    @ObservationIgnored var onOpenFiles: @MainActor (Dieter_V1_Card, String?) async -> Void = { _, _ in }
    @ObservationIgnored var onOpenTerminal: @MainActor (Dieter_V1_Card) async -> Void = { _ in }
    @ObservationIgnored var onSendMessage: @MainActor (String, Dieter_V1_Card, WorkspaceTarget) async -> Bool = {
        _, _, _ in false
    }

    func openWorkspaceFiles(card: Dieter_V1_Card, opening path: String? = nil) async { await onOpenFiles(card, path) }
    func openWorkspaceTerminal(card: Dieter_V1_Card) async { await onOpenTerminal(card) }
    func sendAgentMessage(_ text: String) async -> Bool {
        guard let card else { return false }
        let binding = bindingGeneration
        let sent = await onSendMessage(text, card, target)
        return owns(binding) && sent
    }

    private var cardID: String? { target.conversationID.isEmpty ? nil : target.conversationID }

    func bind(target: WorkspaceTarget, client: (any WorktreeRPC)?, card: Dieter_V1_Card?, doneLaneID: String?) {
        if self.target != target || rpc !== client {
            resetWorkspaceSurface()
            self.target = target; rpc = client
        }
        self.card = card; self.doneLaneID = doneLaneID
    }

    private func owns(_ binding: UInt64) -> Bool { binding == bindingGeneration && !Task.isCancelled }
    private func acceptWorkspaceCard(_ card: Dieter_V1_Card) {
        if self.card?.id == card.id { self.card = card }
        onCard(card)
    }

    func resetWorkspaceSurface() {
        bindingGeneration &+= 1
        gitOperationTask?.cancel(); gitOperationTask = nil
        workspaceToastTask?.cancel(); workspaceToastTask = nil
        workspaceToast = nil; mergeFlowStep = nil
        workspaceRequestGeneration &+= 1; diffRequestGeneration &+= 1
        workspaceRefreshTask?.cancel(); workspaceRefreshTask = nil; workspaceRefreshAgain = false
        conversationDiffLoading = false
        gitOperationSubmitting = false
        gitOperationNeedsReconciliation = false
        gitReconciliationGeneration &+= 1
        gitOperationSubmissionID = nil
        conversationWorkspace = nil
        conversationChangeset = nil
        conversationDiff = nil
        conversationChangeComments = []
        conversationSCMCapabilities = nil
        gitOperation = nil
        gitOperationLogs = []
        workspaceLoading = false
        workspaceError = nil
        selectedChangePath = ""
        selectedCommitSHA = ""
    }

    func loadWorkspaceSurface() async {
        if let workspaceRefreshTask {
            workspaceRefreshAgain = true
            await workspaceRefreshTask.value
            return
        }
        guard let rpc, let cardID = self.cardID,
            DieterConversationID.isServerBacked(cardID)
        else { return }
        workspaceRequestGeneration &+= 1
        let generation = workspaceRequestGeneration
        workspaceLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.workspaceRequestGeneration == generation {
                    self.workspaceLoading = false
                    self.workspaceRefreshTask = nil
                }
            }
            repeat {
                self.workspaceRefreshAgain = false
                await self.readWorkspaceSurface(rpc: rpc, cardID: cardID, generation: generation)
            } while self.workspaceRefreshAgain && self.workspaceRequestGeneration == generation && !Task.isCancelled
        }
        workspaceRefreshTask = task
        await task.value
    }

    private func readWorkspaceSurface(rpc: any WorktreeRPC, cardID: String, generation: UInt64) async {
        let reconciliationGeneration = gitReconciliationGeneration
        func ownsRequest() -> Bool {
            !Task.isCancelled && self.rpc === rpc && workspaceRequestGeneration == generation
                && (self.cardID) == cardID
        }
        do {
            async let workspaceValue = rpc.workspace(cardID: cardID)
            async let changesetValue = rpc.changeset(cardID: cardID)
            let (workspace, changes) = try await (workspaceValue, changesetValue)
            guard ownsRequest() else { return }
            let revisionChanged = conversationChangeset?.revision != changes.revision
            var comments = conversationChangeComments
            if revisionChanged {
                comments = try await rpc.changeComments(cardID: cardID, revision: changes.revision).comments
            }
            guard ownsRequest() else { return }
            var capabilities = conversationSCMCapabilities
            if capabilities == nil { capabilities = try await rpc.scmCapabilities(cardID: cardID) }
            guard ownsRequest() else { return }
            if conversationWorkspace != workspace { conversationWorkspace = workspace }
            if conversationChangeset != changes { conversationChangeset = changes }
            if conversationChangeComments != comments { conversationChangeComments = comments }
            conversationSCMCapabilities = capabilities
            if gitReconciliationGeneration == reconciliationGeneration { gitOperationNeedsReconciliation = false }
            workspaceError = nil
            acceptWorkspaceSummary(workspace)
            let selection = WorkspaceReviewSelectionResolver.resolve(
                currentPath: selectedChangePath, currentCommitSHA: selectedCommitSHA,
                filePaths: changes.files.map(\.path), commitSHAs: changes.commits.map(\.sha)
            )
            if selection.path.isEmpty && selection.commitSHA.isEmpty {
                diffRequestGeneration &+= 1
                selectedChangePath = ""; selectedCommitSHA = ""
                conversationDiff = nil; conversationDiffLoading = false
            } else if revisionChanged || conversationDiff == nil || selection.path != selectedChangePath
                || selection.commitSHA != selectedCommitSHA
            {
                await loadConversationDiff(path: selection.path, commitSHA: selection.commitSHA, retryStale: false)
            }
            guard ownsRequest() else { return }
            let observed = gitOperation?.cardID == cardID ? gitOperation : nil
            if let operationID = GitOperationReconciliation.operationID(
                workspaceOperationID: workspace.currentOperationID,
                observedOperationID: observed?.id, observedStatus: observed?.status
            ) {
                await resumeGitOperation(id: operationID)
            }
        } catch {
            guard ownsRequest() else { return }
            workspaceError = DieterRPCFailure.message(for: error)
        }
    }

    func loadConversationDiff(path: String, commitSHA: String = "", append: Bool = false, retryStale: Bool = true) async
    {
        guard let rpc, let cardID = self.cardID,
            let changes = conversationChangeset
        else { return }
        if append, conversationDiffLoading { return }
        if selectedChangePath != path || selectedCommitSHA != commitSHA { conversationDiff = nil }
        selectedChangePath = path; selectedCommitSHA = commitSHA
        diffRequestGeneration &+= 1
        let generation = diffRequestGeneration
        conversationDiffLoading = true
        defer { if generation == diffRequestGeneration { conversationDiffLoading = false } }
        var request = Dieter_V1_GetDiffRequest()
        request.cardID = cardID; request.path = path; request.commitSha = commitSHA
        request.expectedRevision = changes.revision; request.limit = 1_048_576
        let previous = append ? conversationDiff : nil
        if let previous { request.offset = previous.nextOffset }
        func ownsRequest() -> Bool {
            !Task.isCancelled && self.rpc === rpc && diffRequestGeneration == generation
                && (self.cardID) == cardID && conversationChangeset?.revision == changes.revision
                && selectedChangePath == path && selectedCommitSHA == commitSHA
        }
        do {
            var page = try await (commitSHA.isEmpty ? rpc.fileDiff(request) : rpc.commitDiff(request))
            guard ownsRequest() else { return }
            if let previous { page.patch = previous.patch + page.patch }
            conversationDiff = page
        } catch {
            guard ownsRequest() else { return }
            let message = DieterRPCFailure.message(for: error)
            workspaceError = message
            if retryStale
                && (message.localizedCaseInsensitiveContains("refresh")
                    || message.localizedCaseInsensitiveContains("revision"))
            {
                await loadWorkspaceSurface()
            }
        }
    }

    func addChangeComment(path: String, side: String, line: Int32, body: String) async -> Bool {
        guard let rpc, let cardID = self.cardID,
            let changes = conversationChangeset
        else { return false }
        var request = Dieter_V1_AddChangeCommentRequest()
        request.cardID = cardID; request.path = path; request.side = side; request.line = line
        request.body = body; request.author = authorName; request.revision = changes.revision
        let binding = bindingGeneration
        do {
            let value = try await rpc.addChangeComment(request)
            guard owns(binding), conversationChangeset?.revision == changes.revision else { return false }
            conversationChangeComments.append(value)
            return true
        } catch {
            if owns(binding) { workspaceError = DieterRPCFailure.message(for: error) }
            return false
        }
    }

    func updateConversationWorkspace(_ draft: ConversationWorkspaceDraft) async -> Bool {
        guard let rpc, let cardID = self.cardID else { return false }
        var request = Dieter_V1_UpdateConversationWorkspaceRequest()
        request.cardID = cardID; request.mode = draft.mode.rawValue
        request.branch = draft.mode == .worktree ? draft.branch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        request.baseBranch =
            draft.mode == .worktree ? draft.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let binding = bindingGeneration
        do {
            let card = try await rpc.updateConversationWorkspace(request)
            guard owns(binding) else { return false }
            acceptWorkspaceCard(card)
            return true
        } catch {
            if owns(binding) { workspaceError = DieterRPCFailure.message(for: error) }
            return false
        }
    }

    func startGitOperation(
        _ kind: GitOperationKind, cardID explicitCardID: String? = nil, parameters: [String: String] = [:]
    ) async -> Bool {
        guard !gitOperationSubmitting, let rpc, let cardID = explicitCardID ?? self.cardID else { return false }
        let submissionID = UUID()
        gitOperationSubmissionID = submissionID
        gitOperationSubmitting = true
        defer {
            if gitOperationSubmissionID == submissionID {
                gitOperationSubmitting = false; gitOperationSubmissionID = nil
            }
        }
        var request = Dieter_V1_StartGitOperationRequest()
        request.cardID = cardID; request.kind = kind.rawValue
        if explicitCardID == nil || explicitCardID == self.cardID {
            request.expectedRevision = conversationChangeset?.revision ?? ""
        }
        request.parameters = parameters
        do {
            let operation = try await rpc.startGitOperation(request)
            guard self.rpc === rpc, gitOperationSubmissionID == submissionID else { return false }
            if GitOperationStatus.terminal(operation.status) { requireGitReconciliation() }
            gitOperation = operation
            gitOperationLogs = []
            observeGitOperation(id: operation.id, after: 0)
            return true
        } catch {
            guard self.rpc === rpc, gitOperationSubmissionID == submissionID else { return false }
            workspaceError = DieterRPCFailure.message(for: error)
            return false
        }
    }

    func cancelCurrentGitOperation() async {
        guard let rpc, let operation = gitOperation, GitOperationStatus.active(operation.status) else { return }
        let binding = bindingGeneration
        do {
            let updated = try await rpc.cancelGitOperation(id: operation.id)
            guard owns(binding), gitOperation?.id == operation.id else { return }
            gitOperation = updated
        } catch { if owns(binding) { workspaceError = DieterRPCFailure.message(for: error) } }
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

    /// Runs the full merge flow the merge sheet offers: commit dirty work when
    /// needed, merge into the base branch, then optionally remove the workspace
    /// and move the card to Done. Each stage is an ordinary Git operation, so
    /// progress, logs, and failures surface through the usual operation state.
    @discardableResult
    func performMergeFlow(
        strategy: String,
        subject: String,
        body: String,
        validate: Bool,
        removeWorkspace: Bool,
        moveCardToDone: Bool
    ) async -> Bool {
        guard mergeFlowStep == nil, let card = self.card, let rpc else { return false }
        let binding = bindingGeneration
        let branch = conversationWorkspace?.branch ?? card.workspace.branch
        var base = conversationWorkspace?.baseBranch ?? card.workspace.baseBranch
        if base.isEmpty { base = "base" }
        defer { if binding == bindingGeneration { mergeFlowStep = nil } }

        if conversationWorkspace?.dirty == true {
            guard owns(binding) else { return false }
            mergeFlowStep = .commit
            guard
                await startGitOperation(
                    .commit,
                    parameters: [
                        "subject": subject, "body": body, "include_untracked": "true",
                    ]), await awaitCurrentGitOperationSuccess()
            else { return false }
            await loadWorkspaceSurface()
        }

        guard owns(binding) else { return false }
        mergeFlowStep = .merge
        guard
            await startGitOperation(
                .mergeLocal,
                parameters: [
                    "strategy": strategy, "subject": subject, "validate": validate ? "true" : "false",
                ]), await awaitCurrentGitOperationSuccess()
        else { return false }

        if removeWorkspace {
            guard owns(binding) else { return false }
            mergeFlowStep = .cleanup
            await loadWorkspaceSurface()
            guard owns(binding), await startGitOperation(.cleanup),
                await awaitCurrentGitOperationSuccess()
            else { return false }
        }

        guard owns(binding) else { return false }
        var movedToDone = false
        if moveCardToDone, card.scope != "chat", let lane = doneLaneID, card.lane != lane {
            var request = Dieter_V1_MoveCardRequest(); request.cardID = card.id; request.lane = lane
            do {
                let moved = try await rpc.moveCard(request)
                guard owns(binding) else { return false }
                acceptWorkspaceCard(moved)
            } catch {
                if owns(binding) { workspaceError = DieterRPCFailure.message(for: error) }
                return false
            }
            movedToDone = true
        }
        let mergedLabel = branch.isEmpty ? "workspace" : branch
        showWorkspaceToast("Merged \(mergedLabel) into \(base)" + (movedToDone ? " · card moved to Done" : ""))
        return true
    }

    /// Waits for the operation started last to settle. Polls the daemon
    /// directly so orchestration survives a dropped watch stream.
    func awaitCurrentGitOperationSuccess() async -> Bool {
        guard let id = gitOperation?.id, let rpc else { return false }
        let binding = bindingGeneration
        let deadline = Date().addingTimeInterval(3_600)
        while Date() < deadline, owns(binding) {
            if let current = gitOperation, current.id == id,
                GitOperationStatus.terminal(current.status) || current.status == "waiting_for_resolution"
            {
                return current.status == "succeeded"
            }
            if let polled = try? await rpc.gitOperation(id: id), owns(binding),
                GitOperationStatus.terminal(polled.status) || polled.status == "waiting_for_resolution"
            {
                if gitOperation?.id == id { gitOperation = polled }
                return polled.status == "succeeded"
            }
            try? await DieterTaskSleep.milliseconds(400)
        }
        return false
    }

    func resumeGitOperation(id: String) async {
        guard let rpc else { return }
        let binding = bindingGeneration
        do {
            let operation = try await rpc.gitOperation(id: id)
            guard owns(binding), self.rpc === rpc, operation.cardID == cardID else { return }
            let changedOperation = gitOperation?.id != id
            if GitOperationStatus.terminal(operation.status),
                changedOperation || gitOperation?.status != operation.status
            {
                requireGitReconciliation()
                workspaceRefreshAgain = true
            }
            gitOperation = operation
            if changedOperation {
                gitOperationLogs = []
                if GitOperationStatus.active(operation.status) { observeGitOperation(id: id, after: 0) }
            } else if GitOperationStatus.terminal(operation.status) {
                gitOperationTask?.cancel()
                gitOperationTask = nil
            }
        } catch { if owns(binding) { workspaceError = DieterRPCFailure.message(for: error) } }
    }

    func observeGitOperation(id: String, after sequence: UInt64) {
        gitOperationTask?.cancel()
        let binding = bindingGeneration
        gitOperationTask = Task { [weak self] in
            guard let self, let rpc = self.rpc else { return }
            do {
                try await rpc.watchGitOperation(id: id, after: sequence) { [weak self] frame in
                    if await self?.acceptGitOperationFrame(frame, operationID: id, binding: binding) == true {
                        await self?.loadWorkspaceSurface()
                    }
                }
                guard self.owns(binding), self.gitOperation?.id == id else { return }
                let selectedConversationID = self.cardID
                if self.gitOperation?.cardID == selectedConversationID {
                    let removesWorkspace =
                        ["cleanup", "discard", "adopt"].contains(self.gitOperation?.kind ?? "")
                        && self.gitOperation?.status == "succeeded"
                    if removesWorkspace {
                        self.clearWorkspaceContentPreservingOperation()
                    } else {
                        await self.loadWorkspaceSurface()
                    }
                }
                guard self.owns(binding) else { return }
                await self.onOperationFinished(self.target)
            } catch {
                guard self.owns(binding), !DieterRPCFailure.isCancellation(error) else { return }
                if DieterRPCFailure.isTransient(error) {
                    self.onTransportFailure(error, rpc)
                } else {
                    self.workspaceError = DieterRPCFailure.message(for: error)
                }
            }
        }
    }

    func acceptGitOperationFrame(_ frame: Dieter_V1_GitOperationFrame, operationID: String, binding: UInt64? = nil)
        -> Bool
    {
        guard binding == nil || binding == bindingGeneration, gitOperation?.id == operationID else { return false }
        let enteredConflict =
            gitOperation?.status != "waiting_for_resolution" && frame.operation.status == "waiting_for_resolution"
        if GitOperationStatus.terminal(frame.operation.status), gitOperation?.status != frame.operation.status {
            requireGitReconciliation()
        }
        gitOperation = frame.operation
        let known = Set(gitOperationLogs.map(\.sequence))
        gitOperationLogs.append(contentsOf: frame.logs.filter { !known.contains($0.sequence) })
        var retainedBytes = 0, retainedCount = 0
        for entry in gitOperationLogs.reversed().prefix(2_000) {
            let bytes = entry.message.utf8.count
            guard retainedBytes + bytes <= 8 * 1_024 * 1_024 else { break }
            retainedBytes += bytes; retainedCount += 1
        }
        if retainedCount < gitOperationLogs.count {
            gitOperationLogs.removeFirst(gitOperationLogs.count - retainedCount)
        }
        return enteredConflict
    }

    func clearWorkspaceContentPreservingOperation() {
        workspaceRequestGeneration &+= 1; diffRequestGeneration &+= 1
        workspaceRefreshTask?.cancel(); workspaceRefreshTask = nil; workspaceRefreshAgain = false
        conversationDiffLoading = false
        gitOperationNeedsReconciliation = false
        conversationWorkspace = nil
        conversationChangeset = nil
        conversationDiff = nil
        conversationChangeComments = []
        conversationSCMCapabilities = nil
        selectedChangePath = ""
        selectedCommitSHA = ""
        workspaceLoading = false
        workspaceError = nil
    }

    private func requireGitReconciliation() {
        gitReconciliationGeneration &+= 1
        gitOperationNeedsReconciliation = true
    }

    func acceptWorkspaceSummary(_ workspace: Dieter_V1_Workspace) {
        guard var card = self.card, card.id == workspace.cardID else { return }
        card.workspace.mode = workspace.mode
        card.workspace.state = workspace.state
        card.workspace.branch = workspace.branch
        card.workspace.baseBranch = workspace.baseBranch
        card.workspace.headSha = workspace.headSha
        card.workspace.baseSha = workspace.baseSha
        card.workspace.revision = workspace.revision
        card.workspace.changedFiles = workspace.changedFiles
        card.workspace.additions = workspace.additions
        card.workspace.deletions = workspace.deletions
        card.workspace.ahead = workspace.ahead
        card.workspace.behind = workspace.behind
        card.workspace.currentOperationID = workspace.currentOperationID
        acceptWorkspaceCard(card)
    }

}
