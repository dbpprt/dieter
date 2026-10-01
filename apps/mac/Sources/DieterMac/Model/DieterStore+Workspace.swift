import AppKit
import DieterAPI
import DieterCore
import Foundation
import SharedCore
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    /// Runs an administration command on the machine that holds what it
    /// changes; the core routes it, whichever machine is attached.
    func administer(_ build: (inout ClientAdminCommand) -> Void) async throws -> ClientResult {
        var admin = ClientAdminCommand()
        build(&admin)
        let command = admin
        return try await core.dispatch(.with { $0.admin = command })
    }

    /// A conversation's workspace on its machine.
    func conversationWorkspace(cardID: String) async throws -> Dieter_V1_Workspace {
        try await administer { $0.conversationWorkspace = .with { $0.cardID = cardID } }.workspace
    }

    /// Reviews the selected conversation's workspace on the machine that owns it.
    func bindWorktree() {
        let card = selectedCard ?? selectedDetail?.card
        worktreeChanges.bind(
            target: WorkspaceTarget(
                endpointID: card.map { endpointID(for: $0) } ?? endpoint.id,
                projectID: card?.projectID ?? selectedProjectID,
                conversationID: selectedCardID ?? selectedChatID ?? ""),
            core: core, card: card, doneLaneID: card.flatMap { doneLane(for: $0) }
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
        worktreeChanges.onOperationFinished = { [weak self] target in
            guard let self, self.selectedProjectID == target.projectID else { return }
            await self.loadProjectWorkspaces()
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
    func addChangeComment(line: UnifiedDiffLine, body: String) async -> Bool {
        bindWorktree()
        return await worktreeChanges.addChangeComment(line: line, body: body)
    }

    func updateConversationWorkspace(
        _ draft: ConversationWorkspaceDraft, cardID explicitCardID: String? = nil
    ) async -> Bool {
        guard let cardID = explicitCardID ?? selectedCardID ?? selectedChatID else { return false }
        do {
            let result = try await administer {
                $0.updateConversationWorkspace = .with {
                    $0.cardID = cardID
                    $0.mode = draft.mode.rawValue
                    $0.branch = draft.branch
                    $0.baseBranch = draft.baseBranch
                    $0.baseRemote = draft.baseRemote
                    $0.publishMode = draft.remotePublishMode
                }
            }
            acceptWorkspaceCard(result.card)
            return true
        } catch {
            workspaceError = (error as? CoreFailure)?.message ?? error.localizedDescription
            return false
        }
    }

    func updateProjectWorkspaceSettings(
        remote: String,
        branch: String,
        validationCommands: [Dieter_V1_ValidationCommand]
    ) async -> Bool {
        guard !selectedProjectID.isEmpty else { return false }
        let checkout = checkout(forProjectID: selectedProjectID)
        let updatesValidation = validationCommands != (checkout?.validationCommands ?? [])
        let projectID = selectedProjectID
        do {
            let result = try await administer {
                $0.workspaceSettings = .with {
                    $0.projectID = projectID
                    $0.baseRemote = remote
                    $0.baseBranch = branch
                    $0.checkoutID = checkout?.id ?? ""
                    $0.setValidation = updatesValidation
                    $0.validation = validationCommands
                }
            }
            acceptProject(result.project)
            return true
        } catch {
            show(error)
            return false
        }
    }

    /// The selected project's conversation workspaces across its checkouts.
    func loadProjectWorkspaces() async {
        let projectID = selectedProjectID
        guard !projectID.isEmpty else { return }
        let result = await perform { $0.projectWorkspaces = .with { $0.load = .with { $0.projectID = projectID } } }
        guard case .projectWorkspaces(let slice)? = result?.result, projectID == selectedProjectID else { return }
        projectWorkspaces = slice.workspaces
        if !slice.error.isEmpty { workspaceError = slice.error }
    }

    /// Cleans up or discards a conversation's worktree on its machine and waits for it.
    @discardableResult
    func removeProjectWorkspace(cardID: String, discard: Bool) async -> Bool {
        let result = await perform {
            $0.projectWorkspaces = .with {
                $0.remove = .with {
                    $0.cardID = cardID
                    $0.discard = discard
                }
            }
        }
        guard case .projectWorkspaces(let slice)? = result?.result else { return false }
        projectWorkspaces = slice.workspaces
        if let failure = slice.errors[cardID] {
            workspaceError = failure
            return false
        }
        return true
    }

    func startGitOperation(_ kind: GitOperationKind, parameters: [String: String] = [:]) async -> Bool {
        bindWorktree()
        return await worktreeChanges.startGitOperation(kind, parameters: parameters)
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
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text = trimmed
        // The core's outbox delivers it to the conversation's own machine.
        return await perform {
            $0.sendMessage = .with { send in
                send.cardID = id
                send.parts = [part]
                send.selection = .with {
                    $0.provider = card?.provider ?? ""
                    $0.model = card?.model ?? ""
                    $0.effort = card?.effort ?? ""
                    $0.providerOptions = card?.providerOptions ?? [:]
                }
            }
        } != nil
    }


    func acceptWorkspaceCard(_ card: Dieter_V1_Card, sourceDaemonID: String? = nil) {
        let card = replica.retainingOwnerDetails([card], sourceDaemonID: sourceDaemonID ?? endpoint.daemonID)[0]
        replica.upsert(card)
        refreshReplicaPresentation()
        if var detail = selectedDetail, detail.card.id == card.id {
            detail.card = card
            selectedDetail = detail
        }
        if var snapshot = conversation, snapshot.detail.card.id == card.id {
            snapshot.detail.card = card
            conversation = snapshot
        }
    }


    func listProjectDirectories(path: String, machineID: String) async throws
        -> Dieter_V1_DirectoryListing
    {
        guard
            let machine = machines.first(where: { $0.id == machineID })
                ?? (endpoint.id == machineID ? endpoint : nil), let daemonID = machine.daemonID
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
        return try await administer {
            $0.directories = .with {
                $0.daemonID = daemonID
                $0.path = path
            }
        }.directoryListing
    }

    func createProject(_ draft: ProjectSetupDraft, machineID: String? = nil, operationID: String = UUID().uuidString)
        async throws
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
                    userInfo: [NSLocalizedDescriptionKey: "The selected machine is no longer enrolled."])
            }
            target = selected
        } else {
            target = endpoint
        }
        guard target.online, let daemonID = target.daemonID else {
            throw NSError(
                domain: "DieterMachine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."])
        }
        // The core keeps one operation per intent, so a retry never creates twice.
        let request = draft.request()
        let response = try await administer {
            $0.createProject = .with {
                $0.daemonID = daemonID
                $0.path = request.path
                $0.name = request.name
                $0.create = request.mode == "create"
                $0.boardName = request.boardName
                $0.workflow = request.workflow
                $0.baseRemote = request.baseRemote
                $0.baseBranch = request.baseBranch
                $0.validation = request.validationCommands
            }
        }.createdProject

        projectDirectory[response.project.id] = response.project
        projectReplicaEndpointIDs[response.project.id] = target.id
        navigationBoards[response.project.id] = [response.board]
        if target.id != endpoint.id { await connect(to: target) }
        selectedProjectID = response.project.id
        selectedBoardID = response.board.id
        section = .board
        await refreshState()
        await refreshNavigation()
        return response
    }

    func setProjectArchived(id: String, archived: Bool) async {
        do {
            _ = try await administer {
                $0.setProjectArchived = .with {
                    $0.projectID = id
                    $0.archived = archived
                }
            }
            await refreshState()
            await refreshNavigation()
            await loadArchive()
        } catch { show(error) }
    }

    func renameProject(id: String, name: String) async {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        do {
            _ = try await administer {
                $0.updateProject = .with {
                    $0.projectID = id
                    $0.name = normalized
                }
            }
            renameProjectPresented = false
            await refreshState()
            await refreshNavigation()
        } catch { show(error) }
    }

    @discardableResult
    func updateProject(name: String, summary: String, prompt: String) async -> Bool {
        let projectID = selectedProjectID
        do {
            _ = try await administer {
                $0.updateProject = .with {
                    $0.projectID = projectID
                    $0.name = name
                    $0.summary = summary
                    $0.prompt = prompt
                }
            }
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
        try await administer {
            $0.createBoard = .with {
                $0.projectID = projectID
                $0.name = name
                $0.workflow = workflow
                $0.description_p = description
                $0.doneArchivePolicy = doneArchivePolicy
                $0.baseRemote = baseRemote.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.publishMode = remotePublishMode
            }
        }.board
    }

    @discardableResult
    func renameBoard(id: String, name: String) async -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        do {
            let updated = try await administer {
                $0.renameBoard = .with {
                    $0.boardID = id
                    $0.name = normalized
                }
            }.board
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
        let boardID = selectedBoardID
        do {
            acceptBoard(
                try await administer {
                    $0.setArchivePolicy = .with {
                        $0.boardID = boardID
                        $0.policy = policy
                    }
                }.board)
            archivePolicyPresented = false
            await refreshState()
        } catch { show(error) }
    }

    func updateBoardHostnames(_ hostnames: [String], append: Bool = false) async throws {
        guard let board = selectedBoard else {
            throw CaptureTaskError.failed("Choose an available project and board first.")
        }
        acceptBoard(
            try await administer {
                $0.setHostnames = .with {
                    $0.boardID = board.id
                    $0.hostnames = hostnames
                    $0.append = append
                }
            }.board)
    }

    func updateBoardGitSettings(remote: String, publishMode: String) async -> Bool {
        let boardID = selectedBoardID
        do {
            acceptBoard(
                try await administer {
                    $0.setGitSettings = .with {
                        $0.boardID = boardID
                        $0.baseRemote = remote
                        $0.publishMode = publishMode
                    }
                }.board)
            await refreshState()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func createLabel(name: String, color: String, instructions: String = "") async {
        let boardID = selectedBoardID
        do {
            acceptBoard(
                try await administer {
                    $0.createLabel = .with {
                        $0.boardID = boardID
                        $0.name = name
                        $0.color = color
                        $0.instructions = instructions
                    }
                }.board)
        } catch { show(error) }
    }

    func updateLabel(id: String, name: String, color: String, instructions: String) async {
        let boardID = selectedBoardID
        do {
            acceptBoard(
                try await administer {
                    $0.updateLabel = .with {
                        $0.boardID = boardID
                        $0.labelID = id
                        $0.name = name
                        $0.color = color
                        $0.instructions = instructions
                    }
                }.board)
        } catch { show(error) }
    }

    func deleteLabel(id: String) async {
        let boardID = selectedBoardID
        do {
            acceptBoard(
                try await administer {
                    $0.deleteLabel = .with {
                        $0.boardID = boardID
                        $0.labelID = id
                    }
                }.board)
        } catch { show(error) }
    }

    func retireBoard(_ board: Dieter_V1_Board) async {
        do {
            // The core retires against the lifecycle revision the replica reports.
            acceptBoard(
                try await administer {
                    $0.setBoardRetired = .with {
                        $0.boardID = board.id
                        $0.retired = true
                    }
                }.board)
            await refreshState()
            await refreshNavigation()
        } catch { show(error) }
    }

    func restoreBoard(_ id: String) async {
        do {
            let restored = try await administer {
                $0.setBoardRetired = .with {
                    $0.boardID = id
                    $0.retired = false
                }
            }.board
            replica.retiredBoards.removeValue(forKey: id)
            acceptBoard(restored)
            await refreshState(); await refreshNavigation()
        } catch { show(error) }
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
