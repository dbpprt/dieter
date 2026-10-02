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
import com.dbpprt.dieter.core.testing.MemoryDeviceSettings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
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

        val filed = started("filed", "idle", lane = "In review", scope = "chat").copy(board_id = "b")
        assertEquals(ActivityKind.REVIEW, Activity.classify(filed), "a chat filed on a board waits in review like a card")
        assertEquals("Finished", Activity.detail(filed.copy(lane = "todo"), ActivityKind.RECENT, null))
        val review = Activity.project(listOf(filed), emptyMap(), emptyList(), emptyList()).single()
        assertFalse(review.chat)
        assertTrue(review.canFinish, "a review lane counts by name")
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

        val island = IslandModel.build(items)
        assertEquals(listOf("run", "ask", "chat", "rev"), island.items.map { it.id })
        assertEquals("Dieter Island. 1 running, 1 need attention, 2 recent.", island.accessibility)
        assertEquals(ActivityCounts(running = 1, attention = 1, recent = 2, review = 1, subagents = 0), ActivityCounts.of(items))
        assertEquals(listOf("ask", "rev", "chat"), MenuBar.items(items, now).map { it.id })
    }

    private fun item(id: String, kind: ActivityKind, scope: String = "board", lane: String = "todo", minutesAgo: Int = 5, subagents: Int = 0) = ActivityItem(
        card = Card(id = id, title = id, scope = scope, board_id = if (scope == "chat") "" else "b", lane = lane, active_subagents = List(subagents) { Subagent(status = "running") }),
        kind = kind, detail = "Inbox detail for $id", at = now - minutesAgo.minutes, start = null, sortAt = now - minutesAgo.minutes,
        projectName = null, boardName = null,
    )

    @Test
    fun theIslandShowsRunningThenWaitingThenTheRestWithFullCounts() {
        // Ported from the Mac's islandUsesInboxKindsOrderingAndFullCountsBeforeLimitingRows.
        val kinds = listOf(ActivityKind.RECENT, ActivityKind.FAILED, ActivityKind.REVIEW, ActivityKind.UNREAD, ActivityKind.ANSWER, ActivityKind.RUNNING)
        val items = kinds.map { item(it.name, it, scope = if (it == ActivityKind.ANSWER) "chat" else "board", subagents = if (it == ActivityKind.RUNNING) 2 else 0) }
        val island = IslandModel.build(items)
        assertEquals(1, island.running)
        assertEquals(2, island.attention)
        assertEquals(3, island.recent)
        assertEquals(2, island.subagents)
        assertEquals(listOf("RUNNING", "UNREAD", "ANSWER", "RECENT"), island.items.map { it.id }, "groups first, the feed's order within them, four rows")
        assertTrue(island.items[2].chat)
        assertEquals("Inbox detail for UNREAD", island.items[1].detail)
        // A seen reply leaves attention through the same classification as the Inbox.
        val seen = items.map { if (it.kind == ActivityKind.UNREAD) it.copy(kind = ActivityKind.REVIEW) else it }
        assertEquals(1, IslandModel.build(seen).attention)
        assertEquals(4, IslandModel.build(seen).recent)
        assertEquals(IslandModel(emptyList(), 0, 0, 0, 0), IslandModel.build(emptyList()))
    }

    @Test
    fun rowsCarryTheirTitleShownTimeAndMenuLine() {
        val running = item("run", ActivityKind.RUNNING).copy(start = now - 30.minutes)
        assertEquals(now - 30.minutes, running.shownAt, "a running row shows when its turn started")
        assertEquals(now - 5.minutes, running.copy(start = null).shownAt)
        assertEquals(now - 5.minutes, item("done", ActivityKind.RECENT).copy(start = now - 30.minutes).shownAt)
        assertEquals("Untitled chat", item("c", ActivityKind.RECENT, scope = "chat").let { it.copy(card = it.card.copy(title = " ")) }.title)
        assertEquals("Untitled card", Activity.title(Card(id = "x", scope = "chat", board_id = "b")), "a chat filed on a board is a card")
        assertEquals("Named", Activity.title(Card(title = "Named")))
        assertTrue(item("a", ActivityKind.ANSWER).needsYou && item("u", ActivityKind.UNREAD).needsYou)
        assertFalse(item("v", ActivityKind.REVIEW).needsYou)
        assertFalse(item("c", ActivityKind.REVIEW, scope = "chat", lane = "review").canFinish, "an unfiled chat never finishes")
        assertEquals(
            listOf("Needs you", "Running", "Unread reply", "Ready for review", "Failed", "Finished"),
            ActivityKind.entries.map(MenuBar::title),
        )
    }

    @Test
    fun theMenuChangesWhenARecentRowLeavesItsSixHourWindow() {
        val items = listOf(item("old", ActivityKind.RECENT, minutesAgo = 300), item("new", ActivityKind.FAILED, minutesAgo = 10), item("ask", ActivityKind.ANSWER, minutesAgo = 600))
        val next = MenuBar.nextChange(items, now)!!
        assertEquals(now - 300.minutes + 6.hours + 1.milliseconds, next)
        assertEquals(listOf("ask", "old", "new"), MenuBar.items(items, now).map { it.id })
        assertEquals(listOf("ask", "new"), MenuBar.items(items, next).map { it.id }, "the oldest result has left")
        assertNull(MenuBar.nextChange(listOf(item("gone", ActivityKind.RECENT, minutesAgo = 400), item("ask", ActivityKind.ANSWER)), now), "only rows still in the window count")
    }

    @Test
    fun rowsNameTheirPlaceAndTheHeaderCountsTheFeed() {
        val card = item("card", ActivityKind.REVIEW).copy(projectName = "dieter", boardName = "Main")
        assertEquals("Card", card.noun)
        assertEquals("dieter · Main · Card", card.context)
        val chat = item("chat", ActivityKind.RECENT, scope = "chat").copy(projectName = "dieter", boardName = "Main")
        assertEquals("Chat", chat.noun)
        assertEquals("dieter · Chat", chat.context, "a chat names no board")
        assertEquals("Card", item("lost", ActivityKind.RECENT).context, "unknown places are left out")
        val items = listOf(item("ask", ActivityKind.ANSWER), item("run", ActivityKind.RUNNING), item("run2", ActivityKind.RUNNING), card)
        assertEquals("3 projects · 1 needs attention · 2 running", Activity.overview(3, items))
        assertEquals("1 project · 0 need attention · 0 running", Activity.overview(1, emptyList()))
        assertEquals("2 projects · 2 need attention · 0 running", Activity.overview(2, listOf(item("a", ActivityKind.ANSWER), item("u", ActivityKind.UNREAD))))
    }

    @Test
    fun searchMatchesTitleProjectAndBoardTrimmedAndIgnoringCase() {
        assertTrue(Activity.matches(" release ", "Ship the Release", null, null))
        assertTrue(Activity.matches("dieter", "x", "Dieter", null))
        assertTrue(Activity.matches("TRAIN", "x", "", "Release train"))
        assertTrue(Activity.matches("  ", "x", null, null), "a blank query matches")
        assertFalse(Activity.matches("gateway", "x", "Dieter", "Release train"))
    }

    @Test
    fun timelineSpansClipToTheWindowAndKeepBoundaryEvents() {
        // Ported from the Mac's timelineClipsDurationsKeepsBoundaryEventsAndOmitsOutsideEvents.
        val boundary = now - 1.hours
        val clipped = Activity.span(start = now - 2.hours, at = now - 1.minutes, running = false, now = now, hours = 1)!!
        assertEquals(0.0, clipped.from)
        assertEquals(3540.0 / 3600, clipped.to)
        assertFalse(clipped.point)
        assertEquals(Activity.TimelineSpan(0.0, 0.0, point = true), Activity.span(null, boundary, false, now, 1))
        assertNull(Activity.span(null, boundary - 1.seconds, false, now, 1), "just before the window")
        assertTrue(Activity.span(null, boundary - 1.seconds, false, now, 6) != null, "inside a longer window")
        assertNull(Activity.span(null, now + 1.seconds, false, now, 1), "in the future")
        assertEquals(1.0, Activity.span(now - 2.minutes, now - 1.minutes, true, now, 1)!!.to, "running work reaches now")
        assertNull(Activity.span(null, null, false, now, 1), "no time")
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
        // A chat filed on a board notifies like a card, and a review lane counts by name.
        val filed = started("filed", "running", lane = "running", scope = "chat").copy(board_id = "b")
        val board = TransitionTracker().also { it.update(listOf(filed), emptyMap(), settings) }
        assertIs<NotificationEvent.ReadyForReview>(board.update(listOf(filed.copy(runtime = "idle", lane = "In review")), emptyMap(), settings).single())
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
    fun aDismissedRunningChatStaysHiddenForItsSessionAndTheDismissalEndsWithIt() {
        val posted = mutableListOf<String>()
        val sink = object : NotificationSink {
            override fun post(content: NotificationContent): Boolean { posted += content.key; return true }
            override fun cancel(key: String) = Unit
        }
        val device = MemoryDeviceSettings()
        val settings = NotificationSettings()
        val chat = started("chat", "running", scope = "chat")
        val planner = NotificationPlanner(sink, device)
        planner.dismissRunning("chat", NotificationContent.session(chat))
        planner.frame(listOf(chat), emptyMap(), settings, emptyMap(), { null })
        // A restarted app remembers the dismissal for the same session.
        NotificationPlanner(sink, device).frame(listOf(chat), emptyMap(), settings, emptyMap(), { null })
        assertTrue(posted.isEmpty(), "dismissed: $posted")
        // Once the chat stops, the dismissal is forgotten, also on the device.
        planner.frame(listOf(chat.copy(runtime = "idle", runtime_updated_at = at(1))), emptyMap(), settings, emptyMap(), { null })
        assertNull(device.string("notifications.dismissed"))
        planner.frame(listOf(chat.copy(runtime_updated_at = at(0))), emptyMap(), settings, emptyMap(), { null })
        assertTrue("running:chat" in posted, "the next session notifies: $posted")
        // Dismissals of chats that left are dropped.
        repeat(100) { planner.dismissRunning("gone$it", "s") }
        planner.frame(emptyList(), emptyMap(), settings, emptyMap(), { null })
        assertNull(device.string("notifications.dismissed"))
    }

    @Test
    fun aDismissedNotificationNamesItsRunningChatByTheKeyItWasPostedWith() {
        val running = NotificationContent.running(started("chat", "running", scope = "chat"), null, 1)
        assertEquals("chat", NotificationContent.runningCardId(running.key))
        assertNull(NotificationContent.runningCardId("review:chat"))
        assertNull(NotificationContent.runningCardId("result:chat"))
        assertNull(NotificationContent.runningCardId("running:"))
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
