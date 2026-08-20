package com.dbpprt.nauclio.connection

import com.dbpprt.nauclio.v1.Card
import com.dbpprt.nauclio.v1.Conversation
import com.dbpprt.nauclio.v1.ConversationSnapshot
import com.dbpprt.nauclio.v1.Subagent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationTransitionTrackerTest {
    @Test
    fun startupDoesNotReplayTerminalNotifications() {
        val tracker = NotificationTransitionTracker()

        val events = tracker.update(emptyList(), listOf(chat("chat", "idle")), emptyMap())

        assertTrue(events.isEmpty())
    }

    @Test
    fun dismissedRunningChatGetsFreshTerminalEventWithSubagentTotals() {
        val tracker = NotificationTransitionTracker()
        val running = chat("chat", "running")
        val conversation = ConversationSnapshot.newBuilder()
            .setConversation(
                Conversation.newBuilder()
                    .addSubagents(subagent("one", "completed"))
                    .addSubagents(subagent("two", "running")),
            )
            .build()
        tracker.update(emptyList(), listOf(running), mapOf(running.id to conversation))

        val events = tracker.update(emptyList(), listOf(chat("chat", "idle")), emptyMap())

        val finished = events.single() as NauclioNotificationEvent.ChatFinished
        assertEquals(2, finished.subagentCount)
        assertEquals(1, finished.completedSubagentCount)
    }

    @Test
    fun enteringReviewEmitsOnce() {
        val tracker = NotificationTransitionTracker()
        tracker.update(listOf(boardCard("card", "running")), emptyList(), emptyMap())

        val first = tracker.update(
            listOf(boardCard("card", "running-board", "review")),
            emptyList(),
            emptyMap(),
            setOf("running-board"),
        )
        val repeated = tracker.update(
            listOf(boardCard("card", "running-board", "review")),
            emptyList(),
            emptyMap(),
            setOf("running-board"),
        )

        assertTrue(first.single() is NauclioNotificationEvent.ReadyForReview)
        assertTrue(repeated.isEmpty())
    }

    @Test
    fun disabledBoardDoesNotNotifyOrReplayWhenEnabledLater() {
        val tracker = NotificationTransitionTracker()
        tracker.update(listOf(boardCard("card", "quiet-board", "running")), emptyList(), emptyMap())

        val disabled = tracker.update(
            listOf(boardCard("card", "quiet-board", "review")),
            emptyList(),
            emptyMap(),
        )
        val enabledLater = tracker.update(
            listOf(boardCard("card", "quiet-board", "review")),
            emptyList(),
            emptyMap(),
            setOf("quiet-board"),
        )

        assertTrue(disabled.isEmpty())
        assertTrue(enabledLater.isEmpty())
    }

    private fun chat(id: String, runtime: String): Card = Card.newBuilder()
        .setId(id)
        .setScope("chat")
        .setRuntime(runtime)
        .build()

    private fun boardCard(id: String, lane: String): Card = boardCard(id, "board", lane)

    private fun boardCard(id: String, boardId: String, lane: String): Card = Card.newBuilder()
        .setId(id)
        .setScope("board")
        .setBoardId(boardId)
        .setLane(lane)
        .build()

    private fun subagent(id: String, status: String): Subagent = Subagent.newBuilder()
        .setId(id)
        .setStatus(status)
        .build()
}
