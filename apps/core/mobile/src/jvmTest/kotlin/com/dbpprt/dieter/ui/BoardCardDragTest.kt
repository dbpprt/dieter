package com.dbpprt.dieter.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import com.dbpprt.dieter.api.v1.Card
import org.junit.Assert.*
import org.junit.Test

class BoardCardDragTest {
    private val card = Card(id = "card", lane = "running")

    private fun dragState() =
        BoardCardDragState().apply {
            registerLane("running", Rect(0f, 0f, 100f, 500f))
            registerLane("review", Rect(110f, 0f, 210f, 500f))
        }

    @Test
    fun emptyLaneAcceptsExactlyOneDrop() {
        val state = dragState()
        state.start(card, Offset(50f, 50f))
        state.moveTo(Offset(150f, 50f))
        assertEquals("review", state.targetLaneId)
        assertEquals(BoardCardLaneDrop("card", "review"), state.finish())
        assertNull(state.finish())
        assertNull(state.card)
    }

    @Test
    fun sameLaneOutsideAndCancelledDragsDoNotMoveCards() {
        val state = dragState()
        state.start(card, Offset(50f, 50f))
        assertNull(state.finish())
        state.start(card.copy(lane = "Running"), Offset(50f, 50f)) // Lanes match ignoring case.
        assertNull(state.finish())
        state.start(card, Offset(105f, 50f)) // Gap between columns.
        assertNull(state.finish())
        state.start(card, Offset(150f, 550f)) // Below the board.
        assertNull(state.finish())
        state.start(card, Offset(150f, 50f))
        state.reset()
        assertNull(state.finish())
    }

    @Test
    fun scrollingAndRemovedLanesCannotLeaveStaleTargets() {
        val state = dragState()
        state.start(card, Offset(150f, 50f))
        state.registerLane("review", Rect(220f, 0f, 320f, 500f))
        assertNull(state.targetLaneId)
        state.moveTo(Offset(250f, 50f))
        assertEquals("review", state.targetLaneId)
        state.unregisterLane("review")
        assertNull(state.finish())
    }

    @Test
    fun edgeScrollingStopsOutsideTheBoardAndInItsCenter() {
        assertEquals(-0.5f, boardDragScrollDelta(20f, 0f, 200f, 40f))
        assertEquals(0.5f, boardDragScrollDelta(180f, 0f, 200f, 40f))
        assertEquals(0f, boardDragScrollDelta(100f, 0f, 200f, 40f))
        assertEquals(0f, boardDragScrollDelta(210f, 0f, 200f, 40f))
    }
}
