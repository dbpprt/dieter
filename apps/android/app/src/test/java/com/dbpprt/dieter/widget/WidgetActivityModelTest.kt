package com.dbpprt.dieter.widget

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class WidgetActivityModelTest {
    private val now: Instant = Instant.parse("2026-08-22T10:00:00Z")
    private val zone: ZoneId = ZoneId.of("UTC")
    private val project: Project = Project.newBuilder().setId("p1").setName("Agent workspace").build()

    private fun card(
        id: String,
        title: String,
        lane: String = "running",
        runtime: String = "",
        scope: String = "board",
        summary: String = "",
        runtimeUpdatedAt: String = "",
        phaseChangedAt: String = "",
        updatedAt: String = "2026-08-22T09:00:00Z",
        archived: Boolean = false,
    ): Card = Card.newBuilder()
        .setId(id)
        .setScope(scope)
        .setProjectId("p1")
        .setLane(lane)
        .setTitle(title)
        .setRuntime(runtime)
        .setSummary(summary)
        .setRuntimeUpdatedAt(runtimeUpdatedAt)
        .setPhaseChangedAt(phaseChangedAt)
        .setUpdatedAt(updatedAt)
        .setLastActivityAt(updatedAt)
        .setArchived(archived)
        .build()

    private fun build(
        cards: List<Card> = emptyList(),
        chats: List<Card> = emptyList(),
        config: WidgetConfig = WidgetConfig(),
        compact: Boolean = false,
        hostname: String? = "mac-mini",
        lastSyncAtMs: Long = now.toEpochMilli() - 60_000,
    ): WidgetActivityModel = buildWidgetModel(
        cards = cards,
        chats = chats,
        conversations = emptyMap(),
        projects = listOf(project),
        hostname = hostname,
        lastSyncAtMs = lastSyncAtMs,
        config = config,
        compact = compact,
        now = now,
        zoneId = zone,
    )

    @Test
    fun ordersAttentionBeforeRunningBeforeFinishedSections() {
        val waiting = card(
            "c1", "Lets understand the code",
            lane = "running", runtime = "waiting_for_user",
            runtimeUpdatedAt = "2026-08-21T16:00:00Z",
        )
        val running = card(
            "c2", "Migrate schedule store",
            lane = "running", runtime = "running",
            runtimeUpdatedAt = "2026-08-22T09:48:00Z",
        )
        val doneToday = card(
            "c3", "Subagents",
            lane = "done", runtime = "completed",
            summary = "start 3 sub agents for testing",
            phaseChangedAt = "2026-08-22T09:41:00Z",
        )
        val doneYesterday = card(
            "c4", "Hi",
            lane = "done", runtime = "completed",
            phaseChangedAt = "2026-08-21T17:38:00Z",
        )
        val model = build(cards = listOf(doneYesterday, running, doneToday, waiting))

        val items = model.rows.filterIsInstance<WidgetRow.Item>()
        assertEquals(listOf("c1", "c2", "c3", "c4"), items.map { it.cardId })

        val first = items[0]
        assertEquals(WidgetRowKind.WAITING, first.kind)
        assertTrue(first.highlighted)
        assertEquals("Agent workspace · waiting on you", first.subtitle)
        assertEquals("since 18h", first.trailing)

        val second = items[1]
        assertEquals(WidgetRowKind.RUNNING, second.kind)
        assertEquals("12m elapsed", second.trailing)

        val sections = model.rows.filterIsInstance<WidgetRow.Section>().map { it.title }
        assertEquals(listOf("Finished today", "Yesterday"), sections)
        assertEquals("start 3 sub agents for testing", items[2].subtitle)
        assertEquals("09:41", items[2].trailing)
        assertEquals("Agent workspace · marked done", items[3].subtitle)
    }

    @Test
    fun finishedChatsAppearAsChatReplied() {
        val chat = card(
            "ch1", "we dont need kanna cli anylonger",
            scope = "chat", lane = "", runtime = "completed",
            runtimeUpdatedAt = "2026-08-22T09:12:00Z",
        )
        val model = build(chats = listOf(chat))
        val item = model.rows.filterIsInstance<WidgetRow.Item>().single()
        assertEquals(WidgetRowKind.CHAT, item.kind)
        assertEquals("Agent workspace · chat replied", item.subtitle)
        assertEquals("09:12", item.trailing)
    }

    @Test
    fun reviewLaneCardsAskForReview() {
        val review = card(
            "c1", "Ship the widgets",
            lane = "review", runtime = "idle",
            phaseChangedAt = "2026-08-22T08:00:00Z",
        )
        val model = build(cards = listOf(review))
        val item = model.rows.filterIsInstance<WidgetRow.Item>().single()
        assertEquals(WidgetRowKind.REVIEW, item.kind)
        assertEquals("Agent workspace · ready for review", item.subtitle)
        assertEquals("since 2h", item.trailing)
    }

    @Test
    fun compactModelListsOnlyFinishedWork() {
        val running = card("c1", "Busy", runtime = "running", runtimeUpdatedAt = "2026-08-22T09:48:00Z")
        val done = card(
            "c2", "Subagents",
            lane = "done", runtime = "completed",
            phaseChangedAt = "2026-08-22T09:58:00Z",
        )
        val chat = card(
            "ch1", "Hi",
            scope = "chat", lane = "", runtime = "completed",
            runtimeUpdatedAt = "2026-08-21T17:00:00Z",
        )
        val model = build(cards = listOf(running, done), chats = listOf(chat), compact = true)

        assertTrue(model.compact)
        assertEquals("Last finished", model.headerTitle)
        val items = model.rows.filterIsInstance<WidgetRow.Item>()
        assertEquals(listOf("c2", "ch1"), items.map { it.cardId })
        assertEquals("Subagents · marked done", items[0].title)
        assertEquals("2m", items[0].trailing)
        assertEquals("Hi · replied", items[1].title)
        assertEquals("17h", items[1].trailing)
    }

    @Test
    fun configLimitsItemsAndSectionsAndChats() {
        val cards = (1..5).map { index ->
            card(
                "c$index", "Card $index",
                lane = "done", runtime = "completed",
                phaseChangedAt = "2026-08-22T09:0$index:00Z",
            )
        }
        val chat = card(
            "ch1", "Chat",
            scope = "chat", lane = "", runtime = "completed",
            runtimeUpdatedAt = "2026-08-22T09:30:00Z",
        )
        val model = build(
            cards = cards,
            chats = listOf(chat),
            config = WidgetConfig(maxItems = 3, showSections = false, includeChats = false),
        )
        val items = model.rows.filterIsInstance<WidgetRow.Item>()
        assertEquals(3, items.size)
        assertFalse(items.any { it.cardId == "ch1" })
        assertTrue(model.rows.filterIsInstance<WidgetRow.Section>().isEmpty())
    }

    @Test
    fun archivedCardsAreHidden() {
        val archived = card(
            "c1", "Old",
            lane = "done", runtime = "completed",
            phaseChangedAt = "2026-08-22T09:00:00Z", archived = true,
        )
        assertTrue(build(cards = listOf(archived)).rows.isEmpty())
    }

    @Test
    fun failedWorkIsMarkedFailed() {
        val failed = card(
            "ch1", "Broken",
            scope = "chat", lane = "", runtime = "failed",
            runtimeUpdatedAt = "2026-08-22T09:00:00Z",
        )
        val full = build(chats = listOf(failed))
        assertEquals(WidgetRowKind.FAILED, full.rows.filterIsInstance<WidgetRow.Item>().single().kind)
        val compact = build(chats = listOf(failed), compact = true)
        assertEquals("Broken · failed", compact.rows.filterIsInstance<WidgetRow.Item>().single().title)
    }

    @Test
    fun statusLineReflectsHostAndSyncRecency() {
        assertEquals("mac-mini · just polled", statusLine("mac-mini", now.toEpochMilli() - 20_000, now))
        assertEquals("mac-mini · polled 5m ago", statusLine("mac-mini", now.minusSeconds(300).toEpochMilli(), now))
        assertEquals("polled 2h ago", statusLine(null, now.minusSeconds(7_200).toEpochMilli(), now))
        assertEquals("mac-mini · not synced yet", statusLine("mac-mini", 0, now))
        assertTrue(isOnline(now.minusSeconds(60).toEpochMilli(), now))
        assertFalse(isOnline(now.minusSeconds(600).toEpochMilli(), now))
        assertFalse(isOnline(0, now))
    }

    @Test
    fun pendingChatsAreNotFinished() {
        val pending = card(
            "ch1", "Queued",
            scope = "chat", lane = "", runtime = "pending",
            runtimeUpdatedAt = "2026-08-22T09:00:00Z",
        )
        assertTrue(build(chats = listOf(pending)).rows.isEmpty())
    }
}
