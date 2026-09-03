import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func loadWorkspaceSurface() async {
        guard let rpc, let cardID = selectedCardID ?? selectedChatID,
              DieterConversationID.isServerBacked(cardID) else { return }
        workspaceLoading = true
        workspaceError = nil
        do {
            async let workspaceValue = rpc.workspace(cardID: cardID)
            async let changesetValue = rpc.changeset(cardID: cardID)
            async let capabilitiesValue = rpc.scmCapabilities(cardID: cardID)
            let (workspace, changes, capabilities) = try await (workspaceValue, changesetValue, capabilitiesValue)
            guard (selectedCardID ?? selectedChatID) == cardID else { return }
            conversationWorkspace = workspace
            conversationChangeset = changes
            conversationSCMCapabilities = capabilities
            acceptWorkspaceSummary(workspace)
            conversationChangeComments = try await rpc.changeComments(cardID: cardID, revision: changes.revision).comments

            let selection = WorkspaceReviewSelectionResolver.resolve(
                currentPath: selectedChangePath,
                currentCommitSHA: selectedCommitSHA,
                filePaths: changes.files.map(\.path),
                commitSHAs: changes.commits.map(\.sha)
            )
            if selection.path != selectedChangePath || selection.commitSHA != selectedCommitSHA {
                conversationDiff = nil
            }
            selectedChangePath = selection.path
            selectedCommitSHA = selection.commitSHA
            if !selection.commitSHA.isEmpty {
                await loadConversationDiff(path: "", commitSHA: selection.commitSHA)
            } else if !selection.path.isEmpty {
                await loadConversationDiff(path: selection.path)
            } else {
                conversationDiff = nil
            }
            let observed = gitOperation?.cardID == cardID ? gitOperation : nil
            if let operationID = GitOperationReconciliation.operationID(
                workspaceOperationID: workspace.currentOperationID,
                observedOperationID: observed?.id,
                observedStatus: observed?.status
            ) {
                await resumeGitOperation(id: operationID)
            }
        } catch {
            guard (selectedCardID ?? selectedChatID) == cardID else { return }
            workspaceError = DieterRPCFailure.message(for: error)
        }
        workspaceLoading = false
    }

    func loadConversationDiff(path: String, commitSHA: String = "", append: Bool = false) async {
        guard let rpc, let cardID = selectedCardID ?? selectedChatID,
              let changes = conversationChangeset else { return }
        selectedChangePath = path
        selectedCommitSHA = commitSHA
        var request = Dieter_V1_GetDiffRequest()
        request.cardID = cardID
        request.path = path
        request.commitSha = commitSHA
        request.expectedRevision = changes.revision
        request.limit = 1_048_576
        if append, let current = conversationDiff { request.offset = current.nextOffset }
        do {
            let page = try await (commitSHA.isEmpty ? rpc.fileDiff(request) : rpc.commitDiff(request))
            guard (selectedCardID ?? selectedChatID) == cardID,
                  selectedChangePath == path, selectedCommitSHA == commitSHA else { return }
            if append, var current = conversationDiff {
                current.patch += page.patch
                current.truncated = page.truncated
                current.nextOffset = page.nextOffset
                current.totalBytes = page.totalBytes
                conversationDiff = current
            } else {
                conversationDiff = page
            }
        } catch {
            let message = DieterRPCFailure.message(for: error)
            if message.localizedCaseInsensitiveContains("refresh") || message.localizedCaseInsensitiveContains("revision") {
                workspaceError = "The workspace changed while this diff was open. Refreshing…"
                await loadWorkspaceSurface()
            } else {
                workspaceError = message
            }
        }
    }

    func addChangeComment(path: String, side: String, line: Int32, body: String) async -> Bool {
        guard let rpc, let cardID = selectedCardID ?? selectedChatID,
              let changes = conversationChangeset else { return false }
        var request = Dieter_V1_AddChangeCommentRequest()
        request.cardID = cardID; request.path = path; request.side = side; request.line = line
        request.body = body; request.author = NSFullUserName(); request.revision = changes.revision
        do {
            let value = try await rpc.addChangeComment(request)
            conversationChangeComments.append(value)
            return true
        } catch {
            workspaceError = DieterRPCFailure.message(for: error)
            return false
        }
    }

    func updateConversationWorkspace(_ draft: ConversationWorkspaceDraft) async -> Bool {
        guard let rpc, let cardID = selectedCardID ?? selectedChatID else { return false }
        var request = Dieter_V1_UpdateConversationWorkspaceRequest()
        request.cardID = cardID; request.mode = draft.mode.rawValue
        request.branch = draft.mode == .worktree ? draft.branch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        request.baseBranch = draft.mode == .worktree ? draft.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        do {
            let card = try await rpc.updateConversationWorkspace(request)
            acceptWorkspaceCard(card)
            return true
        } catch {
            workspaceError = DieterRPCFailure.message(for: error)
            return false
        }
    }

    func updateProjectWorkspaceSettings(
        remote: String,
        branch: String,
        validationCommands: [Dieter_V1_ValidationCommand]
    ) async -> Bool {
        guard let rpc, !selectedProjectID.isEmpty else { return false }
        var request = Dieter_V1_UpdateProjectWorkspaceSettingsRequest()
        request.projectID = selectedProjectID
        request.baseRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        request.baseBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        request.validationCommands = validationCommands
        do {
            acceptProject(try await rpc.updateProjectWorkspaceSettings(request))
            return true
        } catch {
            show(error)
            return false
        }
    }

    func loadProjectWorkspaces() async {
        guard let rpc, !selectedProjectID.isEmpty else { return }
        do { projectWorkspaces = try await rpc.projectWorkspaces(projectID: selectedProjectID).workspaces }
        catch { workspaceError = DieterRPCFailure.message(for: error) }
    }

    func startGitOperation(_ kind: GitOperationKind, cardID explicitCardID: String? = nil, parameters: [String: String] = [:]) async -> Bool {
        guard let rpc, let cardID = explicitCardID ?? selectedCardID ?? selectedChatID else { return false }
        var request = Dieter_V1_StartGitOperationRequest()
        request.cardID = cardID; request.kind = kind.rawValue
        if explicitCardID == nil || explicitCardID == selectedCardID || explicitCardID == selectedChatID {
            request.expectedRevision = conversationChangeset?.revision ?? ""
        }
        request.parameters = parameters
        do {
            let operation = try await rpc.startGitOperation(request)
            gitOperation = operation
            gitOperationLogs = []
            observeGitOperation(id: operation.id, after: 0)
            return true
        } catch {
            workspaceError = DieterRPCFailure.message(for: error)
            return false
        }
    }

    func cancelCurrentGitOperation() async {
        guard let rpc, let operation = gitOperation, GitOperationStatus.active(operation.status) else { return }
        do { gitOperation = try await rpc.cancelGitOperation(id: operation.id) }
        catch { workspaceError = DieterRPCFailure.message(for: error) }
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
        guard mergeFlowStep == nil, let card = selectedCard ?? selectedDetail?.card else { return false }
        let branch = conversationWorkspace?.branch ?? card.workspace.branch
        var base = conversationWorkspace?.baseBranch ?? card.workspace.baseBranch
        if base.isEmpty { base = "base" }
        defer { mergeFlowStep = nil }

        if conversationWorkspace?.dirty == true {
            mergeFlowStep = .commit
            guard await startGitOperation(.commit, parameters: [
                "subject": subject, "body": body, "include_untracked": "true",
            ]), await awaitCurrentGitOperationSuccess() else { return false }
            await loadWorkspaceSurface()
        }

        mergeFlowStep = .merge
        guard await startGitOperation(.mergeLocal, parameters: [
            "strategy": strategy, "subject": subject, "validate": validate ? "true" : "false",
        ]), await awaitCurrentGitOperationSuccess() else { return false }

        if removeWorkspace {
            mergeFlowStep = .cleanup
            await loadWorkspaceSurface()
            if await startGitOperation(.cleanup) {
                _ = await awaitCurrentGitOperationSuccess()
            }
        }

        var movedToDone = false
        if moveCardToDone, card.scope != "chat", let lane = doneLane(for: card), card.lane != lane {
            await move(card, lane: lane)
            movedToDone = true
        }
        let mergedLabel = branch.isEmpty ? "workspace" : branch
        showWorkspaceToast("Merged \(mergedLabel) into \(base)" + (movedToDone ? " · card moved to Done" : ""))
        return true
    }

    /// Waits for the operation started last to settle. Polls the daemon
    /// directly so orchestration survives a dropped watch stream.
    func awaitCurrentGitOperationSuccess() async -> Bool {
        guard let id = gitOperation?.id else { return false }
        let deadline = Date().addingTimeInterval(3_600)
        while Date() < deadline, !Task.isCancelled {
            if let current = gitOperation, current.id == id,
               GitOperationStatus.terminal(current.status) || current.status == "waiting_for_resolution" {
                return current.status == "succeeded"
            }
            if let rpc, let polled = try? await rpc.gitOperation(id: id),
               GitOperationStatus.terminal(polled.status) || polled.status == "waiting_for_resolution" {
                if gitOperation?.id == id { gitOperation = polled }
                return polled.status == "succeeded"
            }
            try? await DieterTaskSleep.milliseconds(400)
        }
        return false
    }

    func doneLane(for card: Dieter_V1_Card) -> String? {
        let lanes = selectedDetail?.board.id == card.boardID
            ? selectedDetail?.board.lanes
            : boards(for: card.projectID).first { $0.id == card.boardID }?.lanes
        guard let lanes, !lanes.isEmpty else { return nil }
        return lanes.first { $0.id == "done" }?.id ?? lanes.last?.id
    }

    /// Sends a hand-off message into the conversation on the person's behalf,
    /// e.g. "resolve the merge conflicts" or "address the review".
    @discardableResult
    func sendAgentMessage(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = selectedCardID ?? selectedChatID else { return false }
        let card = selectedCard ?? selectedDetail?.card
        let targetEndpointID = projectEndpointIDs[card?.projectID ?? ""] ?? endpoint.id
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text = trimmed
        var request = Dieter_V1_SendMessageRequest()
        request.cardID = id
        request.parts = [part]
        request.provider = card?.provider ?? ""
        request.model = card?.model ?? ""
        request.effort = card?.effort ?? ""
        request.providerOptions = card?.providerOptions ?? [:]
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        request.messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            syncDiskState.outbox.append(DieterOutboxEntry(
                commandID: request.commandID,
                clientID: syncClientID,
                endpointID: targetEndpointID,
                kind: .sendMessage,
                request: try request.serializedData(),
                optimisticID: request.messageID,
                attempts: 0,
                createdAt: Date()
            ))
            await persistAndDrainOutbox()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func resumeGitOperation(id: String) async {
        guard let rpc else { return }
        do {
            let operation = try await rpc.gitOperation(id: id)
            guard operation.cardID == (selectedCardID ?? selectedChatID) else { return }
            let changedOperation = gitOperation?.id != id
            gitOperation = operation
            if changedOperation {
                gitOperationLogs = []
                if GitOperationStatus.active(operation.status) { observeGitOperation(id: id, after: 0) }
            } else if GitOperationStatus.terminal(operation.status) {
                gitOperationTask?.cancel()
                gitOperationTask = nil
            }
        } catch { workspaceError = DieterRPCFailure.message(for: error) }
    }

    func observeGitOperation(id: String, after sequence: UInt64) {
        gitOperationTask?.cancel()
        gitOperationTask = Task { [weak self] in
            guard let self, let rpc = self.rpc else { return }
            do {
                try await rpc.watchGitOperation(id: id, after: sequence) { [weak self] frame in
                    if await self?.acceptGitOperationFrame(frame, operationID: id) == true {
                        await self?.loadWorkspaceSurface()
                    }
                }
                guard !Task.isCancelled, self.gitOperation?.id == id else { return }
                let selectedConversationID = self.selectedCardID ?? self.selectedChatID
                if self.gitOperation?.cardID == selectedConversationID {
                    let removesWorkspace = ["cleanup", "discard", "adopt"].contains(self.gitOperation?.kind ?? "")
                        && self.gitOperation?.status == "succeeded"
                    if removesWorkspace {
                        self.clearWorkspaceContentPreservingOperation()
                    } else {
                        await self.loadWorkspaceSurface()
                    }
                }
                await self.loadProjectWorkspaces()
                await self.refreshState()
            } catch {
                guard !Self.isExpectedCancellation(error) else { return }
                if DieterRPCFailure.isTransient(error) {
                    self.connectionStopped(error, client: rpc)
                } else {
                    self.workspaceError = DieterRPCFailure.message(for: error)
                }
            }
        }
    }

    func acceptGitOperationFrame(_ frame: Dieter_V1_GitOperationFrame, operationID: String) -> Bool {
        guard gitOperation?.id == operationID else { return false }
        let enteredConflict = gitOperation?.status != "waiting_for_resolution" && frame.operation.status == "waiting_for_resolution"
        gitOperation = frame.operation
        let known = Set(gitOperationLogs.map(\.sequence))
        gitOperationLogs.append(contentsOf: frame.logs.filter { !known.contains($0.sequence) })
        return enteredConflict
    }

    func clearWorkspaceContentPreservingOperation() {
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

    func acceptWorkspaceCard(_ card: Dieter_V1_Card) {
        if let index = state.cards.firstIndex(where: { $0.id == card.id }) { state.cards[index] = card }
        if let index = state.chats.firstIndex(where: { $0.id == card.id }) { state.chats[index] = card }
        if let index = chats.firstIndex(where: { $0.id == card.id }) { chats[index] = card }
        if var cards = navigationCards[card.boardID], let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
            navigationCards[card.boardID] = cards
        }
        if var detail = selectedDetail, detail.card.id == card.id {
            detail.card = card
            selectedDetail = detail
        }
    }

    func acceptWorkspaceSummary(_ workspace: Dieter_V1_Workspace) {
        guard var card = selectedCard ?? selectedDetail?.card, card.id == workspace.cardID else { return }
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

    func listProjectDirectories(path: String, machineID: String) async throws -> Dieter_V1_DirectoryListing {
        guard let machine = machines.first(where: { $0.id == machineID }) ?? (endpoint.id == machineID ? endpoint : nil) else {
            throw NSError(domain: "DieterMachine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select an enrolled machine."])
        }
        guard machine.online else {
            throw NSError(domain: "DieterMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."])
        }
        var request = Dieter_V1_ListDirectoriesRequest()
        request.path = path
        if machine.id == endpoint.id, let rpc {
            return try await rpc.listDirectories(request)
        }
        guard let daemonID = machine.daemonID else {
            throw NSError(domain: "DieterMachine", code: 3, userInfo: [NSLocalizedDescriptionKey: "The project host has no daemon identity."])
        }
        let client = try DieterRPC(
            endpoint: machine,
            accessToken: await accessToken(for: machine),
            route: .relay(daemonID: daemonID)
        )
        let connection = Task { try? await client.run() }
        defer { connection.cancel(); client.shutdown() }
        return try await client.listDirectories(request)
    }

    func createProject(_ draft: ProjectSetupDraft, machineID: String? = nil) async throws -> Dieter_V1_CreateProjectResponse {
        let target: DieterEndpoint
        if let machineID {
            guard let selected = machines.first(where: { $0.id == machineID }) ?? (endpoint.id == machineID ? endpoint : nil) else {
                throw NSError(domain: "DieterMachine", code: 1, userInfo: [NSLocalizedDescriptionKey: "The project host is no longer enrolled."])
            }
            target = selected
        } else {
            target = endpoint
        }
        guard target.online else {
            throw NSError(domain: "DieterMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."])
        }
        let request = draft.request()
        let response: Dieter_V1_CreateProjectResponse
        if target.id == endpoint.id, let rpc {
            response = try await rpc.createProject(request)
        } else {
            guard let daemonID = target.daemonID else {
                throw NSError(domain: "DieterMachine", code: 3, userInfo: [NSLocalizedDescriptionKey: "The project host has no daemon identity."])
            }
            let client = try DieterRPC(
                endpoint: target,
                accessToken: await accessToken(for: target),
                route: .relay(daemonID: daemonID)
            )
            let connection = Task { try? await client.run() }
            defer {
                connection.cancel()
                client.shutdown()
            }
            response = try await client.createProject(request)
        }

        projectDirectory[response.project.id] = response.project
        projectEndpointIDs[response.project.id] = target.id
        navigationBoards[response.project.id] = [response.board]
        if target.id != endpoint.id { await connect(to: target) }
        selectedProjectID = response.project.id
        selectedBoardID = response.board.id
        section = .board
        await refreshState()
        await refreshNavigation()
        await refreshMachineDirectory()
        return response
    }

    func setProjectArchived(id: String, archived: Bool) async {
        guard await ensureProjectConnection(id) else { return }
        guard let rpc else { return }
        var request = Dieter_V1_ArchiveProjectRequest(); request.projectID = id; request.archived = archived
        do { _ = try await rpc.archiveProject(request); await refreshState(); await refreshNavigation(); await loadArchive() } catch { show(error) }
    }

    func renameProject(id: String, name: String) async {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, await ensureProjectConnection(id), let rpc else { return }
        var request = Dieter_V1_UpdateProjectRequest(); request.projectID = id; request.name = normalized
        do {
            _ = try await rpc.updateProject(request)
            renameProjectPresented = false
            await refreshState()
            await refreshNavigation()
        } catch { show(error) }
    }

    func updateProject(name: String, summary: String, prompt: String) async {
        guard await ensureProjectConnection(selectedProjectID) else { return }
        guard let rpc else { return }
        var request = Dieter_V1_UpdateProjectRequest(); request.projectID = selectedProjectID
        request.name = name; request.summary = summary; request.prompt = prompt
        do { _ = try await rpc.updateProject(request); projectContextPresented = false; await refreshState() } catch { show(error) }
    }

    func createBoard(name: String, workflow: String, description: String, doneArchivePolicy: String) async {
        do {
            guard let board = try await createBoard(
                projectID: selectedProjectID,
                name: name,
                workflow: workflow,
                description: description,
                doneArchivePolicy: doneArchivePolicy
            ) else { return }
            createBoardPresented = false
            selectedBoardID = board.id
            section = .board
            await refreshState()
            await refreshNavigation()
        } catch { show(error) }
    }

    func createBoard(
        projectID: String,
        name: String,
        workflow: String,
        description: String = "",
        doneArchivePolicy: String
    ) async throws -> Dieter_V1_Board? {
        guard let rpc else { return nil }
        var request = Dieter_V1_CreateBoardRequest()
        request.projectID = projectID
        request.name = name
        request.workflow = workflow
        request.description_p = description
        request.doneArchivePolicy = doneArchivePolicy
        return try await rpc.createBoard(request)
    }

    func renameBoard(id: String, name: String) async {
        guard let rpc else { return }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var request = Dieter_V1_RenameBoardRequest(); request.boardID = id; request.name = normalized
        do {
            let updated = try await rpc.renameBoard(request)
            if let index = state.boards.firstIndex(where: { $0.id == updated.id }) {
                var next = state
                next.boards[index] = updated
                state = next
            }
            if var boards = navigationBoards[updated.projectID],
               let index = boards.firstIndex(where: { $0.id == updated.id }) {
                boards[index] = updated
                navigationBoards[updated.projectID] = boards
            }
            renameBoardPresented = false
            renameBoardTargetID = ""
            await refreshState()
            await refreshNavigation()
        } catch { show(error) }
    }

    func setArchivePolicy(_ policy: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_SetBoardArchivePolicyRequest(); request.boardID = selectedBoardID; request.doneArchivePolicy = policy
        do { _ = try await rpc.setBoardArchivePolicy(request); archivePolicyPresented = false; await refreshState() } catch { show(error) }
    }

    func createLabel(name: String, color: String, instructions: String = "") async {
        guard let rpc else { return }
        var request = Dieter_V1_CreateBoardLabelRequest(); request.boardID = selectedBoardID; request.name = name; request.color = color; request.instructions = instructions
        do { acceptBoard(try await rpc.createBoardLabel(request)) } catch { show(error) }
    }

    func updateLabel(id: String, name: String, color: String, instructions: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_UpdateBoardLabelRequest()
        request.boardID = selectedBoardID; request.labelID = id; request.name = name; request.color = color; request.instructions = instructions
        do { acceptBoard(try await rpc.updateBoardLabel(request)) } catch { show(error) }
    }

    func deleteLabel(id: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_DeleteBoardLabelRequest(); request.boardID = selectedBoardID; request.labelID = id
        do { acceptBoard(try await rpc.deleteBoardLabel(request)) } catch { show(error) }
    }

    func acceptBoard(_ board: Dieter_V1_Board) {
        pendingBoards[board.id] = board
        var next = state
        if let index = next.boards.firstIndex(where: { $0.id == board.id }) { next.boards[index] = board }
        else if board.projectID == selectedProjectID { next.boards.append(board) }
        state = next
        if var boards = navigationBoards[board.projectID], let index = boards.firstIndex(where: { $0.id == board.id }) {
            boards[index] = board
            navigationBoards[board.projectID] = boards
        }
    }

    func acceptProject(_ project: Dieter_V1_Project) {
        pendingProjects[project.id] = project
        projectDirectory[project.id] = project
        var next = state
        if let index = next.projects.firstIndex(where: { $0.id == project.id }) { next.projects[index] = project }
        if next.project.id == project.id { next.project = project }
        state = next
    }
}
