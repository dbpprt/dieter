package com.getdieter.mobile.store

import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.client.Keyed
import kotlinx.coroutines.flow.MutableStateFlow

/** The account's projects, boards and cards, its pending operations, and the tab lists. */
class WorkspaceModel
internal constructor(
    private val context: StoreContext,
    /** Runs after each workspace update, e.g. to deliver a share waiting for the workspace. */
    private val changed: () -> Unit,
    /** Receives each outbox, e.g. so an open new task follows its server ID. */
    private val resolved: (OutboxSlice) -> Unit,
) {
    val slice = MutableStateFlow(WorkspaceSlice())
    val outbox = MutableStateFlow(OutboxSlice())
    val activity = MutableStateFlow(ActivitySlice())
    val navigation = MutableStateFlow(NavigationSlice())
    val chats = MutableStateFlow(ChatsSlice())

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_WORKSPACE, "") { update ->
            update.workspace?.let { slice.value = it }
            update.workspace_delta?.let { slice.value = fold(slice.value, it) }
            changed()
        }
        context.observeAlways(Slice.SLICE_OUTBOX, "") { update ->
            update.outbox?.let { next ->
                outbox.value = next
                resolved(next)
                next.storage_error.takeIf { it.isNotEmpty() }?.let { context.error.value = it }
                next.failures.values.firstOrNull()?.let { context.error.value = it }
            }
        }
        context.observeAlways(Slice.SLICE_ACTIVITY, "") {
            it.activity?.let { value -> activity.value = value }
        }
        context.observeAlways(Slice.SLICE_NAVIGATION, "") {
            it.navigation?.let { value -> navigation.value = value }
        }
        context.observeAlways(Slice.SLICE_CHATS, MobileStore.CHATS_SCOPE) {
            it.chats?.let { value -> chats.value = value }
        }
    }
}

// Snapshot folding is UI protocol plumbing. No ordering or business policy lives here.
private fun fold(base: WorkspaceSlice, delta: WorkspaceDelta) =
    base.copy(
        projects = delta.projects,
        boards = delta.boards,
        cards =
            Keyed.apply(
                base.cards,
                delta.upserted_cards,
                delta.removed_card_ids,
                delta.card_order.takeIf { delta.order_changed },
                Card::id,
            ),
        pending_card_ids = delta.pending_card_ids,
        loaded = delta.loaded,
        retired_boards = delta.retired_boards,
        board_attention = delta.board_attention,
        project_hosts = delta.project_hosts,
    )
