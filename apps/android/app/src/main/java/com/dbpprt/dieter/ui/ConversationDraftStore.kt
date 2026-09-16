package com.dbpprt.dieter.ui

import android.content.Context
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.QueuedMessage
import org.json.JSONObject

data class ConversationComposerDraft(
    val text: String = "",
    val attachments: List<MessagePart> = emptyList(),
    val selection: ConversationComposerSelection? = null,
    val pendingQueueMessageIds: Set<String> = emptySet(),
) {
    val hasContent: Boolean get() = text.isNotBlank() || attachments.isNotEmpty()
}

internal data class EditableQueuedMessage(
    val text: String,
    val attachments: List<MessagePart>,
    val selection: ConversationComposerSelection?,
)

internal fun editableQueuedMessage(message: QueuedMessage): EditableQueuedMessage {
    val textParts = message.partsList.filter { it.type == "text" }.map(MessagePart::getText)
    val selection = message.selection.takeIf { message.hasSelection() }?.let {
        ConversationComposerSelection(
            provider = it.provider,
            model = it.model,
            effort = it.effort,
            providerOptions = it.providerOptionsMap,
        )
    }
    return EditableQueuedMessage(
        text = if (textParts.isEmpty()) message.text else textParts.joinToString(""),
        attachments = message.partsList.filter { it.type != "text" },
        selection = selection,
    )
}

internal interface ConversationDraftPersistence {
    fun loadTextDrafts(): Map<String, String>
    fun saveTextDrafts(drafts: Map<String, String>)
}

internal class SharedPreferencesConversationDraftPersistence(context: Context) : ConversationDraftPersistence {
    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    override fun loadTextDrafts(): Map<String, String> = runCatching {
        val encoded = preferences.getString(KEY_DRAFTS, null) ?: return@runCatching emptyMap()
        val objectValue = JSONObject(encoded)
        buildMap {
            for (cardId in objectValue.keys()) {
                val text = objectValue.optString(cardId)
                if (cardId.isNotBlank() && text.isNotEmpty()) put(cardId, text)
            }
        }
    }.getOrDefault(emptyMap())

    override fun saveTextDrafts(drafts: Map<String, String>) {
        val editor = preferences.edit()
        if (drafts.isEmpty()) {
            editor.remove(KEY_DRAFTS)
        } else {
            editor.putString(KEY_DRAFTS, JSONObject(drafts).toString())
        }
        editor.apply()
    }

    private companion object {
        const val PREFERENCES = "dieter_conversation_drafts"
        const val KEY_DRAFTS = "text_drafts_v1"
    }
}

/**
 * Bounded composer ownership. Drafts follow conversations across navigation
 * and configuration changes, while their text is also checkpointed outside
 * Android saved-instance-state bundles for process relaunch recovery.
 */
internal class ConversationDraftStore(
    private val maximumDrafts: Int = 64,
    private val persistence: ConversationDraftPersistence? = null,
) {
    private val drafts = LinkedHashMap<String, ConversationComposerDraft>(16, 0.75f, true)

    init {
        require(maximumDrafts > 0)
        persistence?.loadTextDrafts()?.forEach { (cardId, text) ->
            if (cardId.isNotBlank() && text.isNotEmpty()) {
                drafts[cardId] = ConversationComposerDraft(text = text)
            }
        }
        trimToBound()
    }

    fun draft(cardId: String?): ConversationComposerDraft =
        cardId?.takeIf(String::isNotBlank)?.let(drafts::get) ?: ConversationComposerDraft()

    fun update(
        cardId: String,
        transform: (ConversationComposerDraft) -> ConversationComposerDraft,
    ): ConversationComposerDraft {
        require(cardId.isNotBlank())
        val next = transform(drafts[cardId] ?: ConversationComposerDraft())
        if (next == ConversationComposerDraft()) drafts.remove(cardId) else drafts[cardId] = next
        trimToBound()
        persist()
        return next
    }

    fun acceptSend(
        cardId: String,
        expectedText: String,
        expectedAttachments: List<MessagePart>,
    ): ConversationComposerDraft = update(cardId) { current ->
        if (current.text.trim() == expectedText && current.attachments == expectedAttachments) {
            current.copy(text = "", attachments = emptyList())
        } else {
            current
        }
    }

    fun beginQueueMutation(cardId: String, messageId: String): ConversationComposerDraft? {
        val current = draft(cardId)
        if (messageId.isBlank() || messageId in current.pendingQueueMessageIds) return null
        return update(cardId) { it.copy(pendingQueueMessageIds = it.pendingQueueMessageIds + messageId) }
    }

    fun finishQueueMutation(
        cardId: String,
        messageId: String,
        removed: QueuedMessage?,
        edit: Boolean,
    ): ConversationComposerDraft = update(cardId) { current ->
        var next = current.copy(pendingQueueMessageIds = current.pendingQueueMessageIds - messageId)
        if (edit && removed != null) {
            val restored = editableQueuedMessage(removed)
            next = next.copy(
                text = listOf(restored.text, next.text).filter(String::isNotBlank).joinToString("\n\n"),
                attachments = restored.attachments + next.attachments,
                selection = restored.selection ?: next.selection,
            )
        }
        next
    }

    fun retarget(oldCardId: String?, newCardId: String?) {
        if (oldCardId.isNullOrBlank() || newCardId.isNullOrBlank() || oldCardId == newCardId) return
        val old = drafts.remove(oldCardId) ?: return
        val existing = drafts[newCardId]
        drafts[newCardId] = if (existing == null) old else existing.copy(
            text = listOf(old.text, existing.text).filter(String::isNotBlank).joinToString("\n\n"),
            attachments = old.attachments + existing.attachments,
            selection = existing.selection ?: old.selection,
            pendingQueueMessageIds = old.pendingQueueMessageIds + existing.pendingQueueMessageIds,
        )
        trimToBound()
        persist()
    }

    private fun trimToBound() {
        while (drafts.size > maximumDrafts) {
            val removable = drafts.entries.firstOrNull { it.value.pendingQueueMessageIds.isEmpty() }
                ?: drafts.entries.first()
            drafts.remove(removable.key)
        }
    }

    private fun persist() {
        persistence?.saveTextDrafts(
            drafts.mapNotNull { (cardId, draft) ->
                draft.text.takeIf(String::isNotEmpty)?.let { cardId to it }
            }.toMap(),
        )
    }
}
