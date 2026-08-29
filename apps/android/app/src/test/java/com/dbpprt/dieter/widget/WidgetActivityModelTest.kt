package com.dbpprt.dieter.widget

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class WidgetActivityModelTest {
    private val now: Instant = Instant.parse("2026-08-22T10:00:00Z")
    private val zone: ZoneId = ZoneId.of("UTC")
    private val project: Project = Project.newBuilder().setId("p1").setName("Agent workspace").build()

    private fun chat(
        id: String,
        title: String,
        runtime: String = "",
        runtimeUpdatedAt: String = "",
        updatedAt: String = "2026-08-22T09:00:00Z",
        archived: Boolean = false,
    ): Card = Card.newBuilder()
        .setId(id)
        .setScope("chat")
        .setProjectId("p1")
        .setTitle(title)
        .setRuntime(runtime)
        .setRuntimeUpdatedAt(runtimeUpdatedAt)
        .setUpdatedAt(updatedAt)
        .setLastActivityAt(updatedAt)
        .setArchived(archived)
        .build()

    private fun build(
        chats: List<Card> = emptyList(),
        config: WidgetConfig = WidgetConfig(),
        compact: Boolean = false,
        hostname: String? = "mac-mini",
        lastSyncAtMs: Long = now.toEpochMilli() - 60_000,
    ): WidgetActivityModel = buildWidgetModel(
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
    fun ordersWaitingBeforeRunningBeforeRecentReplies() {
        val waiting = chat(
            "ch1", "Lets understand the code",
            runtime = "waiting_for_user",
            runtimeUpdatedAt = "2026-08-21T16:00:00Z",
        )
        val running = chat(
            "ch2", "Migrate schedule store",
            runtime = "running",
            runtimeUpdatedAt = "2026-08-22T09:48:00Z",
            updatedAt = "2026-08-22T09:48:00Z",
        )
        val repliedToday = chat(
            "ch3", "Subagents",
            runtime = "completed",
            runtimeUpdatedAt = "2026-08-22T09:41:00Z",
        )
        val repliedYesterday = chat(
            "ch4", "Hi",
            runtime = "completed",
            runtimeUpdatedAt = "2026-08-21T17:38:00Z",
        )
        val model = build(listOf(repliedYesterday, running, repliedToday, waiting))

        val items = model.rows.filterIsInstance<WidgetRow.Item>()
        assertEquals(listOf("ch1", "ch2", "ch3", "ch4"), items.map { it.cardId })

        assertEquals(WidgetRowKind.WAITING, items[0].kind)
        assertTrue(items[0].highlighted)
        assertEquals("Agent workspace · waiting on you", items[0].subtitle)
        assertEquals("since 18h", items[0].trailing)

        assertEquals(WidgetRowKind.RUNNING, items[1].kind)
        assertEquals("12m elapsed", items[1].trailing)

        assertEquals(listOf("Replied today", "Yesterday"), model.rows.filterIsInstance<WidgetRow.Section>().map { it.title })
        assertEquals("Agent workspace · replied", items[2].subtitle)
        assertEquals("09:41", items[2].trailing)
        assertEquals("Agent workspace · replied", items[3].subtitle)
    }

    @Test
    fun compactModelListsOnlyRecentReplies() {
        val running = chat(
            "ch1", "Busy",
            runtime = "running",
            runtimeUpdatedAt = "2026-08-22T09:48:00Z",
            updatedAt = "2026-08-22T09:48:00Z",
        )
        val recent = chat(
            "ch2", "Subagents",
            runtime = "completed",
            runtimeUpdatedAt = "2026-08-22T09:58:00Z",
        )
        val older = chat(
            "ch3", "Hi",
            runtime = "completed",
            runtimeUpdatedAt = "2026-08-21T17:00:00Z",
        )
        val model = build(listOf(running, older, recent), compact = true)

        assertTrue(model.compact)
        assertEquals("Recent replies", model.headerTitle)
        val items = model.rows.filterIsInstance<WidgetRow.Item>()
        assertEquals(listOf("ch2", "ch3"), items.map { it.cardId })
        assertEquals("Subagents · replied", items[0].title)
        assertEquals("2m", items[0].trailing)
        assertEquals("Hi · replied", items[1].title)
        assertEquals("17h", items[1].trailing)
    }

    @Test
    fun configLimitsChatsAndCanHideSections() {
        val chats = (1..5).map { index ->
            chat(
                "ch$index", "Chat $index",
                runtime = "completed",
                runtimeUpdatedAt = "2026-08-22T09:0$index:00Z",
            )
        }
        val model = build(
            chats = chats,
            config = WidgetConfig(maxItems = 3, showSections = false),
        )

        assertEquals(3, model.rows.filterIsInstance<WidgetRow.Item>().size)
        assertTrue(model.rows.filterIsInstance<WidgetRow.Section>().isEmpty())
    }

    @Test
    fun archivedChatsAreHidden() {
        val archived = chat(
            "ch1", "Old",
            runtime = "completed",
            runtimeUpdatedAt = "2026-08-22T09:00:00Z",
            archived = true,
        )
        assertTrue(build(listOf(archived)).rows.isEmpty())
    }

    @Test
    fun failedChatsAreMarkedFailed() {
        val failed = chat(
            "ch1", "Broken",
            runtime = "failed",
            runtimeUpdatedAt = "2026-08-22T09:00:00Z",
        )
        val full = build(listOf(failed))
        assertEquals(WidgetRowKind.FAILED, full.rows.filterIsInstance<WidgetRow.Item>().single().kind)
        val compact = build(listOf(failed), compact = true)
        assertEquals("Broken · failed", compact.rows.filterIsInstance<WidgetRow.Item>().single().title)
    }

    @Test
    fun statusLineReflectsHostAndSyncRecency() {
        assertEquals("mac-mini · just polled", statusLine("mac-mini", now.toEpochMilli() - 20_000, now))
        assertEquals("mac-mini · polled 5m ago", statusLine("mac-mini", now.minusSeconds(300).toEpochMilli(), now))
        assertEquals("polled 2h ago", statusLine(null, now.minusSeconds(7_200).toEpochMilli(), now))
        assertEquals("mac-mini · not synced yet", statusLine("mac-mini", 0, now))
        assertTrue(isOnline(now.minusSeconds(60).toEpochMilli(), now))
        assertTrue(!isOnline(now.minusSeconds(600).toEpochMilli(), now))
        assertTrue(!isOnline(0, now))
    }

    @Test
    fun pendingChatsAreNotReplies() {
        val pending = chat(
            "ch1", "Queued",
            runtime = "pending",
            runtimeUpdatedAt = "2026-08-22T09:00:00Z",
        )
        assertTrue(build(listOf(pending)).rows.isEmpty())
    }
}
