package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.selection.Selections
import com.dbpprt.dieter.core.state.CreationPreferences
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class WorkspaceMode(val wire: String, val title: String, val shortTitle: String, val detail: String) {
    PROJECT("project", "Project directory", "Project", "Use the registered project directory on whichever branch it currently has checked out."),
    WORKTREE("worktree", "Worktree", "Worktree", "Create a new isolated Git worktree and branch for this conversation.");

    companion object {
        /** Anything other than "worktree" runs in the project checkout. */
        fun parse(value: String?): WorkspaceMode = if (value.equals(WORKTREE.wire, ignoreCase = true)) WORKTREE else PROJECT

        /** Where [card] runs: its own mode, else its workspace's. */
        fun of(card: Card): WorkspaceMode = parse(card.workspace_mode.ifBlank { card.workspace?.mode.orEmpty() })

        /** The order pickers offer them: an isolated worktree first. */
        val choices: List<WorkspaceMode> = listOf(WORKTREE, PROJECT)
    }
}

/** What a new task or chat needs before it can be queued. */
data class CreationInput(
    val project: Project,
    val board: Board? = null,
    val checkoutId: String = "",
    val chat: Boolean = false,
    val lane: String = "",
    val title: String = "",
    val prompt: String = "",
    val attachments: List<MessagePart> = emptyList(),
    val selection: HarnessSelection = HarnessSelection(),
    val labelIds: List<String> = emptyList(),
    val workspaceMode: WorkspaceMode = WorkspaceMode.WORKTREE,
    val workspaceBranch: String = "",
)

/** The agent catalog a new conversation is checked against, relative to its destination machine. */
enum class CatalogState {
    /** No catalog from the destination's machine yet. */
    NONE,

    /** The machine is offline; its last catalog is known, so tasks can still be queued. */
    CACHED,

    /** Loaded from the online destination machine. */
    LIVE,
}

/** Rules for creating conversations, shared by every creation surface. */
object Creation {
    /** Lanes a new task may start in: Todo saves it, Running starts it at once. */
    fun startLanes(board: Board?): List<Lane> = board?.lanes.orEmpty().filter { Lanes.isTodo(it.id) || Lanes.isRunning(it.id) }

    fun startsImmediately(lane: String): Boolean = !defersStart(chat = false, lane = lane)

    /** The machine whose catalog a new conversation loads: its checkout's, else the project's replica, else the attached machine. */
    fun catalogMachine(checkout: Checkout?, replicaDaemonId: String?, attachedDaemonId: String?): String? =
        checkout?.daemon_id?.ifEmpty { null } ?: replicaDaemonId?.ifEmpty { null } ?: attachedDaemonId?.ifEmpty { null }

    fun catalogState(checkout: Checkout?, catalogDaemonId: String?, machineOnline: Boolean): CatalogState = when {
        checkout == null || catalogDaemonId == null || checkout.daemon_id != catalogDaemonId -> CatalogState.NONE
        machineOnline -> CatalogState.LIVE
        else -> CatalogState.CACHED
    }

    /**
     * The catalog to validate against, or null while it loads. A chat starts
     * at once and needs the live catalog; a task queues against a cached one.
     */
    fun catalog(chat: Boolean, state: CatalogState, harnesses: List<Harness>): List<Harness>? = when (state) {
        CatalogState.LIVE -> harnesses
        CatalogState.CACHED -> harnesses.takeIf { !chat }
        CatalogState.NONE -> null
    }

    /** An online destination whose catalog is not live yet must load it before anything can be validated. */
    fun needsCatalog(checkout: Checkout?, machineOnline: Boolean, state: CatalogState): Boolean =
        checkout != null && machineOnline && state != CatalogState.LIVE

    /** The destination picker's status line. */
    fun destinationStatus(project: Project?, checkout: Checkout?, machineOnline: Boolean, state: CatalogState): String = when {
        project?.checkouts.orEmpty().none { !it.detached } -> "No checkouts available for this project"
        checkout == null -> "Choose where this task will run"
        !machineOnline -> "Machine offline · choose an online destination"
        state != CatalogState.LIVE -> "Loading agent models…"
        else -> checkout.name.ifBlank { "Project checkout" }
    }

    /** Shown under a task editor whose destination is offline. */
    fun offlineHint(state: CatalogState): String =
        if (state == CatalogState.CACHED) "Offline · saved tasks queue on this device until the destination reconnects."
        else "Reconnect to validate the destination. Your draft is kept on this device."

