package com.dbpprt.dieter.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.Html
import android.util.AtomicFile
import androidx.compose.runtime.*
import com.dbpprt.dieter.v1.CreateConversationRequest
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Private, bounded draft journal. File payloads never enter saved-instance-state. */
internal class TaskCaptureStore(
    private val context: Context,
    private val directory: File = File(context.noBackupFilesDir, "task-capture"),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val drafts = mutableStateListOf<CardCreationDraft>()
    var incoming by mutableStateOf<CardCreationDraft?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    private val watchers = mutableMapOf<String, Job>()
    private var revision = 0L
    private val writtenRevisions = mutableMapOf<String, Long>()
    private val imports = mutableMapOf<String, Job>()

    var loaded by mutableStateOf(false)
        private set

    init {
        scope.launch {
            val restored = withContext(Dispatchers.IO) {
                directory.mkdirs()
                directory.listFiles().orEmpty().filter { it.extension == "draft" }.sortedBy { it.lastModified() }.take(20).map { file ->
                    runCatching {
                        require(file.length() <= 8L * 1024 * 1024)
                        AtomicFile(file).openRead().use { input ->
                            val stream = java.io.DataInputStream(input)
                            val length = stream.readInt()
                            require(length in 1..256_000)
                            val metadata = ByteArray(length).also(stream::readFully)
                            JSONObject(String(metadata)) to CreateConversationRequest.parseFrom(stream)
                        }
                    }
                }
            }
            restored.forEach { result ->
                result.onSuccess { (json, request) ->
                    runCatching {
                        require(json.getInt("version") == 1)
                        val id = json.getString("id")
                        require(id.matches(Regex("[a-zA-Z0-9-]{1,80}")))
                        val draft = CardCreationDraft(id)
                        draft.accountId = json.optString("account")
                        draft.projectId = json.optString("project")
                        draft.boardId = json.optString("board")
                        draft.checkoutId = json.optString("checkout")
                        draft.submissionId = json.optString("submission")
                        draft.restore(request)
                        if (draft.submissionId.isNotBlank()) draft.submittedRequest = request
                        val failures = json.optJSONArray("failures") ?: JSONArray()
                        for (i in 0 until failures.length()) {
                            val item = failures.getJSONObject(i)
                            draft.importFailures += TaskImportFailure(item.optString("uri"), item.optString("message"))
                        }
                        if (json.optBoolean("importing")) draft.importFailures += TaskImportFailure("", "Import was interrupted. Choose the file again.")
                        drafts += draft
                        watch(draft)
                    }.onFailure { error = "A saved task could not be restored. Its files have been retained." }
                }.onFailure { error = "A saved task could not be restored. Its files have been retained." }
            }
            loaded = true
        }
    }

    private fun record(draft: CardCreationDraft) = File(directory, "${draft.id}.draft")

    fun create(account: String, id: String = UUID.randomUUID().toString()): CardCreationDraft {
        check(loaded) { "Draft storage is loading" }
        require(id.matches(Regex("[a-zA-Z0-9-]{1,80}")))
        drafts.firstOrNull { it.id == id }?.let { return it }
        check(drafts.size < 20) { "20 drafts retained. Discard a saved draft before capturing another task." }
        return CardCreationDraft(id).also { it.accountId = account; retain(it) }
    }

    fun retain(draft: CardCreationDraft): Boolean {
        if (draft in drafts) return true
        if (drafts.size >= 20) {
            draft.persistenceError = "20 drafts retained. Discard a saved draft before capturing another task."
            return false
        }
        drafts += draft
        watch(draft)
        return true
    }

    private fun watch(draft: CardCreationDraft) {
        watchers[draft.id] = scope.launch {
            snapshotFlow { draft.snapshot() to metadata(draft).toString() }.collect { (request, metadata) ->
                try {
                    val version = ++revision
                    withContext(Dispatchers.IO) { write(draft, request, metadata, version) }
                    draft.persistenceError = null
                } catch (failure: Exception) {
                    draft.persistenceError = "Could not save draft: ${failure.message}. Free device storage and retry."
                }
            }
        }
    }

    private fun metadata(draft: CardCreationDraft) = JSONObject().apply {
        put("version", 1); put("id", draft.id); put("account", draft.accountId)
        put("project", draft.projectId); put("board", draft.boardId); put("checkout", draft.checkoutId)
        put("submission", draft.submissionId); put("importing", draft.importing)
        put("failures", JSONArray().apply {
            draft.importFailures.forEach { put(JSONObject().put("uri", it.uri).put("message", it.message)) }
        })
    }

    @Synchronized private fun write(draft: CardCreationDraft, request: CreateConversationRequest, metadata: String, version: Long) {
        if (draft.id in discarded || version <= (writtenRevisions[draft.id] ?: 0)) return
        require(request.serializedSize <= 7 * 1024 * 1024) { "Task text is too large" }
        val journal = AtomicFile(record(draft))
        val output = journal.startWrite()
        try {
            val stream = java.io.DataOutputStream(output)
            val bytes = metadata.toByteArray()
            stream.writeInt(bytes.size); stream.write(bytes); request.writeTo(stream)
            stream.flush(); journal.finishWrite(output)
            writtenRevisions[draft.id] = version
        } catch (error: Throwable) { journal.failWrite(output); throw error }
    }

    private val discarded = mutableSetOf<String>()

    suspend fun flush(draft: CardCreationDraft) {
        check(retain(draft)) { draft.persistenceError.orEmpty() }
        val request = draft.snapshot()
        val metadata = metadata(draft).toString()
        val version = ++revision
        withContext(Dispatchers.IO) { write(draft, request, metadata, version) }
        draft.persistenceError = null
    }

    fun discard(draft: CardCreationDraft) {
        synchronized(this) { discarded += draft.id }
        imports.remove(draft.id)?.cancel()
        watchers.remove(draft.id)?.cancel()
        drafts.remove(draft)
        if (incoming === draft) incoming = null
        scope.launch(Dispatchers.IO) {
            synchronized(this@TaskCaptureStore) {
                AtomicFile(record(draft)).delete()
            }
        }
    }

    fun flushAll() {
        scope.launch { drafts.toList().forEach { draft ->
            runCatching { flush(draft) }.onFailure { draft.persistenceError = "Could not save draft: ${it.message}" }
        } }
    }

    fun close() { scope.cancel() }

    fun consumeIncoming() { incoming = null }
    fun clearError() { error = null }

    fun receive(intent: Intent, account: String) {
        if (intent.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        // Stored on the Activity's intent and in onSaveInstanceState by MainActivity.
        val id = intent.getStringExtra(CAPTURE_ID) ?: UUID.randomUUID().toString().also { intent.putExtra(CAPTURE_ID, it) }
        scope.launch {
        while (!loaded) delay(10)
        drafts.firstOrNull { it.id == id }?.let { incoming = it; return@launch }
        runCatching {
            val draft = create(account, id)
            draft.prompt = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                ?: intent.getStringExtra(Intent.EXTRA_HTML_TEXT)?.let { Html.fromHtml(it, Html.FROM_HTML_MODE_LEGACY).toString() }
                ?: intent.clipData?.let { clip -> (0 until minOf(clip.itemCount, 5)).mapNotNull { clip.getItemAt(it).text?.toString() }.joinToString("\n") }.orEmpty()
            incoming = draft
            flush(draft)
            runCatching { sharedUris(intent) }
                .onSuccess { import(draft, it) }
                .onFailure { draft.importFailures += TaskImportFailure("", "This share could not be read. Choose the files again.") }
        }.onFailure { error = it.message }
        }
    }

    fun import(draft: CardCreationDraft, uris: List<Uri>, imagesOnly: Boolean = false) {
        if (draft.importing || draft.submissionId.isNotBlank()) return
        // Admit synchronously: nested Main.immediate launches may queue until the
        // current callback returns. Save must never race an unstarted import.
        draft.importing = true
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                flush(draft)
                for (uri in uris.distinct().take(MAX_COMPOSER_ATTACHMENTS + 1)) {
                    ensureActive()
                    if (draft.attachments.size >= MAX_COMPOSER_ATTACHMENTS) {
                        draft.importFailures += TaskImportFailure(uri.toString(), "You can attach up to 4 images or files")
                        continue
                    }
                    try {
                        val part = withTimeout(30_000) { runInterruptible(Dispatchers.IO) { readAttachmentPart(context, uri, imagesOnly) } }
                        ensureActive()
                        attachmentLimitError(draft.attachments, listOf(part))?.let { error(it) }
                        draft.attachments += part
                        try { flush(draft) } catch (failure: Exception) {
                            draft.attachments.remove(part)
                            throw failure
                        }
                    } catch (timeout: TimeoutCancellationException) {
                        draft.importFailures += TaskImportFailure(uri.toString(), "Reading the file timed out. Try again.")
                    } catch (cancel: CancellationException) { throw cancel
                    } catch (failure: Exception) {
                        draft.importFailures += TaskImportFailure(uri.toString(), failure.message ?: "Could not read file. Choose it again.")
                    }
                }
            } catch (cancel: CancellationException) { throw cancel
            } catch (failure: Exception) { draft.persistenceError = "Could not save attachments: ${failure.message}"
            }
        }
        imports[draft.id] = job
        job.invokeOnCompletion {
            if (imports[draft.id] === job) {
                imports.remove(draft.id)
                draft.importing = false
            }
        }
        job.start()
    }

    fun cancelImport(draft: CardCreationDraft) { imports[draft.id]?.cancel() }

    fun retry(draft: CardCreationDraft, failure: TaskImportFailure) {
        if (draft.importing || failure.uri.isBlank()) return
        draft.importFailures.remove(failure)
        import(draft, listOf(Uri.parse(failure.uri)))
    }

    companion object { const val CAPTURE_ID = "com.dbpprt.dieter.CAPTURE_ID" }
}

internal data class TaskImportFailure(val uri: String, val message: String)

@Suppress("DEPRECATION")
internal fun sharedUris(intent: Intent): List<Uri> = buildList {
    if (intent.action == Intent.ACTION_SEND_MULTIPLE) addAll(intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty())
    else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::add)
    intent.clipData?.let { clip -> repeat(minOf(clip.itemCount, 100)) { clip.getItemAt(it).uri?.let(::add) } }
}.distinct().take(MAX_COMPOSER_ATTACHMENTS + 1)
