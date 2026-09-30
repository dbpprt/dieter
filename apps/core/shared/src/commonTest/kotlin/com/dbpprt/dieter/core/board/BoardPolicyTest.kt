package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.Subagent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BoardPolicyTest {
    private val board = Board(id = "b", lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running"), Lane("review", "Review"), Lane("done", "Done")))

    @Test
    fun oneRuntimeClassifierCoversEveryAlias() {
        for (value in listOf("starting", "running", "working", "streaming", "active", " Running ")) assertEquals(RuntimeState.ACTIVE, Runtimes.classify(value), value)
        assertEquals(RuntimeState.STOPPING, Runtimes.classify("cancelling"))
        for (value in listOf("waiting", "waiting_for_user", "needs_input")) assertEquals(RuntimeState.NEEDS_INPUT, Runtimes.classify(value))
        assertEquals(RuntimeState.FAILED, Runtimes.classify("failed"))
        for (value in listOf("idle", "queued", "", null, "completed")) assertEquals(RuntimeState.IDLE, Runtimes.classify(value))
        assertTrue(Runtimes.isActive("cancelling"))
        assertFalse(Runtimes.isActive("waiting"))
    }

    @Test
    fun activityComesFromRuntimeStatusOrOperationNeverTheLane() {
        val idleInRunningLane = Card(id = "c", lane = "running", runtime = "idle")
        assertFalse(Runtimes.isActive(idleInRunningLane))
        assertTrue(Runtimes.isActive(idleInRunningLane, conversationStatus = "streaming"))
        assertTrue(Runtimes.isActive(idleInRunningLane, operation = CardOperation.STARTING))
        assertTrue(Runtimes.isBoardActive(idleInRunningLane.copy(active_subagents = listOf(Subagent(status = "running")))))
        assertTrue(Runtimes.blocksWorkspace(Card(runtime = "waiting_for_user")))
        assertEquals("starting", Runtimes.resolved("idle", "idle", CardOperation.STARTING))
        assertEquals("running", Runtimes.resolved("idle", "Running"))
        assertEquals("failed", Runtimes.resolved("failed", ""))
        assertEquals("idle", Runtimes.resolved("", ""))
        assertTrue(Runtimes.isUnread(Card(response_seq = 4, seen_response_seq = 3)))
        assertFalse(Runtimes.isUnread(Card(response_seq = 4, seen_response_seq = 4)))
    }

    @Test
    fun runningAndDoneLanesPreferStableIds() {
        assertEquals("running", Lanes.running(board)?.id)
        assertEquals("in-flight", Lanes.running(Board(lanes = listOf(Lane("in-flight", "Running"))))?.id)
        assertNull(Lanes.running(Board(lanes = listOf(Lane("todo", "Todo")))))
        assertEquals("done", Lanes.done(board)?.id)
        assertEquals("shipped", Lanes.done(Board(lanes = listOf(Lane("todo", "Todo"), Lane("shipped", "Done"))))?.id)
        assertEquals("archive", Lanes.done(Board(lanes = listOf(Lane("todo", "Todo"), Lane("archive", "Archive"))))?.id)
        assertNull(Lanes.done(Board()))
    }

    @Test
    fun placementWinsOverCreationTimeAndPendingMovesUseTheirAnchors() {
        val a = Card(id = "a", lane = "todo", order_key = "b", created_at = "2026-01-03T00:00:00Z")
        val b = Card(id = "b", lane = "todo", order_key = "a", created_at = "2026-01-01T00:00:00Z")
        val c = Card(id = "c", lane = "todo", order_key = "c")
        val tie = Card(id = "0", lane = "todo", order_key = "c")
        assertEquals(listOf("b", "a", "0", "c"), Lanes.arrange(listOf(a, b, c, tie)).map { it.id })
        assertEquals(listOf("a", "0", "b", "c"), Lanes.arrange(listOf(a, b, c, tie), mapOf("b" to PendingMove("todo", beforeCardId = "c"))).map { it.id })
        assertEquals(listOf("b", "a", "0", "c"), Lanes.arrange(listOf(a, b, c, tie), mapOf("b" to PendingMove("review"))).map { it.id }, "a move to another lane waits for the receipt")
        assertEquals(listOf("a", "0", "c", "b"), Lanes.arrange(listOf(a, b, c, tie), mapOf("b" to PendingMove("todo"))).map { it.id })
        assertEquals(listOf("a", "0", "c", "b"), Lanes.arrange(listOf(a, b, c, tie), mapOf("b" to PendingMove("todo", afterCardId = "c"))).map { it.id })
        assertEquals(listOf("a", "b", "0", "c"), Lanes.arrange(listOf(a, b, c, tie), mapOf("b" to PendingMove("todo", afterCardId = "a"))).map { it.id })
        val legacy = listOf(Card(id = "x", position = 2), Card(id = "y", position = 1))
        assertEquals(listOf("y", "x"), Lanes.arrange(legacy).map { it.id })
    }

    @Test
    fun dropAnchorsFollowTheVisualNeighbours() {
        val shown = listOf(Card(id = "1"), Card(id = "2"), Card(id = "3"))
        assertEquals(DropAnchors("1", "2"), Lanes.anchors(shown, 1, descending = false))
        assertEquals(DropAnchors("2", "1"), Lanes.anchors(shown, 1, descending = true))
        assertEquals(DropAnchors("3", ""), Lanes.anchors(shown, null, descending = false))
        assertEquals(DropAnchors("", "1"), Lanes.anchors(shown, 0, descending = false))
        assertEquals(DropAnchors("", "3"), Lanes.anchors(shown, null, descending = true))
    }

    @Test
    fun onlyNeverStartedTodoCardsCanStartOrBeEdited() {
        val todo = Card(id = "c", scope = "board", lane = "todo", initial_prompt = "Plan")
        assertTrue(CardPolicy.canStart(todo, board))
        assertFalse(CardPolicy.canStart(todo.copy(lane = "review"), board))
        assertFalse(CardPolicy.canStart(todo.copy(scope = "chat"), board))
        assertFalse(CardPolicy.canStart(todo.copy(initial_prompt = " "), board))
        assertTrue(CardPolicy.canStart(todo.copy(initial_prompt = " "), board, hasDraftAttachments = true))
        assertFalse(CardPolicy.canStart(todo.copy(initial_prompt_sent_at = "2026-01-01T00:00:00Z"), board))
        assertFalse(CardPolicy.canStart(todo.copy(merged_into_card_id = "other"), board))
        assertFalse(CardPolicy.canStart(todo, Board(lanes = listOf(Lane("todo", "Todo")))))
        assertEquals(todo.copy(lane = "running", runtime = "starting"), CardPolicy.started(todo, board))
        assertTrue(CardPolicy.canEditDraft(todo))
        assertFalse(CardPolicy.canEditDraft(todo.copy(lane = "running")))
        assertFalse(CardPolicy.canEditDraft(todo.copy(scope = "chat")))
    }

    @Test
    fun mergeNeedsAnIdleSourceAndAStartedTargetOnOneBoard() {
        val source = Card(id = "s", board_id = "b", project_id = "p", owner_daemon_id = "d", runtime = "idle")
        val target = Card(id = "t", board_id = "b", project_id = "p", owner_daemon_id = "d", initial_prompt_sent_at = "x")
        assertTrue(CardPolicy.canMerge(source, target))
        assertFalse(CardPolicy.canMerge(source.copy(runtime = "running"), target))
        assertFalse(CardPolicy.canMerge(source, target.copy(initial_prompt_sent_at = "")))
        assertFalse(CardPolicy.canMerge(source, target.copy(board_id = "other")))
        assertFalse(CardPolicy.canMerge(source, target.copy(owner_daemon_id = "e")))
        assertFalse(CardPolicy.canMerge(source, source))
    }
}
