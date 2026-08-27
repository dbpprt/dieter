package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.Subagent
import com.dbpprt.dieter.settings.DieterNotificationSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

        val finished = events.single() as DieterNotificationEvent.ChatFinished
        assertEquals(2, finished.subagentCount)
        assertEquals(1, finished.completedSubagentCount)
    }

    @Test
    fun finishedChatCarriesTheFinalAssistantMessageAsResultPreview() {
        val tracker = NotificationTransitionTracker()
        val running = chat("chat", "running")
        val conversation = ConversationSnapshot.newBuilder()
            .setConversation(
                Conversation.newBuilder()
                    .addMessages(message("m1", "user", "please fix the bug"))
                    .addMessages(message("m2", "assistant", "All tests pass now.")),
            )
            .build()
        tracker.update(emptyList(), listOf(running), mapOf(running.id to conversation))

        val events = tracker.update(emptyList(), listOf(chat("chat", "idle")), emptyMap())

        val finished = events.single() as DieterNotificationEvent.ChatFinished
        assertEquals("All tests pass now.", finished.resultPreview)
    }

    @Test
    fun longResultPreviewsKeepTheClosingWords() {
        val text = "start words " + "filler ".repeat(80) + "closing words"
        val snapshot = ConversationSnapshot.newBuilder()
            .setConversation(
                Conversation.newBuilder().addMessages(message("m", "assistant", text)),
            )
            .build()

        val preview = conversationResultPreview(snapshot, maxLength = 60)

        assertTrue(preview.length <= 60)
        assertTrue(preview.startsWith("…"))
        assertTrue(preview.endsWith("closing words"))
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

        assertTrue(first.single() is DieterNotificationEvent.ReadyForReview)
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

    @Test
    fun successfulAndAttentionOutcomesAreFilteredIndependently() {
        val tracker = NotificationTransitionTracker()
        val successful = chat("successful", "running")
        val failed = chat("failed", "running")
        tracker.update(emptyList(), listOf(successful, failed), emptyMap())

        val events = tracker.update(
            emptyList(),
            listOf(chat("successful", "idle"), chat("failed", "failed")),
            emptyMap(),
            notificationSettings = DieterNotificationSettings(
                successfulChatsEnabled = false,
                attentionChatsEnabled = true,
            ),
        )

        assertEquals(listOf("failed"), events.map { it.card.id })
    }

    @Test
    fun masterSwitchSuppressesAllOptionalTransitionsWithoutReplayingLater() {
        val tracker = NotificationTransitionTracker()
        tracker.update(
            listOf(boardCard("card", "board", "running")),
            listOf(chat("chat", "running")),
            emptyMap(),
        )

        val disabled = tracker.update(
            listOf(boardCard("card", "board", "review")),
            listOf(chat("chat", "idle")),
            emptyMap(),
            notificationBoardIds = setOf("board"),
            notificationSettings = DieterNotificationSettings(activityNotificationsEnabled = false),
        )
        val enabledLater = tracker.update(
            listOf(boardCard("card", "board", "review")),
            listOf(chat("chat", "idle")),
            emptyMap(),
            notificationBoardIds = setOf("board"),
        )

        assertTrue(disabled.isEmpty())
        assertTrue(enabledLater.isEmpty())
        assertFalse(
            chatResultNotificationEnabled(
                chat("failed", "failed"),
                DieterNotificationSettings(activityNotificationsEnabled = false),
            ),
        )
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

    private fun message(id: String, role: String, text: String): com.dbpprt.dieter.v1.UiMessage =
        com.dbpprt.dieter.v1.UiMessage.newBuilder()
            .setId(id)
            .setRole(role)
            .addParts(com.dbpprt.dieter.v1.MessagePart.newBuilder().setType("text").setText(text))
            .build()
}
