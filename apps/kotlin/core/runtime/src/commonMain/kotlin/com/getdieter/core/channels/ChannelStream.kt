package com.getdieter.core.channels

import com.getdieter.api.v1.ChannelClaim
import com.getdieter.api.v1.ChannelFrame
import com.getdieter.api.v1.ChannelMessage
import com.getdieter.api.v1.ChannelSummary

/**
 * One channel's stream as WatchChannel frames build it: messages by sequence (each once, by ID),
 * the live claims, and the summary with members and read state.
 */
data class ChannelStreamState(
    /** Oldest first; at most [WINDOW]. */
    val messages: List<ChannelMessage> = emptyList(),
    val summary: ChannelSummary? = null,
    val claims: List<ChannelClaim> = emptyList(),
    val lastSeq: Long = 0,
    /** The first frame arrived. */
    val loaded: Boolean = false,
) {
    /**
     * [frame] folded in. A reset frame carries the newest page: it replaces the messages from its
     * oldest one on (older ones stay, so a reconnect keeps what was read). Later frames add new
     * messages and resend changed ones (pins, deliveries, replies) with their original sequence.
     * Claims and the summary are complete when present. A frame without claims leaves them unless
     * its summary counts none: the daemon sends an empty claim list as no list.
     */
    fun apply(frame: ChannelFrame): ChannelStreamState {
        val lastSeq = maxOf(lastSeq, frame.last_seq)
        if (frame.heartbeat && !frame.reset) return copy(lastSeq = lastSeq)
        val base =
            if (!frame.reset) messages
            else {
                val oldest = frame.messages.minOfOrNull { it.seq }
                if (oldest == null) emptyList() else messages.filter { it.seq < oldest }
            }
        val merged = merge(base, frame.messages)
        val summary = frame.summary ?: summary
        val claims =
            when {
                frame.claims.isNotEmpty() || frame.reset -> frame.claims
                frame.summary?.claims == 0 -> emptyList()
                else -> claims
            }
        return ChannelStreamState(merged, summary, claims, lastSeq, loaded = true)
    }

    /** [message] (a post's or pin's reply) folded in, as a frame would carry it. */
    fun upsert(message: ChannelMessage): ChannelStreamState =
        copy(messages = merge(messages, listOf(message)), lastSeq = maxOf(lastSeq, message.seq))

    /** The read position advanced to [seq]: nothing before it is unread. */
    fun read(seq: Long): ChannelStreamState {
        val summary = summary ?: return this
        if (summary.seen_seq >= seq) return this
        val unread = messages.count {
            it.seq > seq && it.author?.kind != "human"
        }
        return copy(summary = summary.copy(seen_seq = seq, unread = unread))
    }

    /** [released] claims are gone. */
    fun without(released: List<ChannelClaim>): ChannelStreamState {
        if (released.isEmpty()) return this
        val gone = released.mapTo(HashSet()) { it.card_id to it.path }
        return copy(claims = claims.filterNot { (it.card_id to it.path) in gone })
    }

    /** The newest message's sequence, 0 without messages. */
    val newestSeq: Long
        get() = maxOf(messages.lastOrNull()?.seq ?: 0, summary?.last_seq ?: 0)

    /** Card ID → title, from the members and the claims. */
    val titles: Map<String, String>
        get() = buildMap {
            for (claim in claims) if (claim.card_title.isNotBlank())
                put(claim.card_id, claim.card_title)
            for (member in summary?.members.orEmpty()) if (member.title.isNotBlank())
                put(member.card_id, member.title)
        }

    companion object {
        /** Messages a stream keeps. */
        const val WINDOW = 500

        private fun merge(
            base: List<ChannelMessage>,
            incoming: List<ChannelMessage>,
        ): List<ChannelMessage> {
            if (incoming.isEmpty()) return base
            val byId = LinkedHashMap<String, ChannelMessage>()
            for (message in base) byId[message.id] = message
            for (message in incoming) byId[message.id] = message
            return byId.values.sortedBy { it.seq }.takeLast(WINDOW)
        }
    }
}
