package com.getdieter.core.notifications

import com.getdieter.api.v1.Card
import kotlin.test.Test
import kotlin.test.assertEquals

class AttentionNotificationsTest {
    private class Sink : AttentionNotificationSink {
        val posted = mutableListOf<Triple<String, String, String>>()
        var ids = emptyList<String>()
        var badge = 0

        override fun post(cardId: String, title: String, text: String) {
            posted += Triple(cardId, title, text)
        }

        override fun reconcile(cardIds: List<String>, badge: Int) {
            ids = cardIds
            this.badge = badge
        }

        override fun reset() {
            ids = emptyList()
            badge = 0
        }
    }

    @Test
    fun replaySetsBadgeButOnlyLiveUnreadTransitionsAlert() {
        val sink = Sink()
        val planner = AttentionNotifications(sink)
        val unread =
            Card(
                id = "card",
                title = "Ship it",
                runtime = "idle",
                response_seq = 2,
                seen_response_seq = 1,
            )
        planner.frame(listOf(unread), replaying = { true })
        assertEquals(1, sink.badge)
        assertEquals(emptyList(), sink.posted)
        planner.frame(listOf(unread.copy(title = "Updated title")))
        assertEquals(emptyList(), sink.posted, "metadata changes cannot repeat an alert")
        planner.frame(listOf(unread.copy(response_seq = 3)))
        assertEquals(listOf(Triple("card", "New reply", "Ship it")), sink.posted)
        planner.frame(listOf(unread.copy(response_seq = 3, seen_response_seq = 3)))
        assertEquals(0, sink.badge)
        assertEquals(emptyList(), sink.ids)
    }

    @Test
    fun questionsAlertAndVisibleConversationsDoNot() {
        val sink = Sink()
        val planner = AttentionNotifications(sink)
        val running = Card(id = "card", title = "Deploy", runtime = "running")
        planner.frame(listOf(running), replaying = { true })
        val question =
            running.copy(runtime = "waiting_for_user", runtime_updated_at = "2026-11-07T12:00:00Z")
        planner.frame(listOf(question))
        planner.frame(listOf(question))
        assertEquals(listOf(Triple("card", "Task needs you", "Deploy")), sink.posted)
        assertEquals(1, sink.badge)
        planner.frame(listOf(question), visibleId = "card")
        assertEquals(emptyList(), sink.ids, "remove alerts for the conversation on screen")
        assertEquals(1, sink.posted.size)
        planner.frame(listOf(running))
        assertEquals(0, sink.badge)
        planner.frame(listOf(question), visibleId = "card")
        assertEquals(1, sink.posted.size, "a visible question needs no banner")
    }

    @Test
    fun archivedAndReadReviewCardsDoNotNeedYouAndResetClearsAccountState() {
        val sink = Sink()
        val planner = AttentionNotifications(sink)
        val unread = Card(id = "card", lane = "review", response_seq = 1)
        planner.frame(listOf(unread), replaying = { true })
        planner.frame(listOf(unread.copy(archived = true)))
        assertEquals(0, sink.badge)
        planner.frame(listOf(unread.copy(seen_response_seq = 1)))
        assertEquals(0, sink.badge, "a Review placement by itself is not unread")
        planner.frame(listOf(unread), replaying = { true })
        planner.reset()
        assertEquals(0, sink.badge)
        assertEquals(emptyList(), sink.ids)
    }
}
