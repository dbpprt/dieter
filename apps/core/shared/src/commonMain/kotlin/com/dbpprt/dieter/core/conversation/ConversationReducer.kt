package com.dbpprt.dieter.core.conversation

import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationPage
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.ConversationUpdate
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.runtime.Timestamps
import com.dbpprt.dieter.core.sync.TranscriptFreshness
import com.dbpprt.dieter.core.sync.mergeCardState

/** Earlier messages loaded beyond the live window, and where they start in the full transcript. */
data class ConversationHistory(
    val start: Int = 0,
    val total: Int = 0,
    val hasMore: Boolean = false,
    val loading: Boolean = false,
    /** The user paged far enough back that the live tail is detached from the view. */
    val browsingEarlier: Boolean = false,
)

/** One open conversation: the daemon's live window plus locally loaded history. */
data class TranscriptState(
    val snapshot: ConversationSnapshot? = null,
    /** Loaded earlier messages, oldest first; never overlapping the live window. */
    val older: List<UiMessage> = emptyList(),
    val history: ConversationHistory = ConversationHistory(),
) {
    val conversation: Conversation? get() = snapshot?.conversation
    val lastSeq: Long get() = conversation?.last_seq ?: 0

    /** History then the live window; the live copy of a message wins. */
    val messages: List<UiMessage>
        get() {
            val live = conversation?.messages.orEmpty()
            val liveIds = live.mapTo(HashSet()) { it.id }
            return older.filter { it.id.isEmpty() || it.id !in liveIds } + live
        }
}

/** A bound on retained history: at most [count] messages and [bytes] encoded bytes. */
data class TranscriptRetention(val count: Int = 2_000, val bytes: Long = 32L * 1024 * 1024) {
    /**
     * The messages to keep from one end of [messages]; the first is always
     * kept, even when it alone exceeds the byte budget. Returns kept, removed.
     */
    fun window(messages: List<UiMessage>, keepingEarlier: Boolean): Pair<List<UiMessage>, Int> {
        var kept = 0
        var used = 0L
        for (offset in 0 until minOf(messages.size, maxOf(1, count))) {
            val message = messages[if (keepingEarlier) offset else messages.size - 1 - offset]
            val size = UiMessage.ADAPTER.encodedSize(message).toLong()
            if (kept > 0 && used + size > bytes) break
            used += size
            kept++
        }
        val window = if (keepingEarlier) messages.take(kept) else messages.takeLast(kept)
        return window to messages.size - kept
    }

    companion object {
        /** macOS keeps a deep scrollback. */
        val DESKTOP = TranscriptRetention(2_000, 32L * 1024 * 1024)

        /** Phones keep a smaller one. */
        val MOBILE = TranscriptRetention(240, 8L * 1024 * 1024)
    }
}

/**
 * Applies daemon frames to an open conversation. Snapshots merge by
 * freshness; deltas older than the current tail are dropped; messages that
 * slide out of the live window move into history instead of vanishing.
 * Ported from the macOS `ConversationModel`.
 */
object ConversationReducer {
    class MissingSnapshot : IllegalStateException("A conversation delta arrived before its snapshot.")

    fun apply(state: TranscriptState, update: ConversationUpdate, retention: TranscriptRetention): TranscriptState {
        update.snapshot?.let { return applySnapshot(state, it, retention) }
        val current = state.snapshot ?: throw MissingSnapshot()
        val conversation = current.conversation ?: Conversation()
        if (isOlder(conversation, update.last_seq, update.updated_at)) return state

        val removedIds = update.removed_message_ids.toSet()
        var older = state.older
        var history = state.history
        if (removedIds.isNotEmpty() && !history.browsingEarlier) {
            val known = older.mapTo(HashSet()) { it.id }
            val slid = conversation.messages.filter { it.id in removedIds && it.id !in known }
            if (slid.isNotEmpty()) {
                older = older + slid
                val trimmed = trimStreaming(older, history, retention)
                older = trimmed.first
                history = trimmed.second
            }
        }
        val messages = conversation.messages.filterNot { it.id in removedIds }.toMutableList()
        for (changed in update.changed_messages) {
            val index = messages.indexOfFirst { it.id == changed.id }
            if (index >= 0) messages[index] = changed else messages += changed
        }
        val next = conversation.copy(
            messages = messages,
            status = update.status.ifEmpty { conversation.status },
            pending_tools = update.pending_tools,
            queue = update.queue,
            last_seq = update.last_seq,
            updated_at = update.updated_at,
            subagents = update.subagents,
            task_plans = update.task_plans,
            draft_attachments = update.draft_attachments,
            presented_content = update.presented_content ?: conversation.presented_content,
            provider_status = update.provider_status,
        )
        val detail = update.detail?.let { incoming ->
            val card = incoming.card?.let { mergeCardState(it, current.detail?.card) } ?: current.detail?.card
            incoming.copy(card = card)
        } ?: current.detail
        val page = update.page ?: current.page
        val snapshot = current.copy(detail = detail, conversation = next, page = page)
        return TranscriptState(snapshot, older, withPage(history, page, older.isEmpty()))
    }

    fun applySnapshot(state: TranscriptState, incoming: ConversationSnapshot, retention: TranscriptRetention): TranscriptState {
        val merged = TranscriptFreshness.freshest(state.snapshot, incoming)
        var older = state.older
        var history = state.history
        if (!history.browsingEarlier && merged.conversation !== state.snapshot?.conversation) {
            // Keep the loaded history that still joins the new window; anything else would leave a gap.
            val presented = state.messages
            val ids = merged.conversation?.messages.orEmpty().mapTo(HashSet()) { it.id }
            val overlap = presented.indexOfFirst { it.id in ids }
            older = if (overlap >= 0) presented.take(overlap) else emptyList()
            if (older.isEmpty()) history = history.copy(start = 0, hasMore = false)
            val trimmed = trimStreaming(older, history, retention)
            older = trimmed.first
            history = trimmed.second
        }
        return TranscriptState(merged, older, withPage(history, merged.page, older.isEmpty()))
    }

    /** Page metadata describes the live window; it only positions history while none is loaded. */
    private fun withPage(history: ConversationHistory, page: ConversationPage?, noHistory: Boolean): ConversationHistory {
        page ?: return history
        val total = maxOf(history.total, page.total)
        return if (noHistory) history.copy(start = page.start, hasMore = page.has_more, total = total) else history.copy(total = total)
    }

    private fun trimStreaming(older: List<UiMessage>, history: ConversationHistory, retention: TranscriptRetention): Pair<List<UiMessage>, ConversationHistory> {
        val (kept, removed) = retention.window(older, keepingEarlier = false)
        if (removed == 0) return older to history
        return kept to history.copy(start = history.start + removed, hasMore = true)
    }

    /** A frame is older when its sequence is lower, or equal with an earlier daemon time. */
    fun isOlder(current: Conversation, seq: Long, updatedAt: String): Boolean = when {
        seq != current.last_seq -> seq < current.last_seq
        else -> Timestamps.parse(updatedAt)?.let { incoming -> Timestamps.parse(current.updated_at)?.let { incoming < it } } == true
    }
}
