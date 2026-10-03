package com.dbpprt.dieter.core.activity

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

class WidgetModelTest {
    private val now = Instant.parse("2026-09-26T10:00:00Z")
    private val project = Project(id = "p1", name = "Dieter")

    private fun card(id: String, runtime: String = "idle", minutes: Long = 1, chat: Boolean = false): Card {
        val at = (now - minutes.minutes).toString()
        return Card(
            id = id, title = id, project_id = "p1", scope = if (chat) "chat" else "board", board_id = if (chat) "" else "b1", runtime = runtime,
            runtime_updated_at = at, updated_at = at, initial_prompt_sent_at = (now - 60.minutes).toString(),
        )
    }

    private fun model(cards: List<Card>, style: WidgetModel.Style = WidgetModel.Style.ACTIVITY, maxItems: Int = 12, showSections: Boolean = true) =
        WidgetModel.build(Activity.project(cards, emptyMap(), listOf(project), emptyList()), now, maxItems, showSections, style)

    private fun WidgetModel.items() = rows.filterIsInstance<WidgetModel.Row.Item>()

    @Test fun cardsAndChatsFollowInboxPriorityInEverySize() {
        val answer = card("Question", "waiting_for_user", 30)
        val unread = card("New chat reply", minutes = 2, chat = true).copy(response_seq = 12, seen_response_seq = 11)
        val running = card("Working", "running", 1)
        val review = card("Review", minutes = 5).copy(lane = "review")
        val recent = card("Recent chat", minutes = 10, chat = true)
        val input = listOf(recent, review, running, answer, unread)
        val expected = listOf("New chat reply", "Question", "Working", "Review", "Recent chat")
        for (style in listOf(WidgetModel.Style.ACTIVITY, WidgetModel.Style.COMPACT)) {
            val result = model(input, style)
            val compact = style == WidgetModel.Style.COMPACT
            assertEquals(compact, result.compact)
            assertEquals(expected, result.items().map { it.id })
            assertEquals(if (compact) "2 need attention\n1 running" else "2 need attention · 1 running", result.summary)
            assertEquals("Ready for review", result.items()[3].detail)
        }
        assertEquals("Dieter · Chat", model(input).items()[0].subtitle)
        assertEquals("Dieter · Card", model(input).items()[1].subtitle)
        assertEquals(listOf("Needs attention · 2", "Running · 1", "Recent · 2"), model(input).rows.filterIsInstance<WidgetModel.Row.Header>().map { it.title })
        assertTrue(model(input, WidgetModel.Style.COMPACT).rows.none { it is WidgetModel.Row.Header })
        assertEquals("Inbox", WidgetModel.TITLE)
    }

    @Test fun newerArchivedCopyHidesStaleConversationCopies() {
        val old = card("Old reply", minutes = 20)
        val archived = old.copy(archived = true, updated_at = now.toString())
        assertTrue(model(listOf(old, archived, old)).items().isEmpty())
    }

    @Test fun readReceiptsMoveItemsOutOfAttentionWithoutDuplicatingThem() {
        val unread = card("Reply", minutes = 3).copy(response_seq = 8, seen_response_seq = 7)
        assertEquals(WidgetModel.RowKind.WAITING, model(listOf(unread)).items().single().kind)
        val seen = unread.copy(seen_response_seq = 8, updated_at = now.toString())
        assertEquals(WidgetModel.RowKind.CHAT, model(listOf(unread, seen)).items().single().kind)
        assertEquals("1 recent conversation", model(listOf(seen)).summary)
    }

    @Test fun stoppingWorkStaysRunningAndUsesCurrentTurnDetails() {
        val stopping = model(listOf(card("Stopping", "cancelling"))).items().single()
        assertEquals(WidgetModel.RowKind.RUNNING, stopping.kind)
        assertEquals("Stopping…", stopping.detail)
    }

    @Test fun draftsAndPendingConversationsDoNotPretendToBeReplies() {
        val draft = card("Draft").copy(initial_prompt_sent_at = "")
        assertTrue(model(listOf(draft, card("Pending", "pending"))).items().isEmpty())
    }

    @Test fun recencyUsesTurnTimestampInsteadOfMetadataEdits() {
        val older = card("Old", minutes = 60).copy(updated_at = now.toString())
        assertEquals(listOf("New", "Old"), model(listOf(older, card("New", minutes = 2))).items().map { it.id })
    }

    @Test fun limitsAreBoundedAndSectionsCanBeHidden() {
        val input = (1..30).map { card("Reply $it", minutes = it.toLong()) }
        assertEquals(3, model(input, maxItems = 3, showSections = false).rows.size)
        assertEquals(20, model(input, maxItems = Int.MAX_VALUE).items().size)
        assertEquals(1, model(input, maxItems = -1).items().size)
    }

    @Test fun statusAndEmptyStatesStayHonestWithoutAHostRefresh() {
        assertEquals("Offline · updated Sep 26, 10:00", WidgetModel.status("Sep 26, 10:00", connected = false))
        assertEquals("Updated Sep 26, 10:00", WidgetModel.status("Sep 26, 10:00", connected = true))
        assertEquals("Not synced yet", WidgetModel.status(null, connected = false))
        assertEquals("Syncing…", WidgetModel.status(null, connected = true))
        assertEquals("Refreshing…", WidgetModel.status("Updated", refreshing = true, refreshFailed = true), "a running refresh wins")
        assertEquals("Couldn’t refresh", WidgetModel.status("Updated", refreshing = false, refreshFailed = true))
        assertEquals("Updated", WidgetModel.status("Updated", refreshing = false, refreshFailed = false))
        assertEquals("Open Dieter to connect", WidgetModel.emptyTitle(synced = false, connected = false))
        assertEquals("All quiet here", WidgetModel.emptyTitle(synced = true, connected = false))
    }
}
