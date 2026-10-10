package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.selection.Selections
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.core.state.CaptureFailure
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet

/** The request a capture is writing; empty until something is typed. */
val CaptureDraft.task: CreateConversationRequest
    get() = request ?: CreateConversationRequest()

/** Submitted drafts are frozen: the queued task can never diverge from what the user saw. */
val CaptureDraft.frozen: Boolean
    get() = submission_id.isNotEmpty()

/** Editing rules for a task capture. Every transition leaves a frozen draft unchanged. */
object TaskDrafts {
    /**
     * The title the created task shows: explicit, else from the task, else an attachment's name.
     */
    fun creationTitle(draft: CaptureDraft): String =
        draft.task.let { Titles.creation(it.title, it.prompt, it.attachments) }

    fun selection(draft: CaptureDraft): HarnessSelection =
        draft.task.let { HarnessSelection(it.provider, it.model, it.effort, it.provider_options) }

    fun workspaceMode(draft: CaptureDraft): WorkspaceMode =
        WorkspaceMode.parse(draft.task.workspace_mode)

    private fun CaptureDraft.editing(
        change: (CreateConversationRequest) -> CreateConversationRequest
    ): CaptureDraft = if (frozen) this else copy(request = change(task))

    fun title(draft: CaptureDraft, value: String) = draft.editing { it.copy(title = value) }

    fun prompt(draft: CaptureDraft, value: String) = draft.editing { it.copy(prompt = value) }

    fun lane(draft: CaptureDraft, value: String) = draft.editing { it.copy(lane = value) }

    fun workspaceMode(draft: CaptureDraft, mode: WorkspaceMode) = draft.editing {
        it.copy(workspace_mode = mode.wire)
    }

    fun labels(draft: CaptureDraft, ids: List<String>) = draft.editing {
        it.copy(label_ids = ids.distinct())
    }

    fun toggleLabel(draft: CaptureDraft, id: String): CaptureDraft {
        val ids = draft.task.label_ids
        return labels(draft, if (id in ids) ids - id else ids + id)
    }

    fun choose(draft: CaptureDraft, selection: HarnessSelection) = draft.editing {
        it.copy(
            provider = selection.provider,
            model = selection.model,
            effort = selection.effort,
            provider_options = selection.provider_options,
        )
    }

    /**
     * Another project: its boards, checkouts, and labels are different, so the destination starts
     * over.
     */
    fun project(draft: CaptureDraft, projectId: String): CaptureDraft {
        if (draft.frozen || draft.project_id == projectId) return draft
        return draft.copy(project_id = projectId, board_id = "", checkout_id = "").editing {
            it.copy(label_ids = emptyList())
        }
    }

    /**
     * Another board keeps only the labels it has and a lane a task may start in there
     * ([Creation.startLanes]).
     */
    fun board(draft: CaptureDraft, board: Board): CaptureDraft {
        if (draft.frozen) return draft
        val labels = board.labels.mapTo(HashSet()) { it.id }
        return draft.copy(board_id = board.id).editing { request ->
            request.copy(
                label_ids = request.label_ids.filter { it in labels },
                lane =
                    request.lane.takeIf { lane -> Creation.startLanes(board).any { it.id == lane } }
                        ?: Creation.defaultLane(board),
            )
        }
    }

    fun checkout(draft: CaptureDraft, checkoutId: String): CaptureDraft =
        if (draft.frozen) draft else draft.copy(checkout_id = checkoutId)

    /** Labels chosen on another board that this one lacks; they block saving until removed. */
    fun unavailableLabels(draft: CaptureDraft, board: Board?): List<String> {
        val labels = board?.labels.orEmpty().mapTo(HashSet()) { it.id }
        return draft.task.label_ids.filter { it !in labels }
    }

    fun removeUnavailableLabels(draft: CaptureDraft, board: Board?): CaptureDraft =
        labels(draft, draft.task.label_ids - unavailableLabels(draft, board).toSet())

    /**
     * The remembered agent and workspace, applied once and never over the user's edits: a refreshed
     * catalog or a brief outage must not reset them. A remembered agent the catalog does not offer
     * is not applied.
     */
    fun initialize(
        draft: CaptureDraft,
        defaults: HarnessSelection?,
        workspaceMode: WorkspaceMode,
        lane: String,
        harnesses: List<Harness>,
    ): CaptureDraft {
        var next = draft
        if (next.task.lane.isEmpty())
            next = next.editing { it.copy(lane = lane, workspace_mode = workspaceMode.wire) }
        if (
            next.task.provider.isEmpty() &&
                defaults != null &&
                Selections.supports(harnesses, defaults)
        )
            next = choose(next, defaults)
        return next
    }

    /** Adds an imported file, or records why it cannot be added. */
    fun admit(draft: CaptureDraft, part: MessagePart, source: String = ""): CaptureDraft {
        if (draft.frozen) return draft
        val attachments = draft.task.attachments + part
        val problem = Attachments.limitError(attachments)
        return if (problem != null) fail(draft, source, problem)
        else draft.editing { it.copy(attachments = attachments) }
    }

    fun fail(draft: CaptureDraft, source: String, message: String): CaptureDraft =
        draft.copy(failures = draft.failures + CaptureFailure(source, message))

