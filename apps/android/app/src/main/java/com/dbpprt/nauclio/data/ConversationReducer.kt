package com.dbpprt.nauclio.data

import com.dbpprt.nauclio.v1.ConversationSnapshot
import com.dbpprt.nauclio.v1.ConversationUpdate

/** Applies one bounded live-tail update without owning paged history. */
object ConversationReducer {
    fun apply(
        current: ConversationSnapshot?,
        update: ConversationUpdate,
    ): ConversationSnapshot {
        if (update.hasSnapshot()) return update.snapshot
        requireNotNull(current) { "Conversation stream must begin with a snapshot" }

        val removed = update.removedMessageIdsList.toSet()
        val changed = update.changedMessagesList.associateBy { it.id }
        val messages = current.conversation.messagesList
            .filterNot { it.id in removed }
            .map { changed[it.id] ?: it }
            .toMutableList()
        val existing = messages.mapTo(mutableSetOf()) { it.id }
        update.changedMessagesList.forEach { message ->
            if (existing.add(message.id)) messages += message
        }

        val conversation = current.conversation.toBuilder()
            .clearMessages()
            .addAllMessages(messages)
            .setStatus(update.status)
            .clearPendingTools()
            .addAllPendingTools(update.pendingToolsList)
            .clearSubagents()
            .addAllSubagents(update.subagentsList)
            .clearTaskPlans()
            .addAllTaskPlans(update.taskPlansList)
            .clearQueue()
            .addAllQueue(update.queueList)
            .clearDraftAttachments()
            .addAllDraftAttachments(update.draftAttachmentsList)
            .setLastSeq(update.lastSeq)
            .setUpdatedAt(update.updatedAt)
            .build()

        return current.toBuilder()
            .setConversation(conversation)
            .also { builder -> if (update.hasDetail()) builder.detail = update.detail }
            .also { builder -> if (update.hasPage()) builder.page = update.page }
            .build()
    }
}
