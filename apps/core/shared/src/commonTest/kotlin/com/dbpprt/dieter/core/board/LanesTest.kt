package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LanesTest {
    @Test
    fun laneRolesMatchTheirIdsAndReviewLanesByName() {
        for (lane in listOf("review", "Review", "In review", "needs-review", "CODE_REVIEW")) assertTrue(Lanes.isReview(lane), lane)
        for (lane in listOf("todo", "running", "done", "", "rev")) assertFalse(Lanes.isReview(lane), lane)
        assertTrue(Lanes.isRunning("Running"))
        assertFalse(Lanes.isRunning("running-late"))
        assertTrue(Lanes.isDone("DONE"))
        assertFalse(Lanes.isDone("undone"))
    }

    @Test
    fun onlyAnUnfiledChatIsAChat() {
        assertTrue(Cards.isChat(Card(id = "c", scope = "chat")))
        assertFalse(Cards.isChat(Card(id = "c", scope = "chat", board_id = "b", lane = "review")), "a chat filed on a board behaves like a card")
        assertFalse(Cards.isChat(Card(id = "c", scope = "board", board_id = "b")))
        assertFalse(Cards.isChat(Card(id = "c", scope = "board")), "a board card stays a card while its board is unknown")
        assertFalse(Cards.isChat(Card(id = "c")))
    }

    @Test
    fun cardsNameTheirAgentByProviderAndModel() {
        assertEquals("codex · gpt-5", Cards.agent(Card(provider = "codex", model = "gpt-5")))
        assertEquals("agent · gpt-5", Cards.agent(Card(model = "gpt-5")))
        assertEquals("claude", Cards.agent(Card(provider = "claude")))
        assertEquals("agent", Cards.agent(Card()))
    }

    @Test
    fun laneKindsComeFromTheIdThenTheName() {
        assertEquals(LaneKind.RUNNING, Lanes.kind(Lane("in-flight", "Running")))
        assertEquals(LaneKind.REVIEW, Lanes.kind(Lane("check", "In review")))
        assertEquals(LaneKind.REVIEW, Lanes.kind(Lane("code_review", "Ship")), "the ID decides first")
        assertEquals(LaneKind.DONE, Lanes.kind(Lane("Done", "")))
        assertEquals(LaneKind.OTHER, Lanes.kind(Lane("todo", "Todo")))
    }

    @Test
    fun aBoardWithoutLanesShowsTheDefaultWorkflow() {
        assertEquals(listOf("todo", "running", "review", "done"), Lanes.shown(Board(id = "b")).map { it.id })
        assertEquals(listOf("todo", "running", "review", "done"), Lanes.shown(null).map { it.id })
        assertEquals(listOf("Todo", "Running", "Review", "Done"), Lanes.DEFAULT.map { it.name })
        val own = Board(id = "b", lanes = listOf(Lane("ideas", "Ideas")))
        assertEquals(own.lanes, Lanes.shown(own))
    }
}
