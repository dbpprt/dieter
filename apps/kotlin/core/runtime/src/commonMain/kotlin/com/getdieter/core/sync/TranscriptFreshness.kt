package com.getdieter.core.sync

import com.getdieter.api.v1.CardDetail
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.ConversationSnapshot
import com.getdieter.core.runtime.Timestamps

/**
 * Chooses the fresher of two observations of one conversation. Daemon revisions decide, never
 * client receive times: independent streams can deliver an older projection after a newer read.
 */
object TranscriptFreshness {
    /** Owner revisions, shared by full transcripts and the account's bounded activity previews. */
    fun compare(left: Conversation, right: Conversation): Int =
        left.last_seq.compareTo(right.last_seq).takeIf { it != 0 }
            ?: Timestamps.compare(left.updated_at, right.updated_at)

    fun freshest(
        existing: ConversationSnapshot?,
        incoming: ConversationSnapshot,
    ): ConversationSnapshot {
        val id = incoming.detail?.card?.id
        if (existing == null || existing.detail?.card?.id != id) return incoming
        val current = existing.conversation
        val next = incoming.conversation
        val incomingWins =
            when {
                next == null -> false
                current == null -> true
                compare(next, current) != 0 -> compare(next, current) > 0
                // Only identical revisions may prefer a richer page. A newer, smaller window
                // must still replace changed messages and metadata at the same sequence.
                next.messages.size != current.messages.size ->
                    next.messages.size > current.messages.size
                else -> true
            }
        val transcript = if (incomingWins) incoming else existing
        val incomingCard = incoming.detail?.card
        val card =
            if (incomingCard != null) mergeCardState(incomingCard, existing.detail?.card)
            else existing.detail?.card
        val detail = (incoming.detail ?: CardDetail()).copy(card = card)
        return if (detail == transcript.detail) transcript else transcript.copy(detail = detail)
    }
}