    /** Only a task placed in running starts at once; chats always start. */
    fun defersStart(chat: Boolean, lane: String): Boolean = !chat && !lane.equals(Lanes.RUNNING, ignoreCase = true)

    /** Chats and started tasks open after creation; todo tasks stay on the board. */
    fun opensAfterCreate(chat: Boolean, lane: String): Boolean = chat || !Lanes.isTodo(lane)

    fun defaultLane(board: Board?): String = board?.lanes?.firstOrNull()?.id ?: Lanes.TODO

    /**
     * The checkout to run on: the chosen one when it still exists and is
     * attached, else the only one. Several checkouts need an explicit choice.
     */
    fun checkout(project: Project, selectedId: String?): Checkout? {
        val candidates = project.checkouts.filterNot { it.detached }
        return candidates.firstOrNull { it.id == selectedId } ?: candidates.singleOrNull()
    }

    /** A default choice: the selection, the catalog machine's, the only one, then the project replica's. */
    fun preferredCheckout(project: Project, selectedId: String?, catalogDaemonId: String?, replicaDaemonId: String?): Checkout? {
        val candidates = project.checkouts.filterNot { it.detached }
        return candidates.firstOrNull { it.id == selectedId }
            ?: candidates.firstOrNull { catalogDaemonId != null && it.daemon_id == catalogDaemonId }
            ?: candidates.singleOrNull()
            ?: candidates.firstOrNull { replicaDaemonId != null && it.daemon_id == replicaDaemonId }
    }

    /** Why [input] cannot be queued yet, or null. */
    fun problem(input: CreationInput, harnesses: List<Harness>?): String? {
        if (input.project.id.isEmpty()) return "Choose a project."
        if (checkout(input.project, input.checkoutId) == null) {
            return if (input.project.checkouts.none { !it.detached }) "No checkouts available for this project" else "Choose where this task will run"
        }
        if (harnesses == null) return "Loading agent models…"
        if (!Selections.supports(harnesses, input.selection)) return "Choose an agent and model."
        if (input.prompt.isBlank() && input.attachments.isEmpty() && (input.chat || input.title.isBlank())) return "Describe the task."
        Attachments.limitError(input.attachments)?.let { return it }
        val board = input.board
        if (!input.chat) {
            if (board == null) return "Choose a board."
            if (board.retired) return "This board is retired."
            if (board.lanes.none { it.id == input.lane }) return "Choose a lane on this board."
            val labels = board.labels.mapTo(HashSet()) { it.id }
            if (input.labelIds.any { it !in labels }) return "Remove labels unavailable on this board"
        }
        return null
    }

    /**
     * The request to queue. A blank title becomes a placeholder the daemon
     * replaces with a generated one; worktree fields are sent only in worktree mode.
     */
    fun request(input: CreationInput): CreateConversationRequest {
        val board = input.board
        val worktree = input.workspaceMode == WorkspaceMode.WORKTREE
        val lane = if (input.chat) "" else input.lane.ifEmpty { defaultLane(board) }
        return CreateConversationRequest(
            checkout_id = checkout(input.project, input.checkoutId)?.id.orEmpty(),
            project_id = input.project.id,
            board_id = if (input.chat) "" else board?.id.orEmpty(),
            lane = lane,
            title = input.title.trim().ifEmpty { if (input.chat) Titles.chat(input.prompt, input.attachments) else Titles.creation("", input.prompt, input.attachments) },
            prompt = input.prompt.trim(),
            provider = input.selection.provider,
            model = input.selection.model,
            effort = input.selection.effort,
            provider_options = input.selection.provider_options,
            label_ids = if (input.chat) emptyList() else input.labelIds,
            defer_start = defersStart(input.chat, lane),
            attachments = input.attachments,
            workspace_mode = input.workspaceMode.wire,
            workspace_branch = if (worktree) input.workspaceBranch.trim() else "",
            workspace_base_branch = if (worktree) input.project.base_branch else "",
            workspace_base_remote = if (worktree) (board?.base_remote?.ifEmpty { null } ?: input.project.base_remote) else "",
            remote_publish_mode = if (worktree) board?.remote_publish_mode?.ifEmpty { null } ?: "manual" else "",
            auto_generate_title = input.title.isBlank() && input.prompt.isNotBlank(),
        )
    }
}

/** Creation choices remembered on this device: last agent, workspace mode, and per-project board. */
class CreationMemory(private val storage: CoreStorage, private val logger: CoreLogger) {
    private val mutableState = MutableStateFlow(load())
    val state: StateFlow<CreationPreferences> = mutableState.asStateFlow()

