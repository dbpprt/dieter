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

    private fun card(
        scope: String = "board",
        lane: String = "todo",
        prompt: String = "Verify Android start",
        promptSentAt: String = "",
    ): Card = Card.newBuilder()
        .setScope(scope)
        .setLane(lane)
        .setInitialPrompt(prompt)
        .setInitialPromptSentAt(promptSentAt)
        .build()
}
