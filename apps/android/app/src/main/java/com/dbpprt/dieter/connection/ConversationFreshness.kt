package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.ConversationSnapshot

/**
 * Chooses the fresher of two snapshots of the same conversation. The
 * background sync stream and the foreground conversation stream both feed the
 * shared cache; the per-conversation event sequence decides which one wins so
 * a lagging stream can never roll a transcript backwards.
 */
internal fun freshestConversation(
    existing: ConversationSnapshot?,
    incoming: ConversationSnapshot,
): ConversationSnapshot {
    if (existing == null || existing.detail.card.id != incoming.detail.card.id) return incoming
    val existingSeq = existing.conversation.lastSeq
    val incomingSeq = incoming.conversation.lastSeq
    val transcript = when {
        incomingSeq > existingSeq -> incoming
        incomingSeq < existingSeq -> existing
        // Same live tail: keep the richer page so foreground paging survives
        // a concurrent background refresh.
        incoming.conversation.messagesCount >= existing.conversation.messagesCount -> incoming
        else -> existing
    }
    val detail = incoming.detail.toBuilder()
        .setCard(mergeCardState(incoming.detail.card, existing.detail.card)).build()
    // Keep the cached instance when only the observation's arrival changed.
    return if (detail == transcript.detail) transcript
        else transcript.toBuilder().setDetail(detail).build()
}
