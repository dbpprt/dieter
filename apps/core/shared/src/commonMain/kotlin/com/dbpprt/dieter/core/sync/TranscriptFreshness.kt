package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.CardDetail
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.core.runtime.Timestamps

/**
 * Chooses the fresher of two observations of one conversation. Daemon
 * revisions decide, never client receive times: independent streams can
 * deliver an older projection after a newer read.
 */
object TranscriptFreshness {
    fun freshest(existing: ConversationSnapshot?, incoming: ConversationSnapshot): ConversationSnapshot {
        val id = incoming.detail?.card?.id
        if (existing == null || existing.detail?.card?.id != id) return incoming
        val current = existing.conversation
        val next = incoming.conversation
        val incomingWins = when {
            next == null -> false
            current == null -> true
            next.last_seq != current.last_seq -> next.last_seq > current.last_seq
            // Same live tail: keep the richer page so paging survives a background refresh.
            next.messages.size != current.messages.size -> next.messages.size > current.messages.size
            else -> Timestamps.compare(next.updated_at, current.updated_at) >= 0
        }
        val transcript = if (incomingWins) incoming else existing
        val incomingCard = incoming.detail?.card
        val card = if (incomingCard != null) mergeCardState(incomingCard, existing.detail?.card) else existing.detail?.card
        val detail = (incoming.detail ?: CardDetail()).copy(card = card)
        return if (detail == transcript.detail) transcript else transcript.copy(detail = detail)
    }
}
