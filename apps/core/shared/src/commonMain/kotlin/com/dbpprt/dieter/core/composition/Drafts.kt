package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.state.DraftText
import com.dbpprt.dieter.core.state.DraftTexts
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.time.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch

/** A conversation is identified by the machine that runs it and its ID. */
data class DraftKey(val daemonId: String, val conversationId: String)

data class ConversationDraft(
    val text: String = "",
    val attachments: List<MessagePart> = emptyList(),
    /** Composer agent choice; null follows the conversation. */
    val selection: HarnessSelection? = null,
    /** Queued messages being pulled back into this draft. */
    val pendingQueueIds: Set<String> = emptySet(),
    /** Advances with every text or attachment change, so a send clears only what it sent. */
    val revision: Long = 0,
) {
    val hasContent: Boolean get() = text.isNotBlank() || attachments.isNotEmpty()
    val isEmpty: Boolean get() = text.isEmpty() && attachments.isEmpty() && selection == null && pendingQueueIds.isEmpty()
}

/** A queued message returned to the composer: its text, attachments, and agent choice. */
data class RestoredMessage(val text: String, val attachments: List<MessagePart>, val selection: HarnessSelection?) {
    companion object {
        fun from(message: QueuedMessage): RestoredMessage {
            val texts = message.parts.filter { it.type == "text" }.map { it.text }
            val text = (if (texts.isEmpty()) message.text else texts.joinToString("\n\n")).trim()
            return RestoredMessage(text, message.parts.filter { it.type != "text" }, message.selection?.takeIf { it.provider.isNotEmpty() })
        }
    }
}

/** [next] as a change of [current]: a text or attachment change advances the revision past both. */
private fun revised(current: ConversationDraft, next: ConversationDraft): ConversationDraft =
    if (next.text != current.text || next.attachments != current.attachments) next.copy(revision = maxOf(current.revision, next.revision) + 1) else next

/**
 * The draft of one open conversation. Typing applies to [state] at once, so
 * a text field never lags or rewinds to a stale echo; the core folds each
 * change into its drafts in the background. The core's own changes (a send,
 * a restored queued message) apply to the same state atomically. Safe to
 * call from any thread.
 */
class ConversationDraftEditor internal constructor(val key: DraftKey, initial: ConversationDraft) {
    private val mutableState = MutableStateFlow(initial)
    val state: StateFlow<ConversationDraft> = mutableState.asStateFlow()

    fun setText(text: String): ConversationDraft = edit { it.copy(text = text) }

    internal fun edit(change: (ConversationDraft) -> ConversationDraft): ConversationDraft =
        mutableState.updateAndGet { current -> revised(current, change(current)) }
}

/**
 * Composer drafts per conversation, bounded to the 64 most recently used.
 * Only text survives a restart; a burst of typing is written once. Confined
 * to the core dispatcher, except for the [editor]s it hands out.
 */
