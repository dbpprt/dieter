package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.DraftAgentSettings
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
        val keyless = listOf(Card(id = "x", position = 2), Card(id = "y", position = 1))
        assertEquals(listOf("y", "x"), Lanes.arrange(keyless).map { it.id })
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
    fun theEditFormIsCheckedAsSavingChecksIt() {
        val draft = Card(id = "c", scope = "board", lane = "todo", title = "Fix", initial_prompt = "Fix it", provider = "codex", model = "sol", effort = "low")
        val same = DraftAgentSettings("codex", "sol", "low")
        assertNull(CardPolicy.draftProblem(draft, "Fix", "Fix it", DraftAgentSettings("claude")))
        assertEquals("Enter a title.", CardPolicy.draftProblem(draft, "", "Fix it", null))
        assertEquals("Enter the agent's task.", CardPolicy.draftProblem(draft, "Fix", "  ", null))
        val sent = draft.copy(initial_prompt_sent_at = "2026-01-01T00:00:00Z")
        assertNull(CardPolicy.draftProblem(sent, "Renamed", "Fix it", null))
        assertNull(CardPolicy.draftProblem(sent, "Renamed", " Fix it\n", same), "the card's own agent and task are no change")
        assertEquals("The task was already sent to the agent; only the title can change.", CardPolicy.draftProblem(sent, "Renamed", "Other", null))
        assertEquals("The task was already sent to the agent; only the title can change.", CardPolicy.draftProblem(sent, "Renamed", "Fix it", same.copy(effort = "high")))
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

    @Test
    fun mergeKeysAgreeWithTheMergeRule() {
        // Ported from the Mac's boardMergeRequiresIdleSourceAndStartedTarget.
        var source = Card(id = "source", board_id = "board", project_id = "project")
        var target = source.copy(id = "target")
        assertFalse(CardPolicy.canMerge(source, target), "an unstarted target")
        assertEquals("", CardPolicy.mergeTargetKey(target))
        target = target.copy(initial_prompt_sent_at = "sent", runtime = "running")
        assertTrue(CardPolicy.canMerge(source, target))
        assertEquals("board|project|", CardPolicy.mergeSourceKey(source))
        assertEquals(CardPolicy.mergeSourceKey(source), CardPolicy.mergeTargetKey(target))
        assertFalse(CardPolicy.canMerge(source, source))
        source = source.copy(runtime = "running")
        assertFalse(CardPolicy.canMerge(source, target))
        assertEquals("", CardPolicy.mergeSourceKey(source), "a working source")
        source = source.copy(runtime = "idle", merged_into_card_id = "other")
        assertFalse(CardPolicy.canMerge(source, target))
        assertEquals("", CardPolicy.mergeSourceKey(source))

        val idle = Card(id = "s", board_id = "b", project_id = "p", owner_daemon_id = "d")
        assertEquals("", CardPolicy.mergeSourceKey(idle, CardOperation.STARTING), "a start in flight is work")
        assertEquals("", CardPolicy.mergeSourceKey(idle.copy(active_subagents = listOf(Subagent(status = "pending")))), "a pending delegated agent is work")
        assertEquals("", CardPolicy.mergeSourceKey(idle.copy(board_id = "")), "an unfiled chat")
        assertEquals("", CardPolicy.mergeTargetKey(idle.copy(initial_prompt_sent_at = "x", archived = true)))
        assertTrue(CardPolicy.mergeSourceKey(idle) != CardPolicy.mergeTargetKey(idle.copy(id = "t", initial_prompt_sent_at = "x", owner_daemon_id = "e")), "another machine")
    }

    @Test
    fun aTurnCanBeCancelledWhileItWorksOrWaits() {
        for (runtime in listOf("running", "starting", "streaming", "waiting_for_user", "needs_input")) assertTrue(CardPolicy.canCancel(Card(runtime = runtime)), runtime)
        for (runtime in listOf("idle", "", "failed", "completed", "cancelling")) assertFalse(CardPolicy.canCancel(Card(runtime = runtime)), runtime)
        assertFalse(CardPolicy.canCancel(Card(runtime = "running"), CardOperation.CANCELLING), "a cancel already in flight")
        assertTrue(CardPolicy.canCancel(Card(runtime = "running"), CardOperation.MOVING))
    }

    @Test
    fun onlyBoardTodoCardsWithAnUnsentTaskEditTheirDraft() {
        // Ported from the Mac's onlyTodoCardsWhoseInitialTaskWasNeverSentCanBeEdited; the card must be a board card.
        val card = Card(scope = "board", lane = "todo", initial_prompt = "Draft task")
        assertTrue(CardPolicy.canEditDraft(card))
        assertTrue(CardPolicy.canEditDraft(card.copy(lane = "Todo")))
        assertFalse(CardPolicy.canEditDraft(card.copy(lane = "running")))
        assertFalse(CardPolicy.canEditDraft(card.copy(initial_prompt_sent_at = "2026-08-25T12:00:00Z")))
        assertFalse(CardPolicy.canEditDraft(card.copy(initial_prompt = "   ")))
        assertFalse(CardPolicy.canEditDraft(card.copy(scope = "")), "the Mac allowed a card without a scope; the core requires a board card")
    }

    @Test
    fun runtimeTonesAndLabelsFollowTheClassifier() {
        for (runtime in listOf("running", "working", "streaming", "active", "starting", "cancelling", " Running ")) assertEquals(RuntimeTone.ACTIVE, Runtimes.tone(runtime), runtime)
        for (runtime in listOf("waiting", "waiting_for_user", "needs_input")) assertEquals(RuntimeTone.ATTENTION, Runtimes.tone(runtime), runtime)
        for (runtime in listOf("completed", "done")) assertEquals(RuntimeTone.DONE, Runtimes.tone(runtime), runtime)
        for (runtime in listOf("failed", "error", "cancelled", "canceled")) assertEquals(RuntimeTone.FAILED, Runtimes.tone(runtime), runtime)
        for (runtime in listOf("idle", "", "queued", "review")) assertEquals(RuntimeTone.IDLE, Runtimes.tone(runtime), runtime)
        assertEquals(RuntimeTone.ACTIVE, Runtimes.tone("idle", CardOperation.STARTING))
        assertEquals(RuntimeTone.ACTIVE, Runtimes.tone("failed", CardOperation.CANCELLING))

        assertEquals("Running", Runtimes.label("streaming"))
        assertEquals("Starting…", Runtimes.label("idle", CardOperation.STARTING))
        assertEquals("Stopping…", Runtimes.label("cancelling"))
        assertEquals("Waiting for you", Runtimes.label("waiting_for_user"))
        assertEquals("Failed", Runtimes.label("error"))
        assertEquals("Idle", Runtimes.label(""))
        assertEquals("Idle", Runtimes.label("IDLE"))
        assertEquals("Completed", Runtimes.label("completed"))
        assertEquals("Needs review", Runtimes.label("needs_review"))
    }

    @Test
    fun theStatusDotTracksTheRuntimeRatherThanTheLane() {
        // Ported from the Mac's BoardAgentStatusTests.
        var card = Card(lane = "running", runtime = "idle")
        assertEquals(AgentStatus.IDLE, Runtimes.agentStatus(card))
        for (status in listOf("running", "starting", "streaming", "working", "cancelling")) {
            card = card.copy(lane = "done", runtime = status)
            assertEquals(AgentStatus.RUNNING, Runtimes.agentStatus(card), status)
        }
        for (status in listOf("failed", "error")) assertEquals(AgentStatus.FAILED, Runtimes.agentStatus(card.copy(runtime = status)), status)
        for (status in listOf("idle", "completed", "done", "cancelled", "")) assertEquals(AgentStatus.IDLE, Runtimes.agentStatus(card.copy(runtime = status)), status)
        assertEquals(AgentStatus.RUNNING, Runtimes.agentStatus(card.copy(runtime = "idle"), CardOperation.STARTING))

        // A delegated agent keeps the card running, even after its own turn failed.
        val failed = Card(runtime = "failed", active_subagents = listOf(Subagent(status = "running")))
        assertEquals(AgentStatus.RUNNING, Runtimes.agentStatus(failed))
        assertEquals(AgentStatus.FAILED, Runtimes.agentStatus(failed.copy(active_subagents = listOf(Subagent(status = "completed")))))
        assertEquals("Agent running", AgentStatus.RUNNING.label)
        assertEquals("Agent turn failed", AgentStatus.FAILED.label)
        assertEquals("No agent work in progress", AgentStatus.IDLE.label)
    }

    @Test
    fun chatRowsUseTheSharedActiveAliases() {
        // Ported from the Mac's activeChatRuntimeAliasesReceiveTheRunningTreatment; "active" and "cancelling" count too.
        for (runtime in listOf("running", "RUNNING", "starting", "working", "streaming", "active", "cancelling")) assertTrue(Runtimes.isActive(runtime), runtime)
        for (runtime in listOf("", "idle", "waiting_for_user", "completed", "failed")) assertFalse(Runtimes.isActive(runtime), runtime)
    }
}
