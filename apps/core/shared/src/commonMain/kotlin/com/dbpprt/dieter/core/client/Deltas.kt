package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.ConversationDelta
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.TimelineItem
import com.dbpprt.dieter.client.v1.WorkspaceDelta
import com.dbpprt.dieter.client.v1.WorkspaceSlice

/** Keyed changes between two snapshots of a keyed slice; null when nothing changed. */
internal object Deltas {
    fun workspace(previous: WorkspaceSlice, next: WorkspaceSlice): WorkspaceDelta? {
        if (previous == next) return null
        val cards = Keyed.diff(previous.cards, next.cards, Card::id)
        return WorkspaceDelta(
            projects = next.projects, boards = next.boards, upserted_cards = cards.upserted, removed_card_ids = cards.removed,
            card_order = if (cards.orderChanged) next.cards.map(Card::id) else emptyList(), order_changed = cards.orderChanged,
            pending_card_ids = next.pending_card_ids, loaded = next.loaded,
            retired_boards = next.retired_boards, board_attention = next.board_attention, project_hosts = next.project_hosts,
        )
    }

    fun conversation(previous: ConversationSlice, next: ConversationSlice): ConversationDelta? {
        if (previous == next) return null
        val messages = Keyed.diff(previous.messages, next.messages, UiMessage::id)
        val timeline = Keyed.diff(previous.timeline, next.timeline, TimelineItem::id)
        return ConversationDelta(
            card = next.card, conversation = next.conversation, upserted_messages = messages.upserted, removed_message_ids = messages.removed,
            message_order = if (messages.orderChanged) next.messages.map(UiMessage::id) else emptyList(), order_changed = messages.orderChanged,
            loading = next.loading, syncing = next.syncing, error = next.error, pending = next.pending,
            has_earlier = next.has_earlier, loading_earlier = next.loading_earlier, browsing_earlier = next.browsing_earlier,
            retrying = next.retrying, refreshed_at_millis = next.refreshed_at_millis,
            turn_failure = next.turn_failure, project = next.project, board = next.board, page = next.page,
            card_id = next.card_id, daemon_id = next.daemon_id, earlier_count = next.earlier_count, state = next.state,
            upserted_timeline = timeline.upserted, removed_timeline_ids = timeline.removed,
            timeline_order = if (timeline.orderChanged) next.timeline.map(TimelineItem::id) else emptyList(), timeline_order_changed = timeline.orderChanged,
            unattached_plan_ids = next.unattached_plan_ids,
        )
    }
}

/** Keyed list diffs: upserts, removals, and whether the surviving order changed. */
object Keyed {
    data class Diff<T>(val upserted: List<T>, val removed: List<String>, val orderChanged: Boolean)

    fun <T> diff(previous: List<T>, next: List<T>, key: (T) -> String): Diff<T> {
        val before = previous.associateBy(key)
        val nextKeys = next.map(key)
        val upserted = next.filter { before[key(it)] != it }
        val nextSet = nextKeys.toHashSet()
        val removed = previous.map(key).filter { it !in nextSet }
        // Appending new items at the end keeps the order; anything else resends it.
        val survivors = previous.map(key).filter { it in nextSet }
        val orderChanged = nextKeys.take(survivors.size) != survivors || nextKeys.size != nextKeys.toHashSet().size
        return Diff(upserted, removed, orderChanged)
    }

    fun <T> apply(base: List<T>, upserted: List<T>, removed: List<String>, order: List<String>?, key: (T) -> String): List<T> {
        val removedSet = removed.toHashSet()
        val items = LinkedHashMap<String, T>()
        base.forEach { if (key(it) !in removedSet) items[key(it)] = it }
        upserted.forEach { items[key(it)] = it }
        return order?.mapNotNull { items[it] } ?: items.values.toList()
    }
}
