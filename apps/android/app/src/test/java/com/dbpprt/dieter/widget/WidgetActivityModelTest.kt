package com.dbpprt.dieter.widget

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class WidgetActivityModelTest {
    private val now = Instant.parse("2026-09-26T10:00:00Z")
    private val project = Project.newBuilder().setId("p1").setName("Dieter").build()
    private fun card(id: String, runtime: String = "idle", minutes: Long = 1, chat: Boolean = false): Card =
        Card.newBuilder().setId(id).setTitle(id).setProjectId("p1").setScope(if (chat) "chat" else "board")
            .setBoardId(if (chat) "" else "b1").setRuntime(runtime)
            .setRuntimeUpdatedAt(now.minusSeconds(minutes * 60).toString())
            .setUpdatedAt(now.minusSeconds(minutes * 60).toString())
            .setInitialPromptSentAt(now.minusSeconds(3600).toString()).build()
    private fun model(cards: List<Card>, compact: Boolean = false, config: WidgetConfig = WidgetConfig()) =
        buildWidgetModel(cards, emptyMap(), listOf(project), now.toEpochMilli(), true, config, compact, now)
    private fun WidgetActivityModel.items() = rows.filterIsInstance<WidgetRow.Item>()

    @Test fun cardsAndChatsFollowInboxPriorityInEverySize() {
        val answer = card("Question", "waiting_for_user", 30)
        val unread = card("New chat reply", minutes = 2, chat = true).toBuilder().setResponseSeq(12).setSeenResponseSeq(11).build()
        val running = card("Working", "running", 1)
        val review = card("Review", minutes = 5).toBuilder().setLane("review").build()
        val recent = card("Recent chat", minutes = 10, chat = true)
        val input = listOf(recent, review, running, answer, unread)
        val expected = listOf("New chat reply", "Question", "Working", "Review", "Recent chat")
        for (compact in listOf(false, true)) {
            val result = model(input, compact)
            assertEquals(expected, result.items().map { it.cardId })
            assertEquals("Inbox", result.headerTitle)
            assertEquals(if (compact) "2 need attention\n1 running" else "2 need attention · 1 running", result.summary)
            assertEquals("Dieter · Chat", result.items()[0].subtitle)
            assertEquals("Ready for review", result.items()[3].detail)
        }
        assertEquals(listOf("Needs attention · 2", "Running · 1", "Recent · 2"),
            model(input).rows.filterIsInstance<WidgetRow.Section>().map { it.title })
    }

    @Test fun newerArchivedCopyHidesStaleConversationCopies() {
        val old = card("Old reply", minutes = 20)
        val archived = old.toBuilder().setArchived(true).setUpdatedAt(now.toString()).build()
        assertTrue(model(listOf(old, archived, old)).items().isEmpty())
    }

    @Test fun readReceiptsMoveItemsOutOfAttentionWithoutDuplicatingThem() {
        val unread = card("Reply", minutes = 3).toBuilder().setResponseSeq(8).setSeenResponseSeq(7).build()
        assertEquals(WidgetRowKind.WAITING, model(listOf(unread)).items().single().kind)
        val seen = unread.toBuilder().setSeenResponseSeq(8).setUpdatedAt(now.toString()).build()
        assertEquals(WidgetRowKind.CHAT, model(listOf(unread, seen)).items().single().kind)
        assertEquals("1 recent conversation", model(listOf(seen)).summary)
    }

    @Test fun stoppingWorkStaysRunningAndUsesCurrentTurnDetails() {
        val stopping = card("Stopping", "cancelling")
        assertEquals(WidgetRowKind.RUNNING, model(listOf(stopping)).items().single().kind)
        assertEquals("Stopping…", model(listOf(stopping)).items().single().detail)
    }

    @Test fun draftsAndPendingConversationsDoNotPretendToBeReplies() {
        val draft = card("Draft").toBuilder().clearInitialPromptSentAt().build()
        assertTrue(model(listOf(draft, card("Pending", "pending"))).items().isEmpty())
    }

    @Test fun recencyUsesTurnTimestampInsteadOfMetadataEdits() {
        val older = card("Old", minutes = 60).toBuilder().setUpdatedAt(now.toString()).build()
        assertEquals(listOf("New", "Old"), model(listOf(older, card("New", minutes = 2))).items().map { it.cardId })
    }

    @Test fun limitsAreBoundedAndSectionsCanBeHidden() {
        val input = (1..30).map { card("Reply $it", minutes = it.toLong()) }
        assertEquals(3, model(input, config = WidgetConfig(maxItems = 3, showSections = false)).rows.size)
        assertEquals(20, model(input, config = WidgetConfig(maxItems = Int.MAX_VALUE)).items().size)
        assertEquals(1, model(input, config = WidgetConfig(maxItems = -1)).items().size)
    }

    @Test fun offlineTimestampRemainsHonestWithoutAHostRefresh() {
        val first = widgetStatusText(now.toEpochMilli(), false, now)
        assertTrue(first.startsWith("Offline · updated "))
        assertEquals(first, widgetStatusText(now.toEpochMilli(), false, now.plusSeconds(7200)))
        assertEquals("Not synced yet", widgetStatusText(0, false, now))
    }
}
