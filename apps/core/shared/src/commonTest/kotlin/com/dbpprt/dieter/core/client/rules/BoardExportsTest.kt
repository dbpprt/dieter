package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.client.v1.BoardAgentStatus
import com.dbpprt.dieter.client.v1.BoardLaneKind
import com.dbpprt.dieter.client.v1.BoardViewTarget
import com.dbpprt.dieter.client.v1.Cards
import com.dbpprt.dieter.client.v1.RuntimeTone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BoardExportsTest {
    private val board = Board(id = "b", lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running"), Lane("done", "Done")))

    @Test
    fun onlyAnUnfiledChatIsAChat() {
        assertTrue(BoardExports.isChat("chat", ""))
        assertFalse(BoardExports.isChat("chat", "b"), "a chat filed on a board is a card")
        assertFalse(BoardExports.isChat("board", ""))
    }

    @Test
    fun runtimesShareOneClassifier() {
        assertEquals(RuntimeTone.RUNTIME_TONE_ACTIVE, BoardExports.runtimeTone("streaming"))
        assertEquals(RuntimeTone.RUNTIME_TONE_ATTENTION, BoardExports.runtimeTone("waiting_for_user"))
        assertEquals(RuntimeTone.RUNTIME_TONE_DONE, BoardExports.runtimeTone("completed"))
        assertEquals(RuntimeTone.RUNTIME_TONE_FAILED, BoardExports.runtimeTone("cancelled"))
        assertEquals(RuntimeTone.RUNTIME_TONE_IDLE, BoardExports.runtimeTone(""))
        assertEquals("Waiting for you", BoardExports.runtimeLabel("waiting"))
        assertTrue(BoardExports.runtimeActive("active"))
        assertFalse(BoardExports.runtimeActive("waiting_for_user"))
        assertEquals(BoardLaneKind.BOARD_LANE_KIND_RUNNING, BoardExports.laneKind("in-flight", "Running"))
        assertEquals(BoardLaneKind.BOARD_LANE_KIND_OTHER, BoardExports.laneKind("todo", "Todo"))
    }

    @Test
    fun cardFlagsMatchTheBoardView() {
        val card = Card(id = "c", scope = "board", board_id = "b", lane = "todo", initial_prompt = "Go", project_id = "p", owner_daemon_id = "d")
        val idle = BoardExports.cardFlags(card, board, "", pending = false, failed = false)
        assertTrue(idle.can_start && idle.can_edit_draft && !idle.starting && !idle.can_cancel)
        assertEquals("Idle", idle.runtime_label)
        assertEquals("", idle.badge)
        assertEquals("b|p|d", idle.merge_source_key)
        assertEquals(BoardAgentStatus.BOARD_AGENT_STATUS_IDLE, idle.agent)
        assertEquals("No agent work in progress", idle.agent_label)

        val starting = BoardExports.cardFlags(card, board, "STARTING", pending = false, failed = false)
        assertTrue(starting.starting && !starting.can_start)
        assertEquals("Starting…", starting.badge)
        assertEquals("STARTING", starting.operation)
        assertEquals(RuntimeTone.RUNTIME_TONE_ACTIVE, starting.tone)

        assertFalse(BoardExports.cardFlags(card, Board(), "", pending = false, failed = false).can_start, "an unknown board has no running lane")
        val pending = BoardExports.cardFlags(card, board, "UNKNOWN", pending = true, failed = true)
        assertTrue(pending.pending && pending.failed && !pending.can_start)
        assertEquals("", pending.operation, "an unknown operation name is none")
    }

    @Test
    fun theEditFormSavesWhatTheCardStillTakes() {
        val draft = Card(id = "c", scope = "board", board_id = "b", lane = "todo", title = "Fix", initial_prompt = "Fix the crash", provider = "codex", model = "sol", effort = "low")
        val agent = HarnessSelection("codex", "sol", "low")
        assertEquals("", BoardExports.cardDraftProblem(draft, "Fix it", "Fix the crash fast", HarnessSelection("claude", "opus", "high")), "a draft takes everything")
        assertEquals("Enter a title.", BoardExports.cardDraftProblem(draft, "  ", "Fix the crash", agent))
        assertEquals("Enter the agent's task.", BoardExports.cardDraftProblem(draft, "Fix", " ", agent))
        val sent = draft.copy(initial_prompt_sent_at = "2026-09-30T10:00:00Z", lane = "running")
        assertEquals("", BoardExports.cardDraftProblem(sent, "Renamed", " Fix the crash ", agent), "a started card takes a new title")
        val tooLate = "The task was already sent to the agent; only the title can change."
        assertEquals(tooLate, BoardExports.cardDraftProblem(sent, "Renamed", "Another task", agent))
        assertEquals(tooLate, BoardExports.cardDraftProblem(sent, "Renamed", "Fix the crash", HarnessSelection("codex", "sol", "high")))
    }

    @Test
    fun aBoardViewLaysOutGivenCards() {
        val later = Card(id = "later", board_id = "b", lane = "todo", position = 2L, title = "Later")
        val sooner = Card(id = "sooner", board_id = "b", lane = "TODO", position = 1L, title = "Sooner")
        val elsewhere = Card(id = "elsewhere", board_id = "other", lane = "todo")
        val running = Card(id = "run", board_id = "b", lane = "running", runtime = "running")
        val view = BoardExports.boardView(board, Cards(listOf(sooner, later, elsewhere, running)), BoardViewTarget(board_id = "b"))
        assertEquals(listOf("todo", "running", "done"), view.lanes.map { it.lane_id })
        assertEquals(listOf("later", "sooner"), view.lanes[0].card_ids, "newest position first, lanes matched ignoring case")
        assertEquals(listOf("run"), view.lanes[1].card_ids)
        assertEquals(3, view.total)
        assertEquals("Running", view.cards.getValue("run").badge)
        assertEquals(listOf("later"), BoardExports.boardView(board, Cards(listOf(sooner, later, running)), BoardViewTarget(board_id = "b", query = "later")).lanes.flatMap { it.card_ids })
        assertEquals(emptyList(), BoardExports.boardView(board, Cards(listOf(sooner)), BoardViewTarget()).lanes, "no board bound")
    }
}
