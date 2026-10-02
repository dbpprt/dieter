package com.dbpprt.dieter.core.notifications

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.connection.ConnectionPhase
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NotificationsTest {
    @Test
    fun contentCarriesItsCardAndKindBesideTheOpaqueKey() {
        val chat = Card(id = "chat", scope = "chat", title = "Fix it", runtime = "running", runtime_updated_at = "2026-10-01T10:00:00Z")
        val running = NotificationContent.running(chat, null, 2)
        assertEquals(NotificationKind.RUNNING, running.kind)
        assertEquals(NotificationRole.RUNNING, running.role)
        assertEquals("chat", running.cardId)
        assertEquals("2 models active now", running.expanded)
        assertEquals("1 model active now", NotificationContent.running(chat, null, 1).expanded)

        val result = NotificationContent.result(NotificationEvent.ChatFinished("chat", chat.copy(runtime = "idle"), null, emptyList()), NotificationSettings())
        assertEquals(NotificationKind.RESULT, result.kind)
        assertEquals(NotificationRole.RESULTS, result.role)
        assertEquals("chat", result.cardId)

        val card = Card(id = "card", board_id = "b", title = "Ship", lane = "review")
        val review = NotificationContent.review(NotificationEvent.ReadyForReview("card", card), "Main", NotificationSettings())
        assertEquals(NotificationKind.REVIEW, review.kind)
        assertEquals(NotificationRole.RESULTS, review.role)
        assertEquals("card", review.cardId)
        assertEquals(listOf(NotificationAction.MARK_DONE, NotificationAction.OPEN), review.actions)
        assertTrue(setOf(running.key, result.key, review.key).size == 3, "every notification has its own key")
    }

    @Test
    fun theResultsSummaryCountsTheStackedUpdates() {
        assertEquals(ResultSummary("2 Dieter updates", "Chats finished or cards are ready for review"), ResultSummary.of(2))
        assertEquals("5 Dieter updates", ResultSummary.of(5).title)
    }

    @Test
    fun theBoardScopeListsBoardsByProjectMachineAndName() {
        val projects = listOf(Project(id = "p1", name = "dieter"), Project(id = "p2", name = "Atlas"), Project(id = "p3", name = ""))
        val boards = listOf(
            Board(id = "b1", project_id = "p1", name = "Main"),
            Board(id = "b2", project_id = "p2", name = "roadmap"),
            Board(id = "b3", project_id = "p2", name = "Bugs"),
            Board(id = "b4", project_id = "p3", name = ""),
            Board(id = "b1", project_id = "p1", name = "Main"),
        )
        val hostnames = mapOf("p1" to "mac-mini", "p3" to "")
        val scope = NotificationBoardScope.of(boards, projects, hostnames, NotificationSettings(boardIds = setOf("b3", "gone")))
        assertEquals(listOf("b4", "b3", "b2", "b1"), scope.rows.map { it.id }, "unnamed projects sort first, then by project and board name")
        assertEquals(NotificationBoardRow("b4", "Untitled board", "Workspace", selected = false), scope.rows[0])
        assertEquals(NotificationBoardRow("b3", "Bugs", "Atlas", selected = true), scope.rows[1])
        assertEquals("dieter · mac-mini", scope.rows[3].detail)
        assertEquals("1 of 4 synced boards", scope.summary, "only listed boards count as selected")
        assertEquals(setOf("gone", "b1", "b2", "b3", "b4"), scope.allBoardIds, "selecting all keeps the other choices")
        assertTrue(scope.enabled && scope.canSelectAll && scope.canSelectNone)
        assertEquals("0 of 1 synced board", NotificationBoardScope.of(boards.take(1), projects, hostnames, NotificationSettings()).summary)
    }

    @Test
    fun theBoardScopeControlsFollowTheReviewSetting() {
        val boards = listOf(Board(id = "b1", project_id = "p1", name = "Main"))
        val off = NotificationBoardScope.of(boards, emptyList(), emptyMap(), NotificationSettings(reviewCards = false, boardIds = setOf("b1")))
        assertFalse(off.enabled || off.canSelectAll || off.canSelectNone)
        assertFalse(NotificationBoardScope.of(boards, emptyList(), emptyMap(), NotificationSettings(enabled = false)).enabled)
        val empty = NotificationBoardScope.of(emptyList(), emptyList(), emptyMap(), NotificationSettings())
        assertTrue(empty.rows.isEmpty())
        assertFalse(empty.canSelectAll, "nothing to select")
        assertFalse(empty.canSelectNone, "nothing selected")
        assertEquals("0 of 0 synced boards", empty.summary)
        assertTrue(NotificationBoardScope.of(emptyList(), emptyList(), emptyMap(), NotificationSettings(boardIds = setOf("b9"))).canSelectNone, "a choice of boards not synced yet can be cleared")
    }

    @Test
    fun theConnectionStatusCountsBoardsReviewsAndSubagents() {
        val items = listOf(
            Card(id = "chat", scope = "chat", runtime = "running", active_subagents = listOf(Subagent(id = "a", status = "running"), Subagent(id = "b", status = "running"))),
            Card(id = "card", board_id = "b", lane = "review", runtime = "running", active_subagents = listOf(Subagent(id = "c", status = "running"))),
            Card(id = "other", board_id = "b", lane = "review"),
        )
        val status = BackgroundStatus.of(ConnectionPhase.CONNECTED, null, "mac-mini", BackgroundMode.LIVE, items, 2, true, NotificationSettings())
        assertEquals("Connected to mac-mini", status.title)
        assertEquals("2 models active now", status.subtext)
        assertEquals("2 boards", status.boardsLabel)
        assertEquals("2 reviews", status.reviewsLabel)
        assertEquals(3, status.subagents)
        assertEquals("3 subagents", status.subagentsLabel)

        val single = BackgroundStatus.of(ConnectionPhase.CONNECTED, null, "mac-mini", BackgroundMode.LIVE, items.drop(1).take(1), 1, true, NotificationSettings())
        assertEquals("1 board", single.boardsLabel)
        assertEquals("1 review", single.reviewsLabel)
        assertEquals("1 subagent", single.subagentsLabel)
        assertEquals("1 model active now", single.subtext)

        val idle = BackgroundStatus.of(ConnectionPhase.CONNECTED, null, "mac-mini", BackgroundMode.LIVE, emptyList(), 0, false, NotificationSettings())
        assertEquals("0 boards", idle.boardsLabel)
        assertNull(idle.reviewsLabel)
        assertNull(idle.subagentsLabel)
        assertEquals("Ongoing", idle.subtext)
    }

    @Test
    fun liveStatusOffHidesRunningWorkAndSubagents() {
        val items = listOf(Card(id = "chat", scope = "chat", runtime = "running", active_subagents = listOf(Subagent(id = "a", status = "running"))))
        val status = BackgroundStatus.of(ConnectionPhase.CONNECTED, null, "mac-mini", BackgroundMode.LIVE, items, 1, true, NotificationSettings(liveStatus = false))
        assertEquals(0, status.running)
        assertEquals(0, status.subagents)
        assertNull(status.subagentsLabel)
        assertEquals("Ongoing", status.subtext)
    }
}
