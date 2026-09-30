package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.state.DraftText
import com.dbpprt.dieter.core.state.DraftTexts
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.time.Clock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

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

/**
 * Composer drafts per conversation, bounded to the 64 most recently used.
 * Only text survives a restart. Confined to the core dispatcher.
 */
class ConversationDrafts(private val clock: Clock, private val logger: CoreLogger) {
    private var storage: CoreStorage? = null
    private val drafts = LinkedHashMap<DraftKey, ConversationDraft>()
    private val updatedAt = HashMap<DraftKey, Long>()
    private val mutableState = MutableStateFlow<Map<DraftKey, ConversationDraft>>(emptyMap())
    val state: StateFlow<Map<DraftKey, ConversationDraft>> = mutableState.asStateFlow()

    fun bind(storage: CoreStorage?) {
        if (storage != null && storage.directory == this.storage?.directory) return
        this.storage = storage
        drafts.clear()
        updatedAt.clear()
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

    /** The draft for [key]; reading it counts as use for eviction. */
    fun draft(key: DraftKey): ConversationDraft {
        val draft = drafts.remove(key) ?: return ConversationDraft()
        drafts[key] = draft
        return draft
    }

    /** Applies [change]; an empty result removes the draft. */
    fun update(key: DraftKey, change: (ConversationDraft) -> ConversationDraft): ConversationDraft {
        require(key.conversationId.isNotBlank()) { "A draft needs a conversation." }
        val current = draft(key)
        var next = change(current)
        if (next.text != current.text || next.attachments != current.attachments) next = next.copy(revision = current.revision + 1)
        store(key, next, textChanged = next.text != current.text)
        return next
    }

    fun setText(key: DraftKey, text: String) = update(key) { it.copy(text = text) }

    /** Adds attachments within the daemon's limits, or fails without changing the draft. */
    fun addAttachments(key: DraftKey, parts: List<MessagePart>): Result<ConversationDraft> =
        Attachments.appending(draft(key).attachments, parts).map { combined -> update(key) { it.copy(attachments = combined) } }

    fun removeAttachment(key: DraftKey, index: Int) = update(key) { draft -> draft.copy(attachments = draft.attachments.filterIndexed { i, _ -> i != index }) }

    fun setSelection(key: DraftKey, selection: HarnessSelection?) = update(key) { it.copy(selection = selection) }

    /** Clears what was sent from revision [sentRevision]; anything typed meanwhile stays. */
    fun acceptSend(key: DraftKey, sentRevision: Long): Boolean {
        val current = drafts[key] ?: return false
        if (current.revision != sentRevision) return false
        update(key) { it.copy(text = "", attachments = emptyList()) }
        return true
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
        for (key in drafts.keys.filter { it.conversationId == from }) retarget(key.daemonId, from, to)
    }

    /** Moves a local conversation's draft to its server ID, merging with any draft already there. */
    fun retarget(daemonId: String, from: String, to: String) {
        if (from.isBlank() || to.isBlank() || from == to) return
        val old = drafts[DraftKey(daemonId, from)] ?: return
        val key = DraftKey(daemonId, to)
        val existing = drafts[key]
        drafts.remove(DraftKey(daemonId, from))
        updatedAt.remove(DraftKey(daemonId, from))
        val merged = if (existing == null) old else ConversationDraft(
            text = listOf(old.text, existing.text).filter { it.isNotBlank() }.joinToString("\n\n"),
            attachments = old.attachments + existing.attachments,
            selection = existing.selection ?: old.selection,
            pendingQueueIds = old.pendingQueueIds + existing.pendingQueueIds,
            revision = maxOf(old.revision, existing.revision) + 1,
        )
        store(key, merged, textChanged = true)
    }

    private fun store(key: DraftKey, draft: ConversationDraft, textChanged: Boolean) {
        drafts.remove(key)
        if (draft.isEmpty) {
            updatedAt.remove(key)
        } else {
            drafts[key] = draft
            if (textChanged) updatedAt[key] = clock.now().toEpochMilliseconds()
        }
        trim()
        if (textChanged) persist()
        publish()
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
        private const val FILE = "drafts.pb"

        /** Merges legacy composer texts into [storage]; the newest text per conversation wins. */
        fun importInto(storage: CoreStorage, drafts: List<DraftText>): Int {
            val existing = storage.read(FILE)?.let { runCatching { DraftTexts.ADAPTER.decode(it) }.getOrNull() }?.drafts.orEmpty()
            val merged = (existing + drafts.filter { it.daemon_id.isNotEmpty() && it.conversation_id.isNotEmpty() && it.text.isNotBlank() })
                .groupBy { it.daemon_id to it.conversation_id }.values.map { group -> group.maxBy { it.updated_at_millis } }
                .sortedByDescending { it.updated_at_millis }.take(MAX_DRAFTS)
            if (merged == existing) return 0
            storage.write(FILE, DraftTexts.ADAPTER.encode(DraftTexts(merged)))
            return merged.size - existing.size
        }
        private const val TAG = "Drafts"
    }
}
