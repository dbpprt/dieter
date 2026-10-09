package com.dbpprt.dieter.core.admin

import com.dbpprt.dieter.api.v1.ArchiveProjectRequest
import com.dbpprt.dieter.api.v1.AttachCheckoutRequest
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.BoardRef
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.CheckoutRef
import com.dbpprt.dieter.api.v1.ConsolidateProjectRequest
import com.dbpprt.dieter.api.v1.ConversationRef
import com.dbpprt.dieter.api.v1.CreateBoardLabelRequest
import com.dbpprt.dieter.api.v1.CreateBoardRequest
import com.dbpprt.dieter.api.v1.CreateProjectRequest
import com.dbpprt.dieter.api.v1.CreateProjectResponse
import com.dbpprt.dieter.api.v1.DeleteBoardLabelRequest
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.DirectoryListing
import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.api.v1.ListChatsRequest
import com.dbpprt.dieter.api.v1.ListDirectoriesRequest
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.PeerRecordRef
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.api.v1.PreviewPromptRequest
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.ProjectHostnames
import com.dbpprt.dieter.api.v1.PromptPreview
import com.dbpprt.dieter.api.v1.PromptSettings
import com.dbpprt.dieter.api.v1.PutPeerRecordRequest
import com.dbpprt.dieter.api.v1.ReadFileRequest
import com.dbpprt.dieter.api.v1.RenameBoardRequest
import com.dbpprt.dieter.api.v1.SetBoardArchivePolicyRequest
import com.dbpprt.dieter.api.v1.SetBoardRetiredRequest
import com.dbpprt.dieter.api.v1.SetScopedPromptTemplateRequest
import com.dbpprt.dieter.api.v1.UpdateBoardGitSettingsRequest
import com.dbpprt.dieter.api.v1.UpdateBoardHostnamesRequest
import com.dbpprt.dieter.api.v1.UpdateBoardLabelRequest
import com.dbpprt.dieter.api.v1.UpdateConversationWorkspaceRequest
import com.dbpprt.dieter.api.v1.UpdateProjectRequest
import com.dbpprt.dieter.api.v1.UpdatePromptSettingsRequest
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.machines.MachineChoice
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.workspace.ProjectWorkspaceSettings
import com.dbpprt.dieter.core.workspace.ValidationCommandDraft
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.uuid.Uuid
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

/** Which machine must receive an administrative call. */
sealed interface AdminRoute {
    /**
     * A reachable machine that holds the project: the peer store accepts and replicates the write.
     */
    data class ForProject(val projectId: String) : AdminRoute

    /** The machine holding a checkout's path, validation commands, and leases. */
    data class Owner(val checkoutId: String, val projectId: String) : AdminRoute

    /** A machine the user chose, e.g. to host a new project. */
    data class Target(val daemonId: String) : AdminRoute

    /**
     * A reachable machine that observed every version of the register [key], for a
     * compare-and-swap; else [ForProject].
     */
    data class Observer(val key: String, val projectId: String) : AdminRoute

    /** Any reachable machine, this device's first. */
    data object Anywhere : AdminRoute

    companion object {
        /**
         * Shared records of [projectId] live on every machine that holds it; without a project, on
         * any.
         */
        fun shared(projectId: String?): AdminRoute =
            projectId?.takeIf { it.isNotEmpty() }?.let(::ForProject) ?: Anywhere
    }
}

/**
 * The archived projects a machine knows and a board's archived cards, as the Archives view lists
 * them.
 */
data class AdministrationArchives(
    val projects: List<Project> = emptyList(),
    val cards: List<Card> = emptyList(),
)

/**
 * Projects, checkouts, boards, labels, prompt settings, and shared-record conflicts, each on the
 * machine [MachineChoice] picks for it. Returned projects and boards show at once and yield to the
 * account view once it is at least as new. Confined to the core dispatcher.
 */
