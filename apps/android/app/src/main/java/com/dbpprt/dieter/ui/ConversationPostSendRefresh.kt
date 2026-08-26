package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.ConversationSnapshot

private val activeConversationStatuses = setOf("pending", "starting", "queued", "running", "active", "stopping")

/**
 * Keeps the foreground transcript polling after a send until the durable
 * message receipt and the agent turn have both settled.
 */
internal fun conversationNeedsPostSendRefresh(
    snapshot: ConversationSnapshot?,
    pendingMessageIds: Set<String>,
): Boolean {
    val conversation = snapshot?.conversation ?: return true
    val visibleMessageIds = buildSet {
        conversation.messagesList.mapTo(this) { it.id }
        conversation.queueList.mapTo(this) { it.id }
    }
    return pendingMessageIds.any(visibleMessageIds::contains) ||
        conversation.status.trim().lowercase() in activeConversationStatuses
}
