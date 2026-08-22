package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Board
import com.dbpprt.nauclio.v1.Card
import com.dbpprt.nauclio.v1.Lane
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CardStartPolicyTest {
    @Test
    fun neverStartedTodoCardCanStart() {
        assertTrue(card().canStartFromTodo())
    }

    @Test
    fun startActionIsLimitedToNeverStartedBoardCards() {
        assertFalse(card(lane = "review").canStartFromTodo())
        assertFalse(card(scope = "chat").canStartFromTodo())
        assertFalse(card(prompt = "").canStartFromTodo())
        assertTrue(card(prompt = "").canStartFromTodo(hasDraftAttachments = true))
        assertFalse(card(promptSentAt = "2026-08-16T20:00:00Z").canStartFromTodo())
    }

    @Test
    fun runningLanePrefersTheStableId() {
        val board = Board.newBuilder()
            .addLanes(Lane.newBuilder().setId("active").setName("Running"))
            .addLanes(Lane.newBuilder().setId("running").setName("In progress"))
            .build()

        assertEquals("running", board.runningLaneId())
    }

    @Test
    fun runningLaneFallsBackToItsDisplayName() {
        val board = Board.newBuilder()
            .addLanes(Lane.newBuilder().setId("active").setName("Running"))
            .build()

        assertEquals("active", board.runningLaneId())
        assertNull(Board.getDefaultInstance().runningLaneId())
    }

    @Test
    fun overviewStartRequiresBothAnEligibleCardAndRunningLane() {
        val board = Board.newBuilder()
            .addLanes(Lane.newBuilder().setId("active").setName("Running"))
            .build()

        assertEquals("active", card().startLane(board))
        assertNull(card(lane = "review").startLane(board))
        assertNull(card().startLane(Board.getDefaultInstance()))
    }

    @Test
    fun optimisticStartMovesTheCardIntoRunningImmediately() {
        val board = Board.newBuilder()
            .addLanes(Lane.newBuilder().setId("active").setName("Running"))
            .build()

        val optimistic = requireNotNull(card(id = "card-1").optimisticStart(board))

        assertEquals("active", optimistic.lane)
        assertEquals("starting", optimistic.runtime)
    }

    @Test
    fun staleRemoteFramesCannotPullAStartingCardBackToTodo() {
        val local = card(id = "card-1", lane = "running").toBuilder().setRuntime("starting").build()
        val remote = card(id = "card-1", lane = "todo")

        val reconciled = reconcileCardsDuringOperations(
            remoteCards = listOf(remote),
            localCards = listOf(local),
            operations = mapOf("card-1" to CardOperation.STARTING),
        )

        assertEquals(listOf(local), reconciled)
    }

    @Test
    fun acknowledgedRemoteStartReplacesTheOptimisticCard() {
        val local = card(id = "card-1", lane = "running").toBuilder().setRuntime("starting").build()
        val acknowledged = card(id = "card-1", lane = "running", promptSentAt = "2026-08-22T09:00:00Z")
            .toBuilder()
            .setRuntime("running")
            .build()

        val reconciled = reconcileCardsDuringOperations(
            remoteCards = listOf(acknowledged),
            localCards = listOf(local),
            operations = mapOf("card-1" to CardOperation.STARTING),
        )

        assertEquals(listOf(acknowledged), reconciled)
    }

    @Test
    fun operationAndConversationStatusOverrideAStaleCardRuntime() {
        assertEquals("starting", resolvedCardRuntime("idle", "idle", CardOperation.STARTING))
        assertEquals("running", resolvedCardRuntime("idle", "running"))
        assertEquals("working", resolvedCardRuntime("working", "idle"))
        assertEquals("cancelling", resolvedCardRuntime("running", "running", CardOperation.CANCELLING))
        assertTrue(isActiveCardRuntime("streaming"))
        assertFalse(isActiveCardRuntime("idle"))
    }

    private fun card(
        id: String = "",
        scope: String = "board",
        lane: String = "todo",
        prompt: String = "Verify Android start",
        promptSentAt: String = "",
    ): Card = Card.newBuilder()
        .setId(id)
        .setScope(scope)
        .setLane(lane)
        .setInitialPrompt(prompt)
        .setInitialPromptSentAt(promptSentAt)
        .build()
}
