package com.dbpprt.dieter.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.Html
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.composition.CaptureView
import com.dbpprt.dieter.core.composition.TaskDraftEditor
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.frozen
import com.dbpprt.dieter.core.state.CaptureFailure
import com.dbpprt.dieter.core.runtime.Failures
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withTimeout
import java.util.UUID

/**
 * Android intake for task captures: share intents and document URIs. The
 * drafts, their editing rules, the journal, and the at-most-once submission
 * are the shared core's; this adapter only reads what Android hands over.
 * File payloads never enter saved-instance-state.
 */
internal class TaskCaptureStore(private val context: Context, private val core: CoreRuntime) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val view: StateFlow<CaptureView> = core.captures.view

    /** A share that arrived and waits for the capture host to open it. */
    var incoming by mutableStateOf<TaskDraftEditor?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    private val imports = mutableMapOf<String, Job>()

    suspend fun editor(id: String): TaskDraftEditor = core.onCore { core.captures.editor(id) }

    /** The draft to capture into: an empty one, else a new one. */
    suspend fun begin(): TaskDraftEditor = core.onCore { core.captures.editor(core.captures.begin().id) }

    /** The task draft of a board's editor and quick task. */
    suspend fun forBoard(projectId: String, boardId: String): TaskDraftEditor =
        core.onCore { core.captures.editor(core.captures.forBoard(projectId, boardId).id) }

    /** The newest draft with content, to reopen after a restart or an account switch. */
    suspend fun latest(): TaskDraftEditor? = core.onCore { core.captures.latest()?.let { core.captures.editor(it.id) } }

    suspend fun flush(editor: TaskDraftEditor) = core.onCore { core.captures.flush(editor.id) }

    /** Writes every open draft now, before Android may stop the process. */
    fun flushAll() {
        scope.launch { core.onCore { core.captures.flushAll() } }
    }

    fun discard(id: String) {
        imports.remove(id)?.cancel()
        if (incoming?.id == id) incoming = null
        scope.launch { core.onCore { core.captures.discard(id) } }
    }

    fun close() { scope.cancel() }

    fun consumeIncoming() { incoming = null }
    fun clearError() { error = null }

    fun receive(intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        // Stored on the Activity's intent and in onSaveInstanceState by MainActivity.
        val id = intent.getStringExtra(CAPTURE_ID) ?: UUID.randomUUID().toString().also { intent.putExtra(CAPTURE_ID, it) }
        scope.launch {
            view.first { it.bound }
            try {
                val existing = core.onCore { core.captures.draft(id) }
                val editor = core.onCore { core.captures.create(id = id).let { core.captures.editor(it.id) } }
                incoming = editor
                if (existing != null) return@launch
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                    ?: intent.getStringExtra(Intent.EXTRA_HTML_TEXT)?.let { Html.fromHtml(it, Html.FROM_HTML_MODE_LEGACY).toString() }
                    ?: intent.clipData?.let { clip -> (0 until minOf(clip.itemCount, 5)).mapNotNull { clip.getItemAt(it).text?.toString() }.joinToString("\n") }.orEmpty()
                editor.edit { TaskDrafts.prompt(it, text) }
                flush(editor)
                runCatching { sharedUris(intent) }
                    .onSuccess { import(editor, it) }
                    .onFailure { editor.edit { draft -> TaskDrafts.fail(draft, "", "This share could not be read. Choose the files again.") } }
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: Exception) {
                error = Failures.message(failure)
            }
        }
    }

    /** Reads [uris] into the draft one by one; the core decides what fits. */
    fun import(editor: TaskDraftEditor, uris: List<Uri>, imagesOnly: Boolean = false) {
        val draft = editor.state.value
        if (draft.importing || draft.frozen) return
        // Admit synchronously: Save must never race an import that has not started.
        editor.edit { TaskDrafts.importing(it, true) }
        val job = scope.launch {
            for (uri in uris.distinct().take(Attachments.MAX_COUNT + 1)) {
                ensureActive()
                val source = uri.toString()
                try {
                    val part = withTimeout(30_000) { runInterruptible(Dispatchers.IO) { readAttachmentPart(context, uri, imagesOnly) } }
                    ensureActive()
                    editor.edit { TaskDrafts.admit(it, part, source) }
                } catch (timeout: TimeoutCancellationException) {
                    editor.edit { TaskDrafts.fail(it, source, "Reading the file timed out. Try again.") }
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (failure: Exception) {
                    editor.edit { TaskDrafts.fail(it, source, failure.message ?: "Could not read file. Choose it again.") }
                }
            }
        }
        imports[editor.id] = job
        job.invokeOnCompletion {
            if (imports[editor.id] === job) imports.remove(editor.id)
            editor.edit { TaskDrafts.importing(it, false) }
        }
    }

    fun cancelImport(editor: TaskDraftEditor) { imports[editor.id]?.cancel() }

    /** Reads a failed file again, if Android still grants access to it. */
    fun retry(editor: TaskDraftEditor, failure: CaptureFailure) {
        if (editor.state.value.importing || failure.source.isBlank()) return
        editor.edit { TaskDrafts.removeFailure(it, failure) }
        import(editor, listOf(Uri.parse(failure.source)))
    }

    companion object {
        const val CAPTURE_ID = "com.dbpprt.dieter.CAPTURE_ID"
    }
}

@Suppress("DEPRECATION")
internal fun sharedUris(intent: Intent): List<Uri> = buildList {
    if (intent.action == Intent.ACTION_SEND_MULTIPLE) addAll(intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty())
    else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::add)
    intent.clipData?.let { clip -> repeat(minOf(clip.itemCount, 100)) { clip.getItemAt(it).uri?.let(::add) } }
}.distinct().take(Attachments.MAX_COUNT + 1)
