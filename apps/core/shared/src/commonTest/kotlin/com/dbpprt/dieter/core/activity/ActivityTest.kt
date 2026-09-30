package com.dbpprt.dieter.core.activity

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardDetail
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.notifications.NotificationContent
import com.dbpprt.dieter.core.notifications.NotificationEvent
import com.dbpprt.dieter.core.notifications.NotificationPlanner
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.notifications.NotificationSink
import com.dbpprt.dieter.core.notifications.SummaryAction
import com.dbpprt.dieter.core.notifications.TransitionTracker
import com.dbpprt.dieter.core.notifications.resultSummaryAction
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

class ActivityTest {
    private val now = Instant.parse("2026-09-30T12:00:00Z")
    private fun at(minutesAgo: Int) = (now - minutesAgo.minutes).toString()
    private fun started(id: String, runtime: String, minutesAgo: Int = 5, lane: String = "todo", scope: String = "board") = Card(
        id = id, runtime = runtime, lane = lane, scope = scope, board_id = if (scope == "chat") "" else "b", project_id = "p",
        initial_prompt_sent_at = at(minutesAgo + 1), runtime_updated_at = at(minutesAgo), last_activity_at = at(minutesAgo), title = id,
    )

    @Test
    fun classificationAndDetailFollowOnePrecedence() {
        assertEquals(ActivityKind.ANSWER, Activity.classify(started("a", "waiting_for_user", lane = "review")))
        assertEquals(ActivityKind.RUNNING, Activity.classify(started("r", "streaming")))
        assertEquals(ActivityKind.UNREAD, Activity.classify(started("u", "idle").copy(response_seq = 3, seen_response_seq = 2)))
        assertEquals(ActivityKind.REVIEW, Activity.classify(started("v", "idle", lane = "review")))
        assertEquals(ActivityKind.FAILED, Activity.classify(started("f", "failed")))
        assertEquals(ActivityKind.RECENT, Activity.classify(started("c", "idle", lane = "review", scope = "chat")))
        assertNull(Activity.classify(Card(id = "draft", runtime = "")))
        assertNull(Activity.classify(Card(id = "pending", runtime = "pending", initial_prompt_sent_at = "x", runtime_updated_at = "x")))
        assertEquals("Stopping…", Activity.detail(started("s", "cancelling"), ActivityKind.RUNNING, null))
        assertEquals("Stopped", Activity.detail(started("s", "canceled"), ActivityKind.RECENT, null))
        assertEquals("Replied", Activity.detail(started("s", "idle", scope = "chat"), ActivityKind.RECENT, null))
    }

    @Test
    fun runningRowsKeepTheirPlaceAndArchivedTombstonesWin() {
        val cards = listOf(
            started("running", "running", minutesAgo = 30),
            started("recent", "idle", minutesAgo = 1),
            started("old", "idle", minutesAgo = 60),
            started("gone", "idle", minutesAgo = 2),
            started("gone", "idle", minutesAgo = 2).copy(archived = true, updated_at = at(0)),
        )
        val items = Activity.project(cards, emptyMap(), listOf(Project(id = "p", name = "Dieter")), emptyList())
        assertEquals(listOf("recent", "running", "old"), items.map { it.id })
        assertEquals("Dieter", items.first().projectName)
        val sections = Activity.sections(items)
        assertEquals(listOf("running"), sections.getValue(ActivitySection.RUNNING).map { it.id })
        assertEquals(listOf("recent"), Activity.filter(items, null, " rec").map { it.id })
        assertEquals(0, Activity.needsYouCount(items))
    }

    @Test
    fun aStaleTranscriptNeverDescribesTheCurrentTurn() {
        val card = started("c", "running")
        val oldSnapshot = ConversationSnapshot(detail = CardDetail(card = card.copy(runtime_updated_at = at(90))), conversation = Conversation(status = "running"))
        assertEquals("Working on your request", Activity.project(listOf(card), mapOf("c" to oldSnapshot), emptyList(), emptyList()).single().detail)
        val fresh = oldSnapshot.copy(detail = CardDetail(card = card), conversation = Conversation(status = "running", messages = listOf(UiMessage(role = "assistant", parts = listOf(MessagePart(type = "text", text = "x", state = "streaming"))))))
        assertEquals("Writing response…", Activity.project(listOf(card), mapOf("c" to fresh), emptyList(), emptyList()).single().detail)
    }

    @Test
    fun ageAndTimeline() {
        assertEquals("Just now", Activity.age(now, now, suffix = true))
        assertEquals("5m ago", Activity.age(now - 5.minutes, now, suffix = true))
        assertEquals("3h", Activity.age(now - 3.hours, now))
        assertEquals("2d", Activity.age(now - 50.hours, now))
        assertEquals("Time unavailable", Activity.age(null, now))
        val items = Activity.project(listOf(started("run", "running", minutesAgo = 30), started("done", "idle", minutesAgo = 120), started("ancient", "idle", minutesAgo = 600)), emptyMap(), emptyList(), emptyList())
        val bars = Activity.timeline(items, now, hours = 6)
        assertEquals(setOf("run", "done"), bars.map { it.item.id }.toSet())
        val run = bars.single { it.item.id == "run" }
        assertEquals(1.0, run.to)
        assertFalse(run.point)
    }