    fun removeAttachment(draft: CaptureDraft, index: Int): CaptureDraft = draft.editing { request ->
        request.copy(
            attachments = request.attachments.filterIndexed { position, _ -> position != index }
        )
    }

    fun removeFailure(draft: CaptureDraft, failure: CaptureFailure): CaptureDraft =
        draft.copy(failures = draft.failures - failure)

    fun importing(draft: CaptureDraft, value: Boolean): CaptureDraft = draft.copy(importing = value)

    /**
     * Shared content arriving while another draft with content is open asks whether to add it
     * there; otherwise the share becomes the open draft.
     */
    fun asksToMerge(open: CaptureDraft?, incoming: CaptureDraft): Boolean =
        open != null && open.id != incoming.id && open.hasContent

    /** Why [share] cannot be added to [into], or null. */
    fun mergeProblem(into: CaptureDraft, share: CaptureDraft): String? =
        if (into.frozen) "The draft was already submitted."
        else Attachments.limitError(into.task.attachments + share.task.attachments)

    /**
     * Adds a share to [into]: its text below, its files after; a limit it would break is recorded
     * instead.
     */
    fun merge(into: CaptureDraft, share: CaptureDraft): CaptureDraft {
        if (into.frozen) return into
        val attachments = into.task.attachments + share.task.attachments
        mergeProblem(into, share)?.let {
            return fail(into, "", it)
        }
        return into
            .editing { request ->
                request.copy(
                    prompt =
                        listOf(request.prompt, share.task.prompt)
                            .filter { it.isNotBlank() }
                            .joinToString("\n"),
                    attachments = attachments,
                )
            }
            .copy(failures = into.failures + share.failures)
    }

    /**
     * "Todo · Worktree · Codex / Sol": where a quick task goes and who runs it
     * ([Creation.summary]).
     */
    fun summary(draft: CaptureDraft, board: Board?, harnesses: List<Harness>): String =
        Creation.summary(
            chat = false,
            lane = draft.task.lane,
            board = board,
            mode = workspaceMode(draft),
            selection = selection(draft),
            harnesses = harnesses,
        )

    /** What the creation rules validate and turn into a request. */
    fun input(
        draft: CaptureDraft,
        project: Project,
        board: Board?,
        checkoutId: String = draft.checkout_id,
    ): CreationInput =
        draft.task.let {
            CreationInput(
                project = project,
                board = board,
                checkoutId = checkoutId,
                lane = it.lane,
                title = it.title,
                prompt = it.prompt,
                attachments = it.attachments,
                selection = selection(draft),
                labelIds = it.label_ids,
                workspaceMode = workspaceMode(draft),
                vaultAccess = it.vault_access,
            )
        }

    /** [input] for a chat: no board, lane, or labels, so nothing of the open board carries over. */
    fun chatInput(
        draft: CaptureDraft,
        project: Project,
        checkoutId: String = draft.checkout_id,
    ): CreationInput =
        input(draft, project, null, checkoutId).copy(chat = true, lane = "", labelIds = emptyList())

    /** Why a draft with attachments still importing or failed cannot be submitted. */
    const val NOT_READY = "Wait for attachments to finish importing, or remove the failed ones."

    /**
     * Why [draft] cannot be queued as [input] yet, or null: its attachments first ([NOT_READY]),
     * then [Creation.problem].
     */
    fun problem(draft: CaptureDraft, input: CreationInput, harnesses: List<Harness>?): String? =
        if (!draft.ready) NOT_READY else Creation.problem(input, harnesses)

    /**
     * Adds [parts] together within the daemon's limits ([Attachments.appending]). A batch that
     * would break one fails whole and leaves [draft] as it was; a frozen draft stays unchanged.
     */
    fun attach(draft: CaptureDraft, parts: List<MessagePart>): Result<CaptureDraft> =
        if (draft.frozen) Result.success(draft)
        else
            Attachments.appending(draft.task.attachments, parts).map { combined ->
                draft.editing { it.copy(attachments = combined) }
            }
}

/**
 * One capture open in an editor. Edits apply to [state] at once, so a text field never lags; the
 * journal write follows on the core dispatcher, and a burst of keystrokes is written once. Safe to
 * call from any thread.
 */
class TaskDraftEditor(initial: CaptureDraft) {
    private val mutableState = MutableStateFlow(initial)
    val state: StateFlow<CaptureDraft> = mutableState.asStateFlow()
    private val mutableError = MutableStateFlow<String?>(null)

    /** The last journal write failed; edits stay here until a write succeeds. */
    val error: StateFlow<String?> = mutableError.asStateFlow()

    val id: String
        get() = state.value.id

    /** Applies [change] now; a frozen draft stays as it was submitted. */
    fun edit(change: (CaptureDraft) -> CaptureDraft): CaptureDraft =
        mutableState.updateAndGet { current ->
            val next = change(current)
            if (current.frozen && next.task != current.task) current else next
        }

    /** The journal froze the draft for submission; the frozen version wins. */
    internal fun adopt(saved: CaptureDraft) = mutableState.update { current ->
        if (saved.submission_id != current.submission_id) saved else current
    }

    internal fun saved(error: String?) {
        mutableError.value = error
    }
}
