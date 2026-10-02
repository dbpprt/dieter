package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.client.v1.ActivitySlice
import com.dbpprt.dieter.client.v1.BoardDrop
import com.dbpprt.dieter.client.v1.BoardStateFilter
import com.dbpprt.dieter.client.v1.BoardViewCommand
import com.dbpprt.dieter.client.v1.BoardViewSlice
import com.dbpprt.dieter.client.v1.BoardViewTarget
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.CreateConversation
import com.dbpprt.dieter.client.v1.CreationIntent
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.MoveCard
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.SliceFolds
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/** The board view surface, board attention, and the activity slice's rules through the byte contract. */
class ClientApiBoardViewEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun aBoardViewOrdersFlagsAndDropsCards() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)
        val board = MutableStateFlow<BoardViewSlice?>(null)
        val workspace = MutableStateFlow<WorkspaceSlice?>(null)
        val activity = MutableStateFlow<ActivitySlice?>(null)
        val subscriptions = listOf(
            api.observe(Slice.SLICE_BOARD_VIEW, "board-test") { board.value = Update.ADAPTER.decode(it.encode()).board_view },
            api.observe(Slice.SLICE_WORKSPACE, "") { update ->
                val decoded = Update.ADAPTER.decode(update.encode())
                decoded.workspace?.let { workspace.value = it }
                decoded.workspace_delta?.let { delta -> workspace.value = SliceFolds.apply(checkNotNull(workspace.value), delta) }
            },
            api.observe(Slice.SLICE_ACTIVITY, "") { activity.value = Update.ADAPTER.decode(it.encode()).activity },
        )
        fun view(action: BoardViewCommand) = Command(board_view = action.copy(scope = "board-test"))
        board.await(describe = { "unbound board view" }) { it != null }
        api.dispatch(view(BoardViewCommand(bind = BoardViewTarget(board_id = fixture.boardId))))

        for (title in listOf("First", "Second", "Third")) {
            api.dispatch(
                Command(
                    create_conversation = CreateConversation(
                        intent = CreationIntent(
                            project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = title, prompt = "Do $title",
                            selection = HarnessSelection("mock", "mock", "low"), workspace_mode = "project",
                        ),
                    ),
                ),
            )
        }
        fun todo(slice: BoardViewSlice?) = slice?.lanes?.firstOrNull { it.lane_id == "todo" }?.card_ids.orEmpty()
        val shown = board.await(30.seconds, describe = { "three synced cards: ${board.value}" }) { slice ->
            todo(slice).size == 3 && todo(slice).all { OutboxPolicy.isServerBacked(it) && slice?.cards?.get(it)?.pending == false }
        }!!
        val (first, middle, last) = todo(shown)
        assertEquals("board · 3 conversations", shown.summary)
        assertEquals("All states", shown.state_title)
        assertTrue(shown.lanes.any { it.lane_id == "running" })
        with(shown.cards.getValue(first)) { assertTrue(can_start && can_edit_draft && !can_cancel && !starting, "$this") }

        // A drop lands where the view shows it at once, measured against the shown lane.
        assertEquals(Done(), api.dispatch(view(BoardViewCommand(drop = BoardDrop(card_id = last, lane_id = "todo", before_card_id = first)))).done)
        board.await(30.seconds, describe = { "reordered: ${todo(board.value)}" }) { todo(it) == listOf(last, first, middle) }
        // Dropping a card where it already is changes nothing.
        assertEquals(Done(), api.dispatch(view(BoardViewCommand(drop = BoardDrop(card_id = last, lane_id = "todo", before_card_id = first)))).done)
        assertFailsWith<ClientFailure> { api.dispatch(view(BoardViewCommand(drop = BoardDrop(card_id = last, lane_id = "no-such-lane")))) }

        // A card waiting in review: board attention, the review filter, and the Inbox's Finish.
        api.dispatch(Command(move_card = MoveCard(card_id = middle, lane = "review")))
        workspace.await(30.seconds, describe = { "attention: ${workspace.value?.board_attention}" }) { it?.board_attention?.get(fixture.boardId) == 1 }
        api.dispatch(view(BoardViewCommand(bind = BoardViewTarget(board_id = fixture.boardId, state = BoardStateFilter.BOARD_STATE_FILTER_REVIEW))))
        val review = board.await(describe = { "review filter: ${board.value}" }) { it?.state_title == "Review" }!!
        assertEquals(listOf(middle), review.lanes.flatMap { it.card_ids })
        val inbox = activity.await(30.seconds, describe = { "review row: ${activity.value}" }) { slice -> slice?.rows?.any { it.card?.id == middle } == true }!!
        val row = inbox.rows.single { it.card?.id == middle }
        assertTrue(row.can_finish && !row.needs_you && row.kind_label == "Review" && row.menu_bar_title == "Ready for review", "$row")
        assertEquals(1, inbox.summary?.review)
        assertTrue(middle in inbox.menu_bar_ids && middle in inbox.island_ids)
        subscriptions.forEach { it.close() }
    }
}
