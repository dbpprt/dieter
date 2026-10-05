package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.core.selection.Selections
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.core.state.CreationPreferences
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
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

    /** How a picker offers this mode for a new conversation: "New worktree" or "Project directory". */
    val choiceTitle: String get() = if (this == WORKTREE) "New worktree" else title
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
    /** Worktree only: the new branch; blank lets the daemon name it. */
    val workspaceBranch: String = "",
    /** Worktree only: blank takes the project's base branch. */
    val workspaceBaseBranch: String = "",
    /** Worktree only: blank takes the board's base remote, else the project's. */
    val workspaceBaseRemote: String = "",
    /** Worktree only: blank takes the board's publish mode, else "manual". */
    val remotePublishMode: String = "",
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

/** Where new conversations can run, as the core knows it now. */
data class CreationDestinations(
    /** Machines online now. */
    val online: Set<String> = emptySet(),
    /** This device's machine, when it runs a reachable one. */
    val localDaemonId: String? = null,
    /** Project ID → the reachable machine that serves it ([com.dbpprt.dieter.core.machines.MachineChoice.project]). */
    val projectMachines: Map<String, String> = emptyMap(),
    /** Daemon ID → its loaded agent catalog. */
    val catalogs: Map<String, List<Harness>> = emptyMap(),
)

/** A new task or chat checked against its destination ([Creation.plan]). */
data class CreationPlan(
    val input: CreationInput,
    /** The checkout it runs on; null while none is chosen. */
    val checkout: Checkout?,
    /** The machine that runs it: the checkout's. */
    val daemonId: String?,
    val machineOnline: Boolean,
    val catalogState: CatalogState,
    /** What the agent pickers offer: the catalog of [Creation.catalogMachine]; empty while it loads. */
    val harnesses: List<Harness>,
) {
    /** The catalog [input] is validated against; null while it loads, or for a chat whose machine is offline. */
    val catalog: List<Harness>? get() = Creation.catalog(input.chat, catalogState, harnesses)

    /** Why it cannot be queued yet, or null. */
    val problem: String? get() = Creation.problem(input, catalog)

    /** The agent pickers for [input]'s selection. */
    val controls: AgentControls get() = AgentControls(input.selection, harnesses)

    val destinationStatus: String get() = Creation.destinationStatus(input.project, checkout, machineOnline, catalogState)

    /** Shown under a task editor whose destination is offline; null while online or before a checkout is chosen. */
    val offlineHint: String? get() = if (checkout == null || machineOnline) null else Creation.offlineHint(catalogState)

    /** The destination is online but its catalog is not live yet: load it before validating. */
    val needsCatalog: Boolean get() = Creation.needsCatalog(checkout, machineOnline, catalogState)
}

/** Rules for creating conversations, shared by every creation surface. */
object Creation {
    /** Lanes a new task may start in: Todo saves it, Running starts it at once. */
    fun startLanes(board: Board?): List<Lane> = board?.lanes.orEmpty().filter { Lanes.isTodo(it.id) || Lanes.isRunning(it.id) }

    fun startsImmediately(lane: String): Boolean = !defersStart(chat = false, lane = lane)

    /** The task editor's submit button: "Create & run" for a task that starts at once, else "Save". */
    fun submitTitle(lane: String): String = if (startsImmediately(lane)) "Create & run" else "Save"

    /** What submitting a task in [lane] does. */
    fun startNote(lane: String): String =
        if (startsImmediately(lane)) "The first message starts immediately." else "The card is saved as a draft in Todo."

    /** Why nothing can be created without a project. */
    const val NO_PROJECT = "Choose a project."

    /** A checkout as destination pickers name it: its name, else "Project checkout", ending " · Offline" while its machine is offline. */
    fun checkoutTitle(checkout: Checkout, machineOnline: Boolean = true): String =
        checkout.name.ifBlank { "Project checkout" } + (if (machineOnline) "" else " · Offline")