class ConversationDrafts(
    private val clock: Clock,
    private val logger: CoreLogger,
    /** The core dispatcher's scope; editors fold their edits and text is journaled on it. Without one, text is written at once. */
    private val scope: CoroutineScope? = null,
) {
    private var storage: CoreStorage? = null
    private val drafts = LinkedHashMap<DraftKey, ConversationDraft>()
    private val updatedAt = HashMap<DraftKey, Long>()
    private val editors = HashMap<DraftKey, OpenEditor>()
    private var unsaved = false
    private var saving: Job? = null
    private val mutableState = MutableStateFlow<Map<DraftKey, ConversationDraft>>(emptyMap())
    val state: StateFlow<Map<DraftKey, ConversationDraft>> = mutableState.asStateFlow()

    private class OpenEditor(val editor: ConversationDraftEditor, val job: Job) {
        var holders = 1
    }

    fun bind(storage: CoreStorage?) {
        if (storage != null && storage.directory == this.storage?.directory) return
        flush()
        this.storage = storage
        drafts.clear()
        updatedAt.clear()
        editors.values.forEach { it.job.cancel() }
        editors.clear()
        val saved = storage?.read(FILE)?.let { runCatching { DraftTexts.ADAPTER.decode(it) }.getOrNull() }
        for (draft in saved?.drafts.orEmpty().sortedBy { it.updated_at_millis }) {
            if (draft.conversation_id.isBlank() || draft.text.isEmpty()) continue
            val key = DraftKey(draft.daemon_id, draft.conversation_id)
            drafts[key] = ConversationDraft(text = draft.text)
            updatedAt[key] = draft.updated_at_millis
        }
        trim()
        publish()
    }

    /** The draft for [key], as its open editor holds it; reading it counts as use for eviction. */
    fun draft(key: DraftKey): ConversationDraft {
        val folded = drafts.remove(key)?.also { drafts[key] = it }
        return editors[key]?.editor?.state?.value ?: folded ?: ConversationDraft()
    }

    /** Applies [change], through [key]'s open editor if it has one; an empty result removes the draft. */
    fun update(key: DraftKey, change: (ConversationDraft) -> ConversationDraft): ConversationDraft {
        require(key.conversationId.isNotBlank()) { "A draft needs a conversation." }
        editors[key]?.editor?.let { editor ->
            val next = editor.edit(change)
            fold(key, editor.state.value)
            return next
        }
        val current = draft(key)
        val next = revised(current, change(current))
        store(key, next, textChanged = next.text != current.text)
        return next
    }

    fun setText(key: DraftKey, text: String) = update(key) { it.copy(text = text) }

    /**
     * The live editor of [key]'s draft for a composer, shared until every
     * holder has called [release]. Its edits fold into these drafts here.
     */
    fun editor(key: DraftKey): ConversationDraftEditor {
        editors[key]?.let { open ->
            open.holders++
            return open.editor
        }
        require(key.conversationId.isNotBlank()) { "A draft needs a conversation." }
        val scope = requireNotNull(scope) { "Editors need the core scope." }
        val editor = ConversationDraftEditor(key, draft(key))
        // No drop(1): typing that lands before the collector starts must still fold.
        editors[key] = OpenEditor(editor, scope.launch { editor.state.collect { fold(key, it) } })
        return editor
    }

    /** Lets go of [editor]; after its last holder, its latest draft stays here. */
    fun release(editor: ConversationDraftEditor) {
        val open = editors[editor.key]?.takeIf { it.editor === editor } ?: return
        if (--open.holders > 0) return
        editors.remove(editor.key)
        open.job.cancel()
        fold(editor.key, editor.state.value)
    }

    /** Writes text changed since the last save now, including typing not yet folded, e.g. before the app may be stopped. */
    fun flush() {
        for ((key, open) in editors.entries.toList()) fold(key, open.editor.state.value)
        if (!unsaved) return
        unsaved = false
        persist()
    }

    /** Adds attachments within the daemon's limits, or fails without changing the draft. */
    fun addAttachments(key: DraftKey, parts: List<MessagePart>): Result<ConversationDraft> =
        Attachments.appending(draft(key).attachments, parts).map { combined -> update(key) { it.copy(attachments = combined) } }

    fun removeAttachment(key: DraftKey, index: Int) = update(key) { draft -> draft.copy(attachments = draft.attachments.filterIndexed { i, _ -> i != index }) }

    fun setSelection(key: DraftKey, selection: HarnessSelection?) = update(key) { it.copy(selection = selection) }

    /** Clears what was sent from revision [sentRevision]; anything typed meanwhile stays. */
    fun acceptSend(key: DraftKey, sentRevision: Long): Boolean {
        var accepted = false
        update(key) { current ->
            accepted = current.hasContent && current.revision == sentRevision
            if (accepted) current.copy(text = "", attachments = emptyList()) else current
        }
        return accepted
    }

    /** Marks a queued message as being edited; false if that edit is already running. */
    fun beginQueueEdit(key: DraftKey, messageId: String): Boolean {
        if (messageId in draft(key).pendingQueueIds) return false
        update(key) { it.copy(pendingQueueIds = it.pendingQueueIds + messageId) }
        return true
    }

    /** Ends a queue edit; a removed message is merged in front of what the composer holds. */
    fun finishQueueEdit(key: DraftKey, messageId: String, removed: QueuedMessage?): ConversationDraft = update(key) { draft ->
        val done = draft.copy(pendingQueueIds = draft.pendingQueueIds - messageId)
        if (removed == null) return@update done
        val restored = RestoredMessage.from(removed)
        done.copy(
            text = listOf(restored.text, draft.text).filter { it.isNotBlank() }.joinToString("\n\n"),
            attachments = restored.attachments + draft.attachments,
            selection = restored.selection ?: draft.selection,
        )
    }

    /** Retargets [from] on every machine; local IDs are unique across machines. */
    fun retargetAll(from: String, to: String) {
        for (key in (drafts.keys + editors.keys).filter { it.conversationId == from }) retarget(key.daemonId, from, to)
    }

    /**
     * Moves a local conversation's draft to its server ID, merging with any
     * draft already there. An editor of the local ID stops following it.
     */
    fun retarget(daemonId: String, from: String, to: String) {
        if (from.isBlank() || to.isBlank() || from == to) return
        val source = DraftKey(daemonId, from)
        val detached = editors.remove(source)?.also { it.job.cancel() }?.editor?.state?.value
        val old = detached ?: drafts[source] ?: return
        drafts.remove(source)
        updatedAt.remove(source)
        update(DraftKey(daemonId, to)) { existing ->
            if (existing.isEmpty) old else ConversationDraft(
                text = listOf(old.text, existing.text).filter { it.isNotBlank() }.joinToString("\n\n"),
                attachments = old.attachments + existing.attachments,
                selection = existing.selection ?: old.selection,
                pendingQueueIds = old.pendingQueueIds + existing.pendingQueueIds,
                revision = maxOf(old.revision, existing.revision),
            )
        }
    }

    /** Takes an editor's latest draft into these drafts. */
    private fun fold(key: DraftKey, draft: ConversationDraft) = store(key, draft, textChanged = draft.text != drafts[key]?.text.orEmpty())

    private fun store(key: DraftKey, draft: ConversationDraft, textChanged: Boolean) {
        drafts.remove(key)
        if (draft.isEmpty) {
            updatedAt.remove(key)
        } else {
            drafts[key] = draft
            if (textChanged) updatedAt[key] = clock.now().toEpochMilliseconds()
        }
        trim()
        if (textChanged) persistSoon()
        publish()
    }

    /** Journals text at most every [SAVE_INTERVAL], so a burst of keystrokes is written once. */
    private fun persistSoon() {
        unsaved = true
        val scope = scope ?: return flush()
        if (saving?.isActive == true) return
        saving = scope.launch {
            delay(SAVE_INTERVAL)
            flush()
        }
    }

    /** Evicts the least recently used drafts, sparing ones with a queue edit in flight while possible. */
    private fun trim() {
        while (drafts.size > MAX_DRAFTS) {
            val victim = drafts.entries.firstOrNull { it.value.pendingQueueIds.isEmpty() }?.key ?: drafts.keys.first()
            drafts.remove(victim)
            updatedAt.remove(victim)
        }
    }

    private fun persist() {
        val target = storage ?: return
        val texts = drafts.entries.filter { it.value.text.isNotEmpty() }.map { (key, draft) ->
            DraftText(daemon_id = key.daemonId, conversation_id = key.conversationId, text = draft.text, updated_at_millis = updatedAt[key] ?: 0)
        }.sortedByDescending { it.updated_at_millis }.take(MAX_DRAFTS)
        runCatching { target.write(FILE, DraftTexts.ADAPTER.encode(DraftTexts(texts))) }
            .onFailure { logger.warn(TAG, "could not save composer drafts", it) }
    }

    private fun publish() {
        mutableState.value = drafts.toMap()
    }

    companion object {
        const val MAX_DRAFTS = 64
        val SAVE_INTERVAL = 500.milliseconds
        private const val FILE = "drafts.pb"

        private const val TAG = "Drafts"
    }
}