    private fun load(): CreationPreferences =
        storage.read(FILE)?.let { runCatching { CreationPreferences.ADAPTER.decode(it) }.getOrNull() } ?: CreationPreferences(workspace_mode = WorkspaceMode.WORKTREE.wire)

    /** The remembered agent, validated against [harnesses]. */
    fun selection(harnesses: List<Harness>): HarnessSelection? {
        val saved = state.value
        return Selections.resolve(HarnessSelection(saved.provider, saved.model, saved.effort, saved.provider_options), harnesses)
    }

    val workspaceMode: WorkspaceMode get() = WorkspaceMode.parse(state.value.workspace_mode)

    fun remember(selection: HarnessSelection? = null, workspaceMode: WorkspaceMode? = null, projectId: String? = null, boardId: String? = null) {
        var next = state.value
        if (selection != null) next = next.copy(provider = selection.provider, model = selection.model, effort = selection.effort, provider_options = selection.provider_options)
        if (workspaceMode != null) next = next.copy(workspace_mode = workspaceMode.wire)
        if (projectId != null) next = next.copy(project_id = projectId, boards = if (boardId != null) next.boards + (projectId to boardId) else next.boards)
        save(next)
    }

    fun rememberedBoard(project: Project, boards: List<Board>): Board? =
        state.value.boards[project.id]?.let { id -> boards.firstOrNull { it.id == id && !it.retired } } ?: boards.firstOrNull { !it.retired }

    fun setBoardNotifications(boardId: String, enabled: Boolean) {
        if (boardId.isBlank()) return
        val current = state.value
        save(current.copy(notification_boards = if (enabled) current.notification_boards + (boardId to true) else current.notification_boards - boardId))
    }

    fun notifiesBoard(boardId: String): Boolean = state.value.notification_boards[boardId] == true

    /** Adopts a legacy app's choices unless this device already made its own. */
    fun adopt(preferences: CreationPreferences): Boolean {
        if (storage.read(FILE) != null) return false
        save(preferences)
        return true
    }

    private fun save(next: CreationPreferences) {
        if (next == state.value) return
        runCatching { storage.write(FILE, CreationPreferences.ADAPTER.encode(next)) }.onFailure { logger.warn("Creation", "could not save creation choices", it) }
        mutableState.value = next
    }

    private companion object {
        const val FILE = "creation.pb"
    }
}

/** Describes where a capture can go, for the destination chooser. */
object CaptureDestinations {
    fun projectInfo(project: Project, boards: Int, offline: Boolean): String = buildList {
        add(if (boards == 1) "1 board" else "$boards boards")
        if (project.checkouts.size > 1) add("${project.checkouts.size} checkouts")
        if (offline) add("Offline")
    }.joinToString(" · ")

    /** The workflow and base branch; the platform adds the creation date when names repeat. */
    fun boardInfo(board: Board, project: Project): String = buildList {
        add(
            when (board.workflow) {
                "review" -> "Review workflow"
                "direct" -> "Direct workflow"
                else -> "${board.lanes.size} lanes"
            },
        )
        val branch = listOf(board.base_remote.ifBlank { project.base_remote }, project.base_branch).filter { it.isNotBlank() }.joinToString("/")
        if (branch.isNotBlank()) add(branch)
    }.joinToString(" · ")

    /** A submitted capture keeps the destination it was submitted to. */
    fun selectable(draft: com.dbpprt.dieter.core.state.CaptureDraft, projectId: String, boardId: String? = null): Boolean {
        val submitted = draft.request?.takeIf { draft.frozen } ?: return true
        return submitted.project_id == projectId && (boardId == null || submitted.board_id == boardId)
    }

    /**
     * Where a project's repository lives: each checkout's machine, online ones
     * first, marked offline or unavailable. A replica is not a checkout.
     */
    fun checkoutSummary(project: Project, label: (String) -> String, online: (String) -> Boolean?): String =
        project.checkouts.filterNot { it.detached }.map { it.daemon_id }.distinct()
            .sortedWith(compareByDescending<String> { online(it) == true }.thenBy { label(it).lowercase() })
            .joinToString(" · ") { daemonId ->
                label(daemonId) + when (online(daemonId)) {
                    true -> ""
                    false -> " (offline)"
                    null -> " (unavailable)"
                }
            }.ifEmpty { "No checkouts" }
}