    /** The machine whose catalog a new conversation loads: its checkout's, else the one that serves its project. */
    fun catalogMachine(checkout: Checkout?, projectDaemonId: String?): String? =
        checkout?.daemon_id?.ifEmpty { null } ?: projectDaemonId?.ifEmpty { null }

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
        else -> checkoutTitle(checkout)
    }

    /** Shown under a task editor whose destination is offline. */
    fun offlineHint(state: CatalogState): String =
        if (state == CatalogState.CACHED) "Offline · saved tasks queue on this device until the destination reconnects."
        else "Reconnect to validate the destination. Your draft is kept on this device."

    /** Only a task placed in running starts at once; chats always start. */
    fun defersStart(chat: Boolean, lane: String): Boolean = !chat && !lane.equals(Lanes.RUNNING, ignoreCase = true)

    /** Chats and started tasks open after creation; todo tasks stay on the board. */
    fun opensAfterCreate(chat: Boolean, lane: String): Boolean = chat || !Lanes.isTodo(lane)

    /** The lane a new task starts in unless another is chosen: the board's first start lane, else its first lane. */
    fun defaultLane(board: Board?): String = startLanes(board).firstOrNull()?.id ?: board?.lanes?.firstOrNull()?.id ?: Lanes.TODO

    /** The lane a new task starts in: [selected] when it is one of [board]'s start lanes, else [defaultLane]. */
    fun startLane(board: Board?, selected: String?): String =
        startLanes(board).firstOrNull { it.id.equals(selected, ignoreCase = true) }?.id ?: defaultLane(board)

    /** The checkouts a destination picker offers: every attached one, in the project's order. */
    fun choices(project: Project): List<Checkout> = project.checkouts.filterNot { it.detached }

    /**
     * The checkout to run on: the chosen one when it still exists and is
     * attached, else the only one. Several checkouts need an explicit choice.
     */
    fun checkout(project: Project, selectedId: String?): Checkout? {
        val candidates = choices(project)
        return candidates.firstOrNull { it.id == selectedId } ?: candidates.singleOrNull()
    }

    /**
     * The checkout a new conversation runs on unless another is chosen: the
     * [selectedId] one while it is attached, else this device's machine's,
     * else the only one. Never just the first of several; then the user
     * chooses.
     */
    fun preferredCheckout(project: Project, selectedId: String?, localDaemonId: String?): Checkout? {
        val candidates = choices(project)
        return candidates.firstOrNull { it.id == selectedId }
            ?: candidates.firstOrNull { !localDaemonId.isNullOrEmpty() && it.daemon_id == localDaemonId }
            ?: candidates.singleOrNull()
    }

    /** The board to preselect: [rememberedId] unless it is retired or gone, else the first live board. */
    fun preferredBoard(rememberedId: String?, boards: List<Board>): Board? =
        boards.firstOrNull { it.id == rememberedId && !it.retired } ?: boards.firstOrNull { !it.retired }

    /** Why [input] cannot be queued yet, or null. */
    fun problem(input: CreationInput, harnesses: List<Harness>?): String? {
        if (input.project.id.isEmpty()) return NO_PROJECT
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
            if (startLanes(board).none { it.id == input.lane }) return "A new task starts in Todo or Running."
            val labels = board.labels.mapTo(HashSet()) { it.id }
            if (input.labelIds.any { it !in labels }) return "Remove labels unavailable on this board"
        }
        return null
    }

    /** The title the new card or chat shows at once: the explicit one, else a placeholder from the prompt or an attachment. */
    fun title(input: CreationInput): String =
        input.title.trim().ifEmpty { if (input.chat) Titles.chat(input.prompt, input.attachments) else Titles.creation("", input.prompt, input.attachments) }

    /**
     * The request to queue. A blank title becomes a placeholder the daemon
     * replaces with a generated one ([Titles.generated]); worktree fields,
     * with the input's overrides of the project's and board's defaults, are
     * sent only in worktree mode.
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
            title = title(input),
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
            workspace_base_branch = if (worktree) input.workspaceBaseBranch.trim().ifEmpty { input.project.base_branch } else "",
            workspace_base_remote = if (worktree) input.workspaceBaseRemote.trim().ifEmpty { null } ?: board?.base_remote?.ifEmpty { null } ?: input.project.base_remote else "",
            remote_publish_mode = if (worktree) input.remotePublishMode.trim().ifEmpty { null } ?: board?.remote_publish_mode?.ifEmpty { null } ?: "manual" else "",
            auto_generate_title = Titles.generated(input.title, input.prompt),
        )
    }

    /**
     * "Todo · Worktree · Codex / Sol · Fast": where a new task goes and who
     * runs it; a chat leaves out the lane. The lane is [lane] on [board], else
     * its first; "Agent defaults" until the agent is known; "Fast" when the
     * model's fast mode is on.
     */
    fun summary(chat: Boolean, lane: String, board: Board?, mode: WorkspaceMode, selection: HarnessSelection, harnesses: List<Harness>): String {
        val harness = Selections.harness(harnesses, selection.provider)
        val model = harness?.let { Selections.model(it, selection.model) }
        val agent = if (harness != null && model != null) "${harness.name} / ${model.name}" else "Agent defaults"
        val fast = harness != null && Selections.normalizedOptions(harness, selection.model, selection.provider_options)[FAST_MODE] == "true"
        return buildList {
            if (!chat) add((board?.lanes?.firstOrNull { it.id == lane } ?: board?.lanes?.firstOrNull())?.name ?: "Todo")
            add(mode.title)
            add(agent)
            if (fast) add("Fast")
        }.joinToString(" · ")
    }

    /** The provider option that trades depth for speed, where a harness offers it. */
    const val FAST_MODE = "fast_mode"

    /** How long queuing a new conversation waits for an online destination's catalog to load. */
    val CATALOG_WAIT: Duration = 5.seconds

    /**
     * [input] checked against its destination: the checkout's machine, its
     * catalog (live when online, cached when offline), and the agent pickers.
     * [destinations] is what the core knows of machines and catalogs now.
     */
    fun plan(input: CreationInput, destinations: CreationDestinations): CreationPlan {
        val checkout = checkout(input.project, input.checkoutId)
        val daemonId = checkout?.daemon_id?.ifEmpty { null }
        val online = daemonId != null && daemonId in destinations.online
        val loaded = daemonId?.takeIf { it in destinations.catalogs }
        val catalogMachine = catalogMachine(checkout, destinations.projectMachines[input.project.id])
        return CreationPlan(
            input = input, checkout = checkout, daemonId = daemonId, machineOnline = online,
            catalogState = catalogState(checkout, loaded, online),
            harnesses = catalogMachine?.let(destinations.catalogs::get).orEmpty(),
        )
    }
}

