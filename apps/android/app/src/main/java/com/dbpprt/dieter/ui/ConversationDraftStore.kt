package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.QueuedMessage

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

/**
 * Bounded, process-lifetime composer ownership. Drafts follow conversations
 * across navigation and configuration changes without putting attachment
 * bytes into Android saved-instance-state bundles.
 */
internal class ConversationDraftStore(private val maximumDrafts: Int = 64) {
    private val drafts = LinkedHashMap<String, ConversationComposerDraft>(16, 0.75f, true)

    init {
        require(maximumDrafts > 0)
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
    }

    private fun trimToBound() {
        while (drafts.size > maximumDrafts) {
            val removable = drafts.entries.firstOrNull { it.value.pendingQueueMessageIds.isEmpty() }
                ?: drafts.entries.first()
            drafts.remove(removable.key)
        }
    }
}