class Administration(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
) {
    /** Intent → its operation ID, oldest first; an intent is forgotten once it succeeded. */
    private val operationIds = LinkedHashMap<String, String>()

    /** Intents whose operation ID is kept for a retry. */
    internal val pendingIntents: Int
        get() = operationIds.size

    private fun daemonFor(route: AdminRoute): String {
        val directory = store.directoryProjection
        return when (route) {
            is AdminRoute.Target -> route.daemonId
            is AdminRoute.ForProject ->
                choice.project(route.projectId)
                    ?: throw CoreException(
                        FailureKind.TRANSIENT,
                        "No machine with this project is reachable.",
                    )
            is AdminRoute.Observer ->
                choice.observer(route.key)
                    ?: choice.project(route.projectId)
                    ?: throw CoreException(
                        FailureKind.TRANSIENT,
                        "No machine with this project is reachable.",
                    )
            is AdminRoute.Owner ->
                directory.checkoutMachine(route.projectId, route.checkoutId)
                    ?: throw CoreException(
                        FailureKind.TRANSIENT,
                        "The checkout’s machine is unavailable",
                    )
            AdminRoute.Anywhere ->
                choice.any()
                    ?: throw CoreException(FailureKind.TRANSIENT, "No machine is reachable.")
        }
    }

    private suspend fun <T> call(
        route: AdminRoute,
        timeout: Duration = Deadlines.CALL,
        block: suspend (DieterServiceClient) -> T,
    ): T = sessions.call(daemonFor(route), timeout, block)

    /**
     * Runs [block] with one operation ID per distinct intent, so a retry of the same intent is
     * idempotent and an edit is not. The ID is kept until the intent succeeds; only the newest
     * [MAX_INTENTS] are kept.
     */
    private suspend fun <T> idempotent(
        kind: String,
        fingerprint: ByteString,
        block: suspend (operationId: String) -> T,
    ): T {
        val key = kind + ":" + fingerprint.sha256().hex()
        val id = operationIds.remove(key) ?: Uuid.random().toString()
        operationIds[key] = id
        while (operationIds.size > MAX_INTENTS) operationIds.remove(operationIds.keys.first())
        return block(id).also { operationIds.remove(key) }
    }

    // --- Projects ---------------------------------------------------------------

    /**
     * Registers an existing repository ("open") or creates one ("create") on [daemonId], with its
     * first board ([DEFAULT_BOARD_NAME] when blank). A [summary] or [prompt] is saved on the new
     * project right after.
     */
    suspend fun createProject(
        daemonId: String,
        path: String,
        name: String = "",
        create: Boolean = false,
        boardName: String = DEFAULT_BOARD_NAME,
        workflow: String = DEFAULT_WORKFLOW,
        baseRemote: String = DEFAULT_BASE_REMOTE,
        baseBranch: String = DEFAULT_BASE_BRANCH,
        validation: List<ValidationCommand> = emptyList(),
        summary: String = "",
        prompt: String = "",
    ): CreateProjectResponse {
        if (path.isBlank())
            throw CoreException(FailureKind.PERMANENT, "Choose a folder for the project.")
        if (baseBranch.isBlank())
            throw CoreException(FailureKind.PERMANENT, "Enter a workspace base branch.")
        val request =
            CreateProjectRequest(
                mode = if (create) "create" else "open",
                path = path.trim(),
                name = name.trim(),
                board_name = boardName.trim().ifEmpty { DEFAULT_BOARD_NAME },
                workflow = workflow,
                base_remote = baseRemote.trim(),
                base_branch = baseBranch.trim(),
                validation_commands = validation,
            )
        val response =
            idempotent("project", CreateProjectRequest.ADAPTER.encodeByteString(request)) {
                operationId ->
                call(AdminRoute.Target(daemonId), Deadlines.PROVISION) {
                    it.CreateProject().execute(request.copy(operation_id = operationId))
                }
            }
        // Its checkout routes calls for the new project to the machine that created it.
        response.project?.let(store::overlayProject)
        response.board?.let(store::overlayBoard)
        val created = response.project
        if (created == null || (summary.isBlank() && prompt.isBlank())) return response
        return response.copy(
            project = updateProject(created.id, summary = summary, prompt = prompt)
        )
    }

    suspend fun updateProject(
        projectId: String,
        name: String? = null,
        summary: String? = null,
        prompt: String? = null,
        hostnames: List<String>? = null,
    ): Project {
        val request =
            UpdateProjectRequest(
                project_id = projectId,
                name = name?.trim()?.ifEmpty { null },
                summary = summary,
                prompt = prompt,
                hostnames =
                    hostnames?.let {
                        ProjectHostnames(
                            values =
                                Hostnames.normalize(it).getOrElse { error ->
                                    throw CoreException(
                                        FailureKind.PERMANENT,
                                        error.message.orEmpty(),
                                    )
                                }
                        )
                    },
            )
        return call(AdminRoute.ForProject(projectId)) { it.UpdateProject().execute(request) }
            .also(store::overlayProject)
    }

    /**
     * Saves the project settings form: the workspace base remote and branch and, unless
     * [validation] is null, [checkoutId]'s validation commands (written on that checkout's
     * machine), then the name, summary, and instructions. A blank [name] keeps the current one. The
     * project shows each result at once.
     */
    suspend fun saveProject(
        projectId: String,
        name: String,
        summary: String,
        prompt: String,
        baseRemote: String,
        baseBranch: String,
        checkoutId: String?,
        validation: List<ValidationCommandDraft>?,
    ): Project {
        val project =
            store.state.value.project(projectId)
                ?: throw CoreException(FailureKind.PERMANENT, "The project is no longer available.")
        ProjectWorkspaceSettings.update(
                sessions,
                store,
                choice,
                project,
                baseRemote,
                baseBranch,
                checkoutId,
                validation,
            )
            .also(store::overlayProject)
        return updateProject(projectId, name = name, summary = summary, prompt = prompt)
    }

    suspend fun setProjectArchived(projectId: String, archived: Boolean): Project =
        call(AdminRoute.ForProject(projectId)) {
                it.ArchiveProject()
                    .execute(ArchiveProjectRequest(project_id = projectId, archived = archived))
            }
            .also(store::overlayProject)

    suspend fun archivedProjects(daemonId: String? = choice.any()): List<Project> {
        val machine =
            daemonId ?: throw CoreException(FailureKind.TRANSIENT, "No machine is reachable.")
        return call(AdminRoute.Target(machine)) { it.ListArchivedProjects().execute(Unit) }.projects
    }

    /**
     * Folds [sourceId] into [destinationId]; conversations keep their IDs, checkouts, and machines.
     * The source leaves the workspace at once, and the destination shows its boards, items, and
     * checkouts.
     */
    suspend fun consolidate(sourceId: String, destinationId: String): Project {
        if (sourceId == destinationId)
            return store.directoryProjection.projects[destinationId]
                ?: throw CoreException(FailureKind.PERMANENT, "The project is no longer available.")
        return call(AdminRoute.ForProject(destinationId)) {
                it.ConsolidateProject()
                    .execute(
                        ConsolidateProjectRequest(
                            source_project_id = sourceId,
                            destination_project_id = destinationId,
                        )
                    )
            }
            .also { store.overlayConsolidation(sourceId, it) }
    }

    // --- Checkouts ----------------------------------------------------------------

    /** Folders on [daemonId]; an empty [path] lists its default locations. */
    suspend fun directories(daemonId: String, path: String = ""): DirectoryListing =
        call(AdminRoute.Target(daemonId)) {
            it.ListDirectories().execute(ListDirectoriesRequest(path = path))
        }

    /**
     * Attaches a Git working tree on [daemonId] as another checkout of [projectId]; the project
     * shows it at once.
     */
    suspend fun attachCheckout(
        daemonId: String,
        projectId: String,
        path: String,
        name: String = "",
    ): Checkout =
        call(AdminRoute.Target(daemonId), Deadlines.PROVISION) {
                it.AttachCheckout()
                    .execute(
                        AttachCheckoutRequest(
                            project_id = projectId,
                            path = path.trim(),
                            name = name.trim(),
                        )
                    )
            }
            .also(store::overlayCheckout)

    /**
     * Detaches a checkout on the machine that holds it; refused while a conversation there is
     * running. The project shows it detached at once.
     */
    suspend fun detachCheckout(projectId: String, checkoutId: String) {
        call(AdminRoute.Owner(checkoutId, projectId)) {
            it.DetachCheckout().execute(CheckoutRef(checkout_id = checkoutId))
        }
        store.directoryProjection.projects[projectId]
            ?.checkouts
            ?.firstOrNull { it.id == checkoutId }
            ?.let { store.overlayCheckout(it.copy(detached = true)) }
    }

    // --- Boards -------------------------------------------------------------------

    suspend fun createBoard(
        projectId: String,
        name: String,
        workflow: String = DEFAULT_WORKFLOW,
        description: String = "",
        policy: String = DEFAULT_ARCHIVE_POLICY,
        baseRemote: String = "",
        publishMode: String = DEFAULT_PUBLISH_MODE,
    ): Board {
        if (name.isBlank()) throw CoreException(FailureKind.PERMANENT, "board name is required")
        val request =
            CreateBoardRequest(
                project_id = projectId,
                name = name.trim(),
                workflow = workflow,
                description = description.trim(),
                done_archive_policy = policy,
                base_remote =
                    baseRemote.ifEmpty {
                        store.directoryProjection.projects[projectId]?.base_remote.orEmpty()
                    },
                remote_publish_mode = publishMode,
            )
        return call(AdminRoute.ForProject(projectId)) { it.CreateBoard().execute(request) }
            .also(store::overlayBoard)
    }

    private fun projectOf(boardId: String): String =
        store.findBoard(boardId)?.project_id
            ?: throw CoreException(FailureKind.PERMANENT, "The board is no longer available.")

    suspend fun renameBoard(boardId: String, name: String): Board {
        if (name.isBlank()) throw CoreException(FailureKind.PERMANENT, "board name is required")
        return call(AdminRoute.ForProject(projectOf(boardId))) {
                it.RenameBoard().execute(RenameBoardRequest(board_id = boardId, name = name.trim()))
            }
            .also(store::overlayBoard)
    }

    suspend fun setArchivePolicy(boardId: String, policy: String): Board {
        if (policy !in ARCHIVE_POLICIES)
            throw CoreException(
                FailureKind.PERMANENT,
                "Done archive policy must be never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days",
            )
        return call(AdminRoute.ForProject(projectOf(boardId))) {
                it.SetBoardArchivePolicy()
                    .execute(
                        SetBoardArchivePolicyRequest(
                            board_id = boardId,
                            done_archive_policy = policy,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    suspend fun setGitSettings(boardId: String, baseRemote: String, publishMode: String): Board {
        if (publishMode !in PUBLISH_MODES)
            throw CoreException(
                FailureKind.PERMANENT,
                "remote publish mode must be manual, pull_request, or push_base",
            )
        return call(AdminRoute.ForProject(projectOf(boardId))) {
                it.UpdateBoardGitSettings()
                    .execute(
                        UpdateBoardGitSettingsRequest(
                            board_id = boardId,
                            base_remote = baseRemote.trim(),
                            remote_publish_mode = publishMode,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    suspend fun setHostnames(
        boardId: String,
        hostnames: List<String>,
        append: Boolean = false,
    ): Board {
        val values =
            Hostnames.normalize(hostnames).getOrElse {
                throw CoreException(FailureKind.PERMANENT, it.message.orEmpty())
            }
        return call(AdminRoute.ForProject(projectOf(boardId))) {
                it.UpdateBoardHostnames()
                    .execute(
                        UpdateBoardHostnamesRequest(
                            board_id = boardId,
                            hostnames = values,
                            append = append,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    /**
     * Retires (deletes) or restores a board against the lifecycle revision of a machine that
     * observed every intent this client shows. Only empty boards can be retired. The operation ID
     * is kept for the whole intent, so a retry never applies twice.
     */
    suspend fun setBoardRetired(boardId: String, retired: Boolean): Board {
        val route = AdminRoute.Observer("board/$boardId.retired", projectOf(boardId))
        return idempotent("board", "retire:$boardId:$retired".encodeUtf8()) { operationId ->
                call(route) { client ->
                    val current = client.GetBoard().execute(BoardRef(board_id = boardId))
                    client
                        .SetBoardRetired()
                        .execute(
                            SetBoardRetiredRequest(
                                board_id = boardId,
                                retired = retired,
                                expected_revision = current.retirement_revision,
                                operation_id = operationId,
                            )
                        )
                }
            }
            .also(store::overlayBoard)
    }

    // --- Labels ---------------------------------------------------------------------

    suspend fun createLabel(
        boardId: String,
        name: String,
        color: String = "",
        instructions: String = "",
    ): Board {
        Labels.validate(name, color)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.ForProject(projectOf(boardId))) {
                it.CreateBoardLabel()
                    .execute(
                        CreateBoardLabelRequest(
                            board_id = boardId,
                            name = name.trim(),
                            color = color.trim(),
                            instructions = instructions,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    suspend fun updateLabel(
        boardId: String,
        labelId: String,
        name: String,
        color: String,
        instructions: String,
    ): Board {
        Labels.validate(name, color)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.ForProject(projectOf(boardId))) {
                it.UpdateBoardLabel()
                    .execute(
                        UpdateBoardLabelRequest(
                            board_id = boardId,
                            label_id = labelId,
                            name = name.trim(),
                            color = color.trim(),
                            instructions = instructions,
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    /** Removes the label from the board and from every card. */
    suspend fun deleteLabel(boardId: String, labelId: String): Board =
        call(AdminRoute.ForProject(projectOf(boardId))) {
                it.DeleteBoardLabel()
                    .execute(DeleteBoardLabelRequest(board_id = boardId, label_id = labelId))
            }
            .also(store::overlayBoard)

    // --- Prompts ----------------------------------------------------------------------

    /**
     * Global prompt settings are local to one machine; the editor always names the machine it
     * edits.
     */
    suspend fun promptSettings(daemonId: String): PromptSettings =
        call(AdminRoute.Target(daemonId)) { it.GetPromptSettings().execute(Unit) }

    suspend fun updatePromptSettings(
        daemonId: String,
        context: String,
        boardSkill: String,
        chatSkill: String,
    ): PromptSettings {
        listOf(
                PromptTemplates.validate(context, context = true),
                PromptTemplates.validate(boardSkill)?.let { "board skill template: $it" },
                PromptTemplates.validate(chatSkill)?.let { "chat skill template: $it" },
            )
            .firstOrNull { it != null }
            ?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.Target(daemonId)) {
            it.UpdatePromptSettings()
                .execute(
                    UpdatePromptSettingsRequest(
                        prompt_template = context,
                        board_skill_template = boardSkill,
                        chat_skill_template = chatSkill,
                    )
                )
        }
    }

    /** Sets or clears ([template] null) a project's prompt override. */
    suspend fun setProjectPrompt(projectId: String, template: String?): Project {
        template
            ?.let { PromptTemplates.validate(it, context = true) }
            ?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.ForProject(projectId)) {
                it.SetProjectPromptTemplate()
                    .execute(
                        SetScopedPromptTemplateRequest(
                            scope_id = projectId,
                            inherit = template == null,
                            prompt_template = template.orEmpty(),
                        )
                    )
            }
            .also(store::overlayProject)
    }

    suspend fun setBoardPrompt(boardId: String, template: String?): Board {
        template
            ?.let { PromptTemplates.validate(it, context = true) }
            ?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.ForProject(projectOf(boardId))) {
                it.SetBoardPromptTemplate()
                    .execute(
                        SetScopedPromptTemplateRequest(
                            scope_id = boardId,
                            inherit = template == null,
                            prompt_template = template.orEmpty(),
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    /**
     * Renders the prompt an agent would receive; runs where the checkout lives, since it reads the
     * repository.
     */
    suspend fun previewPrompt(
        projectId: String,
        boardId: String = "",
        cardId: String = "",
        labelIds: List<String> = emptyList(),
        checkoutId: String? = null,
    ): PromptPreview {
        val route =
            checkoutId?.let { AdminRoute.Owner(it, projectId) } ?: AdminRoute.ForProject(projectId)
        return call(route) {
            it.PreviewPrompt()
                .execute(
                    PreviewPromptRequest(
                        project_id = projectId,
                        board_id = boardId,
                        card_id = cardId,
                        label_ids = labelIds,
                        scope = if (boardId.isNotEmpty()) "board" else "chat",
                    )
                )
        }
    }

    // --- Shared-record conflicts --------------------------------------------------------

    /**
     * The competing versions behind a conflict key such as `board/b_1.name`, read from a machine
     * with [projectId].
     */
    suspend fun conflict(projectId: String?, key: String): PeerRecord? {
        val kind = key.substringBefore('/')
        val id = key.substringAfter('/').substringBefore('.')
        val record =
            call(AdminRoute.shared(projectId)) {
                it.GetPeerRecord().execute(PeerRecordRef(kind = kind, id = id))
            }
        return record.takeIf { it.versions.size > 1 }
    }

    /** Keeps one version (or the deletion) on a machine with [projectId]. */
    suspend fun resolve(
        projectId: String?,
        record: PeerRecord,
        valueJson: ByteString?,
        deleted: Boolean,
    ): PeerRecord =
        call(AdminRoute.shared(projectId)) {
            it.PutPeerRecord()
                .execute(
                    PutPeerRecordRequest(
                        kind = record.kind,
                        id = record.id,
                        value_json =
                            if (deleted) ByteString.EMPTY else valueJson ?: ByteString.EMPTY,
                        deleted = deleted,
                        expected_revision = record.revision,
                    )
                )
        }

    // --- Conversations and files ---------------------------------------------------------

    /** The machine that runs [cardId]: its owner, else its checkout's machine. */
    private fun ownerOf(cardId: String): String {
        val directory = store.directoryProjection
        val card =
            directory.item(cardId)
                ?: throw CoreException(
                    FailureKind.PERMANENT,
                    "The conversation is no longer available.",
                )
        return directory.owner(card)
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "The conversation's machine is unavailable.",
            )
    }

    /** A conversation's workspace, provisioning it when needed. */
    suspend fun conversationWorkspace(cardId: String): Workspace =
        call(AdminRoute.Target(ownerOf(cardId)), Deadlines.PROVISION) {
            it.GetWorkspace().execute(ConversationRef(card_id = cardId))
        }

    /** Changes a conversation's workspace before its first turn, on the machine that owns it. */
    suspend fun updateConversationWorkspace(
        cardId: String,
        mode: WorkspaceMode,
        branch: String,
        baseBranch: String,
        baseRemote: String,
        publishMode: String,
    ): Card {
        val daemon = ownerOf(cardId)
        val worktree = mode == WorkspaceMode.WORKTREE
        return call(AdminRoute.Target(daemon)) {
            it.UpdateConversationWorkspace()
                .execute(
                    UpdateConversationWorkspaceRequest(
                        card_id = cardId,
                        mode = mode.wire,
                        branch = if (worktree) branch.trim() else "",
                        base_branch = if (worktree) baseBranch.trim() else "",
                        base_remote = baseRemote.trim(),
                        remote_publish_mode = publishMode.trim(),
                    )
                )
        }
    }

    /** A machine's archived chats; live chats are in the workspace. */
    suspend fun archivedChats(daemonId: String): List<Card> =
        call(AdminRoute.Target(daemonId)) {
                it.ListChats().execute(ListChatsRequest(include_archived = true))
            }
            .chats
            .filter { it.archived }

    /** One file of a checkout, or of a conversation's workspace when [cardId] is set. */
    suspend fun readFile(
        daemonId: String,
        projectId: String,
        checkoutId: String,
        cardId: String,
        path: String,
    ): FileDocument =
        call(AdminRoute.Target(daemonId), Deadlines.PROVISION) {
            it.ReadFile()
                .execute(
                    ReadFileRequest(
                        project_id = projectId,
                        checkout_id = if (cardId.isEmpty()) checkoutId else "",
                        card_id = cardId,
                        path = path,
                    )
                )
        }

    /**
     * The archived projects a machine with [projectId] knows and [boardId]'s archived cards, read
     * together for the Archives view.
     */
    suspend fun archives(projectId: String, boardId: String?): AdministrationArchives {
        val projects = archivedProjects(daemonFor(AdminRoute.ForProject(projectId)))
        val cards =
            boardId
                ?.let { board ->
                    call(AdminRoute.ForProject(projectId)) {
                            it.ListArchivedCards().execute(BoardRef(board_id = board))
                        }
                        .cards
                }
                .orEmpty()
        return AdministrationArchives(projects, cards)
    }

    companion object {
        private const val MAX_INTENTS = 64
        val ARCHIVE_POLICIES =
            listOf(
                "never",
                "immediately",
                "after_1_day",
                "after_7_days",
                "after_30_days",
                "after_90_days",
            )
        val PUBLISH_MODES = listOf("manual", "pull_request", "push_base")

        /**
         * A board with a review lane, or one that moves finished work straight to Done; review
         * first.
         */
        val WORKFLOWS = listOf("review", "direct")

        /** What a new project or board starts with unless the user changes it. */
        const val DEFAULT_BOARD_NAME = "Main"
        const val DEFAULT_WORKFLOW = "review"
        const val DEFAULT_BASE_REMOTE = "origin"
        const val DEFAULT_BASE_BRANCH = "main"
        const val DEFAULT_PUBLISH_MODE = "manual"
        const val DEFAULT_ARCHIVE_POLICY = "never"

        /** "Never", "Immediately", "After 7 days". */
        fun archivePolicyTitle(policy: String): String =
            policy.replace('_', ' ').replaceFirstChar { it.uppercase() }

        fun publishModeTitle(mode: String): String =
            when (mode) {
                "manual" -> "Manual"
                "pull_request" -> "Pull request"
                "push_base" -> "Push base branch"
                else -> mode
            }

        /** What a publish mode does with a conversation's finished branch. */
        fun publishModeDetail(mode: String): String =
            when (mode) {
                "manual" -> "Choose local merge, branch push, or pull request when publishing."
                "pull_request" -> "Publish the conversation branch through a pull request."
                "push_base" -> "Push the validated integration result directly to the base branch."
                else -> ""
            }

        /** "With review" or "Direct to done"; an unknown workflow reads as itself. */
        fun workflowTitle(workflow: String): String =
            when (workflow) {
                "review" -> "With review"
                "direct" -> "Direct to done"
                else -> workflow
            }

        /**
         * The lanes a workflow's cards pass: "Todo → Running → Review → Done", or without Review
         * for direct.
         */
        fun workflowLanes(workflow: String): String =
            if (workflow == "direct") "Todo → Running → Done" else "Todo → Running → Review → Done"

        /** What a workflow does with finished agent work. */
        fun workflowDetail(workflow: String): String =
            if (workflow == "direct") "Direct moves completed work straight to Done."
            else "Review keeps completed agent work waiting for your approval."

        /** The remote a project's workspaces branch from, [DEFAULT_BASE_REMOTE] when unset. */
        fun baseRemote(project: Project): String =
            project.base_remote.ifBlank { DEFAULT_BASE_REMOTE }

        /** The branch a project's workspaces start from, [DEFAULT_BASE_BRANCH] when unset. */
        fun baseBranch(project: Project): String =
            project.base_branch.ifBlank { DEFAULT_BASE_BRANCH }

        /** The remote a board's workspaces publish to: its own, else its project's. */
        fun boardRemote(board: Board, project: Project?): String =
            board.base_remote.ifBlank { project?.base_remote.orEmpty() }

        /** How a board publishes finished work, [DEFAULT_PUBLISH_MODE] when unset. */
        fun publishMode(board: Board): String =
            board.remote_publish_mode.ifBlank { DEFAULT_PUBLISH_MODE }

        /**
         * A new project needs a folder, a base branch, and valid validation commands; a blank board
         * name becomes [DEFAULT_BOARD_NAME].
         */
        fun canCreateProject(
            path: String,
            baseBranch: String,
            validation: List<ValidationCommandDraft>,
        ): Boolean =
            path.isNotBlank() &&
                baseBranch.isNotBlank() &&
                ValidationCommandDraft.problem(validation) == null

        /**
         * The project settings form saves with a name, a base branch, and valid validation
         * commands.
         */
        fun canSaveProject(
            name: String,
            baseBranch: String,
            validation: List<ValidationCommandDraft>,
        ): Boolean =
            name.isNotBlank() &&
                baseBranch.isNotBlank() &&
                ValidationCommandDraft.problem(validation) == null
    }
}

data class LabelColor(val name: String, val value: String)

object Labels {
    /** The palette every client offers, by name. */
    val COLORS =
        listOf(
            LabelColor("Ruby", "#d95c68"),
            LabelColor("Coral", "#df7650"),
            LabelColor("Amber", "#c9952f"),
            LabelColor("Lime", "#7d9e45"),
            LabelColor("Emerald", "#3e9970"),
            LabelColor("Teal", "#379799"),
            LabelColor("Sky", "#478dc5"),
            LabelColor("Indigo", "#626fd0"),
            LabelColor("Violet", "#8a62c3"),
            LabelColor("Rose", "#c65f98"),
        )
    val PALETTE = COLORS.map { it.value }
    private val hex = Regex("^#[0-9a-fA-F]{6}$")

    fun validate(name: String, color: String): String? =
        when {
            name.isBlank() -> "label name is required"
            color.isNotBlank() && !hex.matches(color.trim()) ->
                "label color must be a hex color such as #6558df"
            else -> null
        }

    /** A palette color other than [exclude]. */
    fun randomColor(exclude: String? = null, random: Random = Random): String =
        PALETTE.filterNot { it.equals(exclude, ignoreCase = true) }.random(random)

    /** [color]'s palette entry, else the first. */
    fun named(color: String): LabelColor =
        COLORS.firstOrNull { it.value.equals(color, ignoreCase = true) } ?: COLORS.first()

    /** The same palette color for [id] on every launch and client. */
    fun stable(id: String): String = PALETTE[id.hashCode().mod(PALETTE.size)]
}

/** How competing versions of a shared record read when the user picks one. */
object ConflictVersions {
    /** A string value as itself, other JSON compactly, a deletion as "Deleted". */
    fun versionText(version: PeerVersion): String {
        if (version.deleted) return "Deleted"
        val raw = version.value_json.utf8()
        val element = runCatching { Json.parseToJsonElement(raw) }.getOrNull() ?: return raw
        return (element as? JsonPrimitive)?.takeIf { it.isString }?.content ?: element.toString()
    }

    fun keepLabel(version: PeerVersion): String =
        if (version.deleted) "Keep deletion" else "Keep this value"
}

/** Browser hostnames that route captured tasks to a project or board. */
object Hostnames {
    const val MAX = 64

    /**
     * Lowercase `host` or `host:port` values, deduplicated and sorted; rejects URLs, paths, and
     * wildcards.
     */
    fun normalize(values: List<String>): Result<List<String>> {
        val normalized = mutableSetOf<String>()
        for (raw in values) {
            val value = raw.trim()
            if (value.isEmpty()) continue
            val host: String
            val port: Int?
            when {
                value.startsWith("[") -> {
                    val end = value.indexOf(']')
                    if (end < 0) return invalid(value)
                    host = value.substring(1, end)
                    val rest = value.substring(end + 1)
                    port =
                        if (rest.isEmpty()) null
                        else rest.removePrefix(":").toIntOrNull() ?: return invalid(value)
                    if (':' !in host) return invalid(value)
                }
                value.count { it == ':' } == 1 -> {
                    host = value.substringBefore(':')
                    port = value.substringAfter(':').toIntOrNull() ?: return invalid(value)
                }
                value.count { it == ':' } > 1 -> {
                    host = value
                    port = null
                }
                else -> {
                    host = value
                    port = null
                }
            }
            val name = host.lowercase().trimEnd('.')
            if (
                name.isEmpty() ||
                    name.any {
                        it == '/' ||
                            it == '*' ||
                            it == '?' ||
                            it == '#' ||
                            it == '@' ||
                            it.isWhitespace()
                    }
            )
                return invalid(value)
            if (port != null && port !in 1..65535) return invalid(value)
            normalized +=
                when {
                    port == null -> name
                    ':' in name -> "[$name]:$port"
                    else -> "$name:$port"
                }
        }
        if (normalized.size > MAX)
            return Result.failure(
                IllegalArgumentException("at most 64 project hostnames are allowed")
            )
        return Result.success(normalized.sorted())
    }

    private fun invalid(value: String) =
        Result.failure<List<String>>(
            IllegalArgumentException(
                "invalid project hostname \"$value\": use host or host:port (1-65535), with IPv6 ports written as [::1]:4018; no URL, path, or wildcard"
            )
        )
}

/**
 * Client-side checks mirroring the daemon's prompt template validation, for live editor feedback.
 */
object PromptTemplates {
    const val MAX_BYTES = 32 * 1024
    val VARIABLES =
        listOf(
            "scope",
            "project.name",
            "project.id",
            "project.path",
            "project.registered_path",
            "project.summary",
            "project.instructions",
            "project.instructions_block",
            "workspace.path",
            "workspace.mode",
            "workspace.branch",
            "workspace.base_branch",
            "workspace.base_remote",
            "workspace.base_sha",
            "workspace.remote_publish_mode",
            "board.name",
            "board.id",
            "board.workflow",
            "board.description",
            "board.labels",
            "board.target_lane",
            "card.id",
            "card.title",
            "card.lane",
            "card.labels",
            "labels.instructions",
            "labels.instructions_block",
        )
    private val placeholder = Regex("\\{\\{\\s*([a-z0-9_.]+)\\s*\\}\\}")

    /**
     * The first problem with [template], or null; context templates must place both instruction
     * blocks once.
     */
    fun validate(template: String, context: Boolean = false): String? {
        if (template.isBlank()) return "template is required"
        if (template.encodeToByteArray().size > MAX_BYTES) return "template exceeds 32 KiB"
        val names = placeholder.findAll(template).map { it.groupValues[1] }.toList()
        names
            .firstOrNull { it !in VARIABLES }
            ?.let {
                return "unknown template variable {{$it}}"
            }
        val rest = placeholder.replace(template, "")
        if ("{{" in rest || "}}" in rest) return "template contains a malformed variable"
        if (context) {
            for (required in listOf("project.instructions_block", "labels.instructions_block")) {
                if (names.count { it == required } != 1)
                    return "template must contain {{$required}} exactly once"
            }
        }
        return null
    }
}
