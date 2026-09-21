package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class ActivityModelTest {
    private val now = Instant.parse("2026-09-21T12:00:00Z")
    private fun card(id: String, runtime: String, scope: String = "card", lane: String = "running", ago: Long = 600) =
        Card.newBuilder().setId(id).setScope(scope).setProjectId("project").setBoardId("board")
            .setTitle("Task $id").setInitialPromptSentAt(now.minusSeconds(1800).toString()).setRuntime(runtime).setLane(lane)
            .setRuntimeUpdatedAt(now.minusSeconds(ago).toString()).setUpdatedAt(now.minusSeconds(ago).toString()).build()

    @Test fun `chats and cards share grouping and waiting outranks review`() {
        val entries = buildActivityEntries(listOf(card("chat", "waiting_for_user", "chat"),
            card("card", "waiting_for_user", lane = "review"), card("review", "idle", lane = "review"),
            card("run", "running", "chat"), card("stop", "cancelling"), card("fail", "failed")))
        assertEquals(2, entries.count { it.kind == ActivityKind.ANSWER })
        assertEquals(1, entries.count { it.kind == ActivityKind.REVIEW })
        assertEquals(2, entries.count { it.running })
        assertEquals(1, entries.count { it.kind == ActivityKind.FAILED })
    }

    @Test fun `latest copy wins including archived tombstone and unstarted drafts stay out`() {
        val old = card("one", "running")
        val updated = old.toBuilder().setRuntime("idle").setUpdatedAt(now.toString()).build()
        assertFalse(buildActivityEntries(listOf(old, updated, old)).single().running)
        val runtimeOnly = old.toBuilder().setRuntime("idle").setRuntimeUpdatedAt(now.toString()).build()
        assertFalse(buildActivityEntries(listOf(old, runtimeOnly)).single().running)
        assertTrue(buildActivityEntries(listOf(old, updated.toBuilder().setArchived(true).build())).isEmpty())
        assertTrue(buildActivityEntries(listOf(card("draft", "pending"), card("blank", ""),
            card("unstarted", "idle").toBuilder().clearInitialPromptSentAt().build())).isEmpty())
    }

    @Test fun `project and search filters cover chat and board names`() {
        val entries = buildActivityEntries(listOf(card("chat", "idle", "chat"), card("card", "idle"),
            card("elsewhere", "running").toBuilder().setProjectId("other").build()))
        val projects = mapOf("project" to "Dieter", "other" to "Other")
        val boards = mapOf("board" to "Release")
        assertEquals(2, filterActivityEntries(entries, "project", "dieter", projects, boards).size)
        assertEquals(2, filterActivityEntries(entries, "project", "release", projects, boards).size)
        assertEquals("chat", filterActivityEntries(entries, "", "CHAT", projects, boards).single().card.id)
        assertTrue(filterActivityEntries(entries, "other", "Dieter", projects, boards).isEmpty())
    }

    @Test fun `timeline clips running intervals and uses event points for unknown completed starts`() {
        val entries = buildActivityEntries(listOf(card("long", "running", ago = 7200), card("done", "idle"),
            card("old", "idle", ago = 7200), card("future", "idle", ago = -60)))
        val timeline = activityTimeline(entries, now, 1)
        assertEquals(setOf("long", "done"), timeline.map { it.entry.card.id }.toSet())
        val running = timeline.single { it.entry.card.id == "long" }
        assertEquals(0f, running.from); assertEquals(1f, running.to); assertFalse(running.point)
        assertTrue(timeline.single { it.entry.card.id == "done" }.point)
        assertEquals(3, activityTimeline(entries, now, 6).size)
    }

    @Test fun `stale conversation start is rejected and valid completed duration retained`() {
        val done = card("done", "idle")
        val stale = ActivityDetail("older", now.minusSeconds(1200), "Old tool")
        assertNull(buildActivityEntries(listOf(done), mapOf("done" to stale)).single().start)
        val valid = stale.copy(runtimeUpdatedAt = done.runtimeUpdatedAt)
        val entry = buildActivityEntries(listOf(done), mapOf("done" to valid)).single()
        assertEquals(valid.start, entry.start)
        assertFalse(activityTimeline(listOf(entry), now, 1).single().point)
    }

    @Test fun `quota reset uses the same clock as activity and labels unavailable values`() {
        assertEquals("Resets in 2h", activityResetText(now.plusSeconds(7200).toString(), now))
        assertEquals("Reset due", activityResetText(now.minusSeconds(1).toString(), now))
        assertEquals("Reset time unavailable", activityResetText("bad", now))
    }

    @Test fun `missing and malformed timestamps do not invent completed duration`() {
        val missing = card("missing", "failed").toBuilder().setRuntimeUpdatedAt("bad").build()
        assertNull(buildActivityEntries(listOf(missing)).single().at)
        assertTrue(activityTimeline(buildActivityEntries(listOf(missing)), now, 1).isEmpty())
        assertEquals("Time unavailable", activityAge(null, now))
        assertEquals(Destination.ACTIVITY, DieterUiState().destination)
    }
}
