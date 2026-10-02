package com.dbpprt.dieter.core.testing

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.ConversationDelta
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.TimelineItem
import com.dbpprt.dieter.client.v1.WorkspaceDelta
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.client.Keyed

/** Applies keyed deltas to a slice snapshot, as a UI observing the contract does. */
object SliceFolds {
    fun apply(base: WorkspaceSlice, delta: WorkspaceDelta): WorkspaceSlice = base.copy(
        projects = delta.projects, boards = delta.boards,
        cards = Keyed.apply(base.cards, delta.upserted_cards, delta.removed_card_ids, delta.card_order.takeIf { delta.order_changed }, Card::id),
        pending_card_ids = delta.pending_card_ids, loaded = delta.loaded, project_replicas = delta.project_replicas,
        retired_boards = delta.retired_boards, settings = delta.settings, board_attention = delta.board_attention,
    )

    fun apply(base: ConversationSlice, delta: ConversationDelta): ConversationSlice = base.copy(
        card = delta.card, conversation = delta.conversation,
        messages = Keyed.apply(base.messages, delta.upserted_messages, delta.removed_message_ids, delta.message_order.takeIf { delta.order_changed }, UiMessage::id),
        loading = delta.loading, syncing = delta.syncing, error = delta.error, pending = delta.pending,
        has_earlier = delta.has_earlier, loading_earlier = delta.loading_earlier, browsing_earlier = delta.browsing_earlier,
        retrying = delta.retrying, refreshed_at_millis = delta.refreshed_at_millis,
        turn_failure = delta.turn_failure, project = delta.project, board = delta.board, page = delta.page,
        card_id = delta.card_id.ifEmpty { base.card_id }, daemon_id = delta.daemon_id, earlier_count = delta.earlier_count,
        state = delta.state,
        timeline = Keyed.apply(base.timeline, delta.upserted_timeline, delta.removed_timeline_ids, delta.timeline_order.takeIf { delta.timeline_order_changed }, TimelineItem::id),
        unattached_plan_ids = delta.unattached_plan_ids,
    )
}