/** Creation choices remembered on this device: last agent, workspace mode, and per-project board and checkout. */
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

    /** Remembers what was given; a board or checkout belongs to [projectId] and needs it. */
    fun remember(selection: HarnessSelection? = null, workspaceMode: WorkspaceMode? = null, projectId: String? = null, boardId: String? = null, checkoutId: String? = null) {
        var next = state.value
        if (selection != null) next = next.copy(provider = selection.provider, model = selection.model, effort = selection.effort, provider_options = selection.provider_options)
        if (workspaceMode != null) next = next.copy(workspace_mode = workspaceMode.wire)
        if (projectId != null) {
            next = next.copy(
                project_id = projectId,
                boards = if (boardId != null) next.boards + (projectId to boardId) else next.boards,
                checkouts = if (checkoutId != null) next.checkouts + (projectId to checkoutId) else next.checkouts,
            )
        }
        save(next)
    }

    /** After [input] was queued, its agent, workspace mode, project, board (a task's), and checkout become the defaults. */
    fun remember(input: CreationInput) = remember(
        selection = input.selection, workspaceMode = input.workspaceMode, projectId = input.project.id,
        boardId = input.board?.id?.takeIf { !input.chat }, checkoutId = input.checkoutId.ifEmpty { null },
    )

    fun rememberedBoard(project: Project, boards: List<Board>): Board? = Creation.preferredBoard(state.value.boards[project.id], boards)

    /** [project]'s checkout to preselect ([Creation.preferredCheckout]), starting from the one last chosen there. */
    fun preferredCheckout(project: Project, localDaemonId: String?): Checkout? =
        Creation.preferredCheckout(project, state.value.checkouts[project.id], localDaemonId)

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
        add(Counts.of(boards, "board"))
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

    /** The board a capture goes to without asking: [boards]' only live board, else null (the user chooses). */
    fun soleBoard(boards: List<Board>): Board? = boards.filterNot { it.retired }.singleOrNull()

    /** A submitted capture keeps the destination it was submitted to. */
    fun selectable(draft: CaptureDraft, projectId: String, boardId: String? = null): Boolean {
        val submitted = draft.request?.takeIf { draft.frozen } ?: return true
        return submitted.project_id == projectId && (boardId == null || submitted.board_id == boardId)
    }

    /**
     * Where a project's repository lives: each checkout's machine, online ones
     * first, marked offline or unavailable.
     */
    fun checkoutSummary(project: Project, label: (String) -> String, online: (String) -> Boolean?): String =
        Creation.choices(project).map { it.daemon_id }.distinct()
            .sortedWith(compareByDescending<String> { online(it) == true }.thenBy { label(it).lowercase() })
            .joinToString(" · ") { daemonId ->
                label(daemonId) + when (online(daemonId)) {
                    true -> ""
                    false -> " (offline)"
                    null -> " (unavailable)"
                }
            }.ifEmpty { "No checkouts" }
}
