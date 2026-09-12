import AppKit
import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func bindWorktree() {
        let card = selectedCard ?? selectedDetail?.card
        worktreeChanges.bind(
            target: WorkspaceTarget(
                endpointID: endpoint.id, projectID: card?.projectID ?? selectedProjectID,
                conversationID: selectedCardID ?? selectedChatID ?? ""),
            client: card.map { isConversationServerBacked($0.id) } == true ? rpc : nil,
            card: card, doneLaneID: card.flatMap { doneLane(for: $0) }
        )
        worktreeChanges.authorName = NSFullUserName()
        worktreeChanges.onOpenFiles = { [weak self] card, path in
            await self?.openWorkspaceFiles(card: card, opening: path)
        }
        worktreeChanges.onOpenTerminal = { [weak self] card in
            await self?.openWorkspaceTerminal(card: card)
        }
        worktreeChanges.onSendMessage = { [weak self] text, card, target in
            await self?.sendAgentMessage(text, card: card, endpointID: target.endpointID) ?? false
        }
        worktreeChanges.onCard = { [weak self] card in self?.acceptWorkspaceCard(card) }
        worktreeChanges.onTransportFailure = { [weak self] error, client in
            guard let rpc = client as? DieterRPC else { return }
            self?.connectionStopped(error, client: rpc)
        }
        worktreeChanges.onOperationFinished = { [weak self] target in
            guard let self, self.endpoint.id == target.endpointID,
                self.selectedProjectID == target.projectID
            else {
                return
            }
            await self.loadProjectWorkspaces()
            guard self.endpoint.id == target.endpointID, self.selectedProjectID == target.projectID else {
                return
            }
            await self.refreshState()
        }
    }
    func loadWorkspaceSurface() async {
        bindWorktree()
        await worktreeChanges.loadWorkspaceSurface()
    }
    func loadConversationDiff(
        path: String, commitSHA: String = "", append: Bool = false, retryStale: Bool = true
    ) async {
        bindWorktree()
        await worktreeChanges.loadConversationDiff(
            path: path, commitSHA: commitSHA, append: append, retryStale: retryStale)
    }
    func addChangeComment(path: String, side: String, line: Int32, body: String) async -> Bool {
        bindWorktree()
        return await worktreeChanges.addChangeComment(path: path, side: side, line: line, body: body)
    }

    func updateConversationWorkspace(
        _ draft: ConversationWorkspaceDraft, cardID explicitCardID: String? = nil
    ) async -> Bool {
        guard let rpc, let cardID = explicitCardID ?? selectedCardID ?? selectedChatID else {
            return false
        }
        var request = Dieter_V1_UpdateConversationWorkspaceRequest()
        request.cardID = cardID
        request.mode = draft.mode.rawValue
        request.branch =
            draft.mode == .worktree ? draft.branch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        request.baseBranch =
            draft.mode == .worktree
            ? draft.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        request.baseRemote = draft.baseRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        request.remotePublishMode = draft.remotePublishMode
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
        do {
            projectWorkspaces = try await rpc.projectWorkspaces(projectID: selectedProjectID).workspaces
        } catch {
            workspaceError = DieterRPCFailure.message(for: error)
        }
    }

    func startGitOperation(
        _ kind: GitOperationKind, cardID: String? = nil, parameters: [String: String] = [:]
    ) async
        -> Bool
    {
        bindWorktree()
        return await worktreeChanges.startGitOperation(kind, cardID: cardID, parameters: parameters)
    }
    func cancelCurrentGitOperation() async { await worktreeChanges.cancelCurrentGitOperation() }
    func showWorkspaceToast(_ message: String) { worktreeChanges.showWorkspaceToast(message) }
    @discardableResult func performMergeFlow(
        strategy: String, subject: String, body: String, validate: Bool, removeWorkspace: Bool,
        moveCardToDone: Bool
    ) async -> Bool {
        bindWorktree()
        return await worktreeChanges.performMergeFlow(
            strategy: strategy, subject: subject, body: body, validate: validate,
            removeWorkspace: removeWorkspace,
            moveCardToDone: moveCardToDone)
    }
    func awaitCurrentGitOperationSuccess() async -> Bool {
        await worktreeChanges.awaitCurrentGitOperationSuccess()
    }

    func doneLane(for card: Dieter_V1_Card) -> String? {
        let lanes =
            selectedDetail?.board.id == card.boardID
            ? selectedDetail?.board.lanes
            : boards(for: card.projectID).first { $0.id == card.boardID }?.lanes
        guard let lanes, !lanes.isEmpty else { return nil }
        return lanes.first { $0.id == "done" }?.id ?? lanes.last?.id
    }

    /// Sends a hand-off message into the conversation on the person's behalf,
    /// e.g. "resolve the merge conflicts" or "address the review".
    @discardableResult
    func sendAgentMessage(
        _ text: String, card explicitCard: Dieter_V1_Card? = nil,
        endpointID explicitEndpointID: String? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = explicitCard?.id ?? selectedCardID ?? selectedChatID else {
            return false
        }
        let card = explicitCard ?? selectedCard ?? selectedDetail?.card
        let targetEndpointID =
            explicitEndpointID ?? projectEndpointIDs[card?.projectID ?? ""] ?? endpoint.id
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
        request.messageID =
            "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            try await enqueueMessage(request, endpointID: targetEndpointID)
            return true
        } catch {
            show(error)
            return false
        }
    }

    func resumeGitOperation(id: String) async {
        bindWorktree()
        await worktreeChanges.resumeGitOperation(id: id)
    }
    func observeGitOperation(id: String, after sequence: UInt64) {
        bindWorktree()
        worktreeChanges.observeGitOperation(id: id, after: sequence)
    }
    func acceptGitOperationFrame(_ frame: Dieter_V1_GitOperationFrame, operationID: String) -> Bool {
        worktreeChanges.acceptGitOperationFrame(frame, operationID: operationID)
    }
    func clearWorkspaceContentPreservingOperation() {
        worktreeChanges.clearWorkspaceContentPreservingOperation()
    }

    func acceptWorkspaceCard(_ card: Dieter_V1_Card) {
        replica.upsert(card)
        refreshReplicaPresentation()
        if var detail = selectedDetail, detail.card.id == card.id {
            detail.card = card
            selectedDetail = detail
        }
    }

    func acceptWorkspaceSummary(_ workspace: Dieter_V1_Workspace) {
        bindWorktree()
        worktreeChanges.acceptWorkspaceSummary(workspace)
    }

    func listProjectDirectories(path: String, machineID: String) async throws
        -> Dieter_V1_DirectoryListing
    {
        guard
            let machine = machines.first(where: { $0.id == machineID })
                ?? (endpoint.id == machineID ? endpoint : nil)
        else {
            throw NSError(
                domain: "DieterMachine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Select an enrolled machine."])
        }
        guard machine.online else {
            throw NSError(
                domain: "DieterMachine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."])
        }
        var request = Dieter_V1_ListDirectoriesRequest()
        request.path = path
        if machine.id == endpoint.id, let rpc {
            return try await rpc.listDirectories(request)
        }
        let lease = try await selectDirectoryDataPlane(for: machine)
        defer { lease.release() }
        return try await lease.rpc.listDirectories(request)
    }

    func createProject(_ draft: ProjectSetupDraft, machineID: String? = nil) async throws
        -> Dieter_V1_CreateProjectResponse
    {
        let target: DieterEndpoint
        if let machineID {
            guard
                let selected = machines.first(where: { $0.id == machineID })
                    ?? (endpoint.id == machineID ? endpoint : nil)
            else {
                throw NSError(
                    domain: "DieterMachine", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The project host is no longer enrolled."])
            }
            target = selected
        } else {
            target = endpoint
        }
        guard target.online else {
            throw NSError(
                domain: "DieterMachine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."])
        }
        let request = draft.request()
        let response: Dieter_V1_CreateProjectResponse
        if target.id == endpoint.id, let rpc {
            response = try await rpc.createProject(request)
        } else {
            let lease = try await selectDirectoryDataPlane(for: target)
            defer { lease.release() }
            response = try await lease.rpc.createProject(request)
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
        var request = Dieter_V1_ArchiveProjectRequest()
        request.projectID = id
        request.archived = archived
        do {
            _ = try await rpc.archiveProject(request)
            await refreshState()
            await refreshNavigation()
            await loadArchive()
        } catch { show(error) }
    }

    func renameProject(id: String, name: String) async {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, await ensureProjectConnection(id), let rpc else { return }
        var request = Dieter_V1_UpdateProjectRequest()
        request.projectID = id
        request.name = normalized
        do {
            _ = try await rpc.updateProject(request)
            renameProjectPresented = false
            await refreshState()
            await refreshNavigation()
        } catch { show(error) }
    }

    @discardableResult
    func updateProject(name: String, summary: String, prompt: String) async -> Bool {
        guard await ensureProjectConnection(selectedProjectID) else { return false }
        guard let rpc else { return false }
        var request = Dieter_V1_UpdateProjectRequest()
        request.projectID = selectedProjectID
        request.name = name
        request.summary = summary
        request.prompt = prompt
        do {
            _ = try await rpc.updateProject(request)
            projectContextPresented = false
            await refreshState()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func createBoard(
        name: String, workflow: String, description: String, doneArchivePolicy: String,
        baseRemote: String, remotePublishMode: String
    ) async {
        do {
            guard
                let board = try await createBoard(
                    projectID: selectedProjectID,
                    name: name,
                    workflow: workflow,
                    description: description,
                    doneArchivePolicy: doneArchivePolicy,
                    baseRemote: baseRemote,
                    remotePublishMode: remotePublishMode
                )
            else { return }
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
        doneArchivePolicy: String,
        baseRemote: String = "",
        remotePublishMode: String = RemotePublishMode.manual.rawValue
    ) async throws -> Dieter_V1_Board? {
        guard let rpc else { return nil }
        var request = Dieter_V1_CreateBoardRequest()
        request.projectID = projectID
        request.name = name
        request.workflow = workflow
        request.description_p = description
        request.doneArchivePolicy = doneArchivePolicy
        request.baseRemote = baseRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        request.remotePublishMode = remotePublishMode
        return try await rpc.createBoard(request)
    }

    @discardableResult
    func renameBoard(id: String, name: String) async -> Bool {
        guard let rpc else { return false }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        var request = Dieter_V1_RenameBoardRequest()
        request.boardID = id
        request.name = normalized
        do {
            let updated = try await rpc.renameBoard(request)
            if let index = state.boards.firstIndex(where: { $0.id == updated.id }) {
                var next = state
                next.boards[index] = updated
                state = next
            }
            if var boards = navigationBoards[updated.projectID],
                let index = boards.firstIndex(where: { $0.id == updated.id })
            {
                boards[index] = updated
                navigationBoards[updated.projectID] = boards
            }
            renameBoardPresented = false
            renameBoardTargetID = ""
            await refreshState()
            await refreshNavigation()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func setArchivePolicy(_ policy: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_SetBoardArchivePolicyRequest()
        request.boardID = selectedBoardID
        request.doneArchivePolicy = policy
        do {
            _ = try await rpc.setBoardArchivePolicy(request)
            archivePolicyPresented = false
            await refreshState()
        } catch { show(error) }
    }

    func updateBoardHostnames(_ hostnames: [String], append: Bool = false) async throws {
        guard let board = selectedBoard, await ensureProjectConnection(board.projectID), let rpc else {
            throw CaptureTaskError.failed("Choose an available project and board first.")
        }
        var request = Dieter_V1_UpdateBoardHostnamesRequest()
        request.boardID = board.id
        request.hostnames = hostnames
        request.append = append
        acceptBoard(try await rpc.updateBoardHostnames(request))
    }

    func updateBoardGitSettings(remote: String, publishMode: String) async -> Bool {
        guard let rpc else { return false }
        var request = Dieter_V1_UpdateBoardGitSettingsRequest()
        request.boardID = selectedBoardID
        request.baseRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        request.remotePublishMode = publishMode
        do {
            acceptBoard(try await rpc.updateBoardGitSettings(request))
            await refreshState()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func createLabel(name: String, color: String, instructions: String = "") async {
        guard let rpc else { return }
        var request = Dieter_V1_CreateBoardLabelRequest()
        request.boardID = selectedBoardID
        request.name = name
        request.color = color
        request.instructions = instructions
        do { acceptBoard(try await rpc.createBoardLabel(request)) } catch { show(error) }
    }

    func updateLabel(id: String, name: String, color: String, instructions: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_UpdateBoardLabelRequest()
        request.boardID = selectedBoardID
        request.labelID = id
        request.name = name
        request.color = color
        request.instructions = instructions
        do { acceptBoard(try await rpc.updateBoardLabel(request)) } catch { show(error) }
    }

    func deleteLabel(id: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_DeleteBoardLabelRequest()
        request.boardID = selectedBoardID
        request.labelID = id
        do { acceptBoard(try await rpc.deleteBoardLabel(request)) } catch { show(error) }
    }

    func acceptBoard(_ board: Dieter_V1_Board) {
        pendingBoards[board.id] = board
        replica.upsert(board, selectedProjectID: selectedProjectID)
        refreshReplicaPresentation()
    }

    func acceptProject(_ project: Dieter_V1_Project) {
        pendingProjects[project.id] = project
        replica.upsert(project)
        refreshReplicaPresentation()
    }
}