    @Test
    fun widgetIslandAndMenuBarShareTheProjection() {
        val items = Activity.project(
            listOf(started("ask", "waiting_for_user"), started("run", "running"), started("chat", "idle", scope = "chat"), started("rev", "idle", lane = "review")),
            emptyMap(), listOf(Project(id = "p", name = "Dieter")), emptyList(),
        )
        val widget = WidgetModel.build(items, now, maxItems = 3)
        assertEquals(listOf("Needs attention · 1", "Running · 1", "Recent · 2"), widget.rows.filterIsInstance<WidgetModel.Row.Header>().map { it.title })
        assertEquals(3, widget.rows.filterIsInstance<WidgetModel.Row.Item>().size, "sections share one budget")
        assertEquals("1 need attention · 1 running", widget.summary)
        assertTrue(WidgetModel.build(items, now, widthDp = 200).compact)
        assertEquals("Cards and chats, together", WidgetModel.build(emptyList(), now).summary)

        val island = IslandModel.build(items, dayStart = now - 12.hours)
        assertEquals(listOf("run", "rev", "ask"), island.items.map { it.id })
        assertEquals("1 running", island.header)
        assertEquals(1, island.doneToday)
        assertEquals(listOf("ask", "rev", "chat"), MenuBar.items(items, now).map { it.id })
    }

    @Test
    fun transitionsNeverReplayAndRespectSettings() {
        val tracker = TransitionTracker()
        val settings = NotificationSettings(boardIds = setOf("b"))
        val chat = started("chat", "running", scope = "chat")
        val card = started("card", "idle", lane = "running")
        assertTrue(tracker.update(listOf(chat, card), emptyMap(), settings).isEmpty(), "the first frame is a baseline")
        val events = tracker.update(listOf(chat.copy(runtime = "idle"), card.copy(lane = "review")), emptyMap(), settings)
        assertEquals(2, events.size)
        assertIs<NotificationEvent.ChatFinished>(events[0])
        assertIs<NotificationEvent.ReadyForReview>(events[1])
        // Cancelling is still active; only the end of the turn notifies.
        val stopping = TransitionTracker().also { it.update(listOf(chat), emptyMap(), settings) }
        assertTrue(stopping.update(listOf(chat.copy(runtime = "cancelling")), emptyMap(), settings).isEmpty())
        // Transitions while disabled are not replayed after re-enabling.
        val muted = TransitionTracker()
        muted.update(listOf(chat), emptyMap(), settings.copy(enabled = false))
        assertTrue(muted.update(listOf(chat.copy(runtime = "idle")), emptyMap(), settings.copy(enabled = false)).isEmpty())
        assertTrue(muted.update(listOf(chat.copy(runtime = "idle")), emptyMap(), settings).isEmpty())
        // Review alerts need the board opted in.
        val optOut = TransitionTracker().also { it.update(listOf(card), emptyMap(), NotificationSettings()) }
        assertTrue(optOut.update(listOf(card.copy(lane = "review")), emptyMap(), NotificationSettings()).isEmpty())
    }

    @Test
    fun plannerPostsResultsAndSkipsTheVisibleConversation() {
        val posted = mutableListOf<String>()
        val cancelled = mutableListOf<String>()
        val planner = NotificationPlanner(object : NotificationSink {
            override fun post(content: NotificationContent): Boolean { posted += content.key + "=" + content.title; return true }
            override fun cancel(key: String) { cancelled += key }
        })
        val settings = NotificationSettings()
        val chat = started("chat", "running", scope = "chat")
        planner.frame(listOf(chat), emptyMap(), settings, emptyMap(), { "Reading x" })
        assertEquals(listOf("running:chat=chat"), posted)
        planner.frame(listOf(chat), emptyMap(), settings, emptyMap(), { "Reading x" })
        assertEquals(1, posted.size, "an unchanged running notification is not reposted")
        planner.frame(listOf(chat.copy(runtime = "failed")), emptyMap(), settings, emptyMap(), { null })
        assertTrue("running:chat" in cancelled)
        assertEquals("result:chat=Chat failed", posted.last())

        val quiet = mutableListOf<String>()
        val visible = NotificationPlanner(object : NotificationSink {
            override fun post(content: NotificationContent): Boolean { quiet += content.key; return true }
            override fun cancel(key: String) = Unit
        })
        visible.frame(listOf(chat), emptyMap(), settings, emptyMap(), { null }, visibleConversationId = "chat")
        visible.frame(listOf(chat.copy(runtime = "idle")), emptyMap(), settings, emptyMap(), { null }, visibleConversationId = "chat")
        assertTrue(quiet.isEmpty())
    }

    @Test
    fun resultContentAndSummaries() {
        val long = "word ".repeat(100).trim()
        val preview = NotificationContent.resultPreview(ConversationSnapshot(conversation = Conversation(messages = listOf(UiMessage(role = "assistant", parts = listOf(MessagePart(type = "text", text = long)))))))!!
        assertTrue(preview.startsWith("…") && preview.length <= 320 && preview.endsWith("word"))
        val event = NotificationEvent.ChatFinished("c", Card(id = "c", runtime = "idle"), "Done", listOf(Subagent(status = "completed"), Subagent(status = "running")))
        assertEquals("Subagents finished · 1 of 2", NotificationContent.result(event, NotificationSettings()).title)
        assertEquals("Done", NotificationContent.result(event.copy(subagents = emptyList()), NotificationSettings()).expanded)
        assertEquals(SummaryAction.POST, resultSummaryAction(setOf("a", "b"), emptySet(), false))
        assertEquals(SummaryAction.UNCHANGED, resultSummaryAction(setOf("a", "b"), setOf("a", "b"), true))
        assertEquals(SummaryAction.CANCEL, resultSummaryAction(setOf("a"), setOf("a", "b"), true))
        assertEquals(SummaryAction.UNCHANGED, resultSummaryAction(setOf("a"), emptySet(), false))
    }
}
