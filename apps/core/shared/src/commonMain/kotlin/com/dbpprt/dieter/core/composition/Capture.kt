package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.core.state.CaptureFailure
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.time.Clock
import kotlin.uuid.Uuid
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/** [bound] turns true once the gateway's journal is attached; drafts made earlier would be replaced by it. */
data class CaptureView(val drafts: List<CaptureDraft> = emptyList(), val error: String? = null, val bound: Boolean = false)

/** Whether a capture has anything worth keeping. */
val CaptureDraft.hasContent: Boolean
    get() = request?.let { it.prompt.isNotBlank() || it.title.isNotBlank() || it.attachments.isNotEmpty() } == true || failures.isNotEmpty()

/** Ready to submit: no import in flight and nothing failed to import. */
val CaptureDraft.ready: Boolean get() = !importing && failures.isEmpty()

/**
 * Durable task captures (quick task, share intake), at most 20. Each survives
 * process death in its own file. The first submit freezes the request and a
 * submission ID; the outbox uses that ID as its command ID, so retrying after
 * a crash or a lost reply can never create a second task.
 */
class TaskCaptures(
    private val clock: Clock,
    private val logger: CoreLogger,
    /** The core dispatcher's scope; editors journal their edits on it. */
    private val scope: CoroutineScope? = null,
) {
    private var storage: CoreStorage? = null
    private val drafts = LinkedHashMap<String, CaptureDraft>()
    private val editors = HashMap<String, Pair<TaskDraftEditor, Job>>()
    private val mutableView = MutableStateFlow(CaptureView())
    val view: StateFlow<CaptureView> = mutableView.asStateFlow()

    fun bind(storage: CoreStorage?) {
        if (storage != null && storage.directory == this.storage?.directory) return
        this.storage = storage
        drafts.clear()
        editors.values.forEach { (_, job) -> job.cancel() }
        editors.clear()
        var unreadable = false
        val restored = storage?.names().orEmpty().filter { it.startsWith(PREFIX) && it.endsWith(SUFFIX) }.mapNotNull { name ->
            runCatching { CaptureDraft.ADAPTER.decode(storage!!.read(name)!!) }.onFailure { unreadable = true }.getOrNull()
        }
        for (draft in restored.sortedBy { it.updated_at_millis }.take(MAX_DRAFTS)) {
            // An import cut short by process death must be chosen again.
            drafts[draft.id] = if (draft.importing) draft.copy(importing = false, failures = draft.failures + CaptureFailure("", "Import was interrupted. Choose the file again.")) else draft
        }
        publish(if (unreadable) "A saved task could not be restored. Its files have been retained." else null)
    }

    fun draft(id: String): CaptureDraft? = drafts[id]

    /**
     * The draft to capture into: [preferred] when it exists, else an empty one,
     * else the most recent when the journal is full, else a new one.
     */
    fun begin(preferred: String? = null, projectId: String = "", boardId: String = ""): CaptureDraft {
        preferred?.let(drafts::get)?.let { return it }
        drafts.values.firstOrNull { !it.hasContent && it.submission_id.isEmpty() }?.let { return it }
        if (drafts.size >= MAX_DRAFTS) return drafts.values.last()
        return create(projectId, boardId)
    }

    /** The draft a board's task editor opens: its latest unsubmitted draft, else an empty one moved there, else a new one. */
    fun forBoard(projectId: String, boardId: String): CaptureDraft {
        drafts.values.lastOrNull { it.project_id == projectId && it.board_id == boardId && !it.frozen }?.let { return it }
        drafts.values.firstOrNull { !it.hasContent && !it.frozen }?.let { empty ->
            return save(empty.copy(project_id = projectId, board_id = boardId, checkout_id = ""))
        }
        return create(projectId, boardId)
    }

    /** The newest draft with content, to reopen after a restart or an account switch. */
    fun latest(): CaptureDraft? = drafts.values.lastOrNull { it.hasContent && !it.frozen }

    /**
     * The live editor of draft [id]. Its edits are journaled here in the
     * background, coalesced; [flush] writes the latest at once.
     */
    fun editor(id: String): TaskDraftEditor {
        editors[id]?.let { return it.first }
        val draft = drafts[id] ?: throw CoreException(FailureKind.PERMANENT, "The draft is no longer available.")
        val editor = TaskDraftEditor(draft)
        val scope = requireNotNull(scope) { "Editors need the core scope." }
        val job = scope.launch { editor.state.drop(1).collect { write(editor, it) } }
        editors[id] = editor to job
        return editor
    }

    /** Writes an open editor's latest state now, e.g. before submitting. */
    fun flush(id: String) {
        val editor = editors[id]?.first ?: return
        write(editor, editor.state.value)
        editor.error.value?.let { throw CoreException(FailureKind.OUT_OF_STORAGE, it) }
    }

    /** Writes every open editor now, e.g. when the app goes to the background. */
    fun flushAll() = editors.values.forEach { (editor, _) -> write(editor, editor.state.value) }

    private fun write(editor: TaskDraftEditor, latest: CaptureDraft) {
        if (drafts[latest.id] == null) return
        try {
            update(latest.id) { current -> if (current.frozen) current else latest }
            editor.saved(null)
        } catch (error: Throwable) {
            editor.saved(Failures.message(error))
        }
    }

    fun create(projectId: String = "", boardId: String = "", id: String = Uuid.random().toString()): CaptureDraft {
        require(ID.matches(id)) { "Invalid capture ID." }
        drafts[id]?.let { return it }
        if (drafts.size >= MAX_DRAFTS) throw CoreException(FailureKind.PERMANENT, "20 drafts retained. Discard a saved draft before capturing another task.")
        return save(CaptureDraft(id = id, project_id = projectId, board_id = boardId, request = CreateConversationRequest()))
    }

    /** Edits a draft. Once submitted, its request is frozen and only failures may change. */
    fun update(id: String, change: (CaptureDraft) -> CaptureDraft): CaptureDraft {
        val current = drafts[id] ?: throw CoreException(FailureKind.PERMANENT, "The draft is no longer available.")
        val next = change(current)
        if (current.submission_id.isNotEmpty() && (next.request != current.request || next.project_id != current.project_id || next.board_id != current.board_id)) {
            throw CoreException(FailureKind.PERMANENT, SUBMISSION_PENDING)
        }
        next.request?.attachments?.let { Attachments.limitError(it) }?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return save(next)
    }

    /** Freezes [request] for submission; a draft already submitted keeps its original request and ID. */
    fun freeze(id: String, request: CreateConversationRequest): CaptureDraft {
        val current = drafts[id] ?: throw CoreException(FailureKind.PERMANENT, "The draft is no longer available.")
        if (current.submission_id.isNotEmpty()) return current
        if (!current.ready) throw CoreException(FailureKind.PERMANENT, TaskDrafts.NOT_READY)
        return save(current.copy(request = request, submission_id = Uuid.random().toString(), submitted = true))
            .also { frozen -> editors[id]?.first?.adopt(frozen) }
    }

    /** The outbox accepted the task durably; the capture is done. */
    fun accepted(id: String) = discard(id)

    fun discard(id: String) {
        editors.remove(id)?.second?.cancel()
        drafts.remove(id) ?: return
        storage?.delete(file(id))
        publish(null)
    }

    private fun save(draft: CaptureDraft): CaptureDraft {
        val stamped = draft.copy(updated_at_millis = clock.now().toEpochMilliseconds())
        val bytes = CaptureDraft.ADAPTER.encode(stamped)
        if (bytes.size > MAX_FILE_BYTES) throw CoreException(FailureKind.PERMANENT, "Task text is too large.")
        try {
            storage?.write(file(draft.id), bytes)
        } catch (error: Throwable) {
            val message = "Could not save draft: ${Failures.message(error)}. Free device storage and retry."
            publish(message)
            throw CoreException(FailureKind.OUT_OF_STORAGE, message, error)
        }
        drafts.remove(draft.id)
        drafts[draft.id] = stamped
        publish(null)
        return stamped
    }

    private fun publish(error: String?) {
        mutableView.value = CaptureView(drafts.values.toList(), error, bound = storage != null)
    }

    private fun file(id: String) = "$PREFIX$id$SUFFIX"

    companion object {
        const val MAX_DRAFTS = 20

        /** Shown with a submitted draft until the outbox accepts it; its request stays as submitted. */
        const val SUBMISSION_PENDING = "Submission pending. Retry Save with the same task; attachments are retained."

        const val MAX_FILE_BYTES = 8 * 1024 * 1024
        private const val PREFIX = "capture-"
        private const val SUFFIX = ".pb"
        private val ID = Regex("[A-Za-z0-9-]{1,80}")
    }
}
