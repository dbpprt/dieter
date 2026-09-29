package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.CardStateField
import com.dbpprt.dieter.v1.CardStateVersion
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

    @Test fun `unread replies need attention until seen across cards and chats`() {
        for (scope in listOf("board", "chat")) {
            val reply = card("reply", "idle", scope, "review").toBuilder().setResponseSeq(30).setSeenResponseSeq(10).build()
            assertEquals(ActivityKind.UNREAD, buildActivityEntries(listOf(reply)).single().kind)
            assertTrue(buildActivityEntries(listOf(reply)).single().needsYou)
            val seen = reply.toBuilder().setSeenResponseSeq(30).build()
            assertFalse(buildActivityEntries(listOf(seen)).single().needsYou)
            val next = seen.toBuilder().setResponseSeq(50).build()
            assertTrue(buildActivityEntries(listOf(next)).single().needsYou)
            assertTrue(buildActivityEntries(listOf(next.toBuilder().setRuntime("running").build())).single().running)
            assertTrue(buildActivityEntries(listOf(next.toBuilder().setArchived(true).build())).isEmpty())
        }
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

    @Test fun `latest message advances age without changing turn duration`() {
        val running = card("running", "running", ago = 7200).toBuilder()
            .setLastActivityAt(now.minusSeconds(30).toString()).build()
        val entries = buildActivityEntries(listOf(card("recent", "idle", ago = 60), running))
        val entry = entries.single { it.running }
        assertEquals(now.minusSeconds(30), entry.at)
        assertEquals("Just now", activityAge(entry.at, now))
        assertEquals(now.minusSeconds(7200), entry.start)
        assertEquals(0f, activityTimeline(entries, now, 1).single { it.entry.running }.from)
    }

    @Test fun `interleaved model events cannot reorder running cards and chats`() {
        val older = card("older", "running", ago = 7200)
        val newer = card("newer", "running", "chat", ago = 3600)
        for (index in 0..5) {
            val oldUpdate = older.toBuilder().setLastActivityAt(now.plusSeconds(index * 2L).toString()).build()
            val newUpdate = newer.toBuilder().setLastActivityAt(now.plusSeconds(index * 2L - 1).toString()).build()
            for (cards in listOf(listOf(oldUpdate, newUpdate), listOf(newUpdate, oldUpdate))) {
                val entries = buildActivityEntries(cards)
                assertEquals(listOf("newer", "older"), entries.map { it.card.id })
                assertEquals(now.plusSeconds(index * 2L), entries.last().at)
                val cachedStart = ActivityDetail(oldUpdate.runtimeUpdatedAt, now.minusSeconds(7300), "Using a tool")
                assertEquals(entries.map { it.card.id }, buildActivityEntries(cards, mapOf("older" to cachedStart)).map { it.card.id })
            }
        }
        val restarted = older.toBuilder().setRuntimeUpdatedAt(now.toString()).build()
        assertEquals(listOf("older", "newer"), buildActivityEntries(listOf(newer, restarted)).map { it.card.id })
        val finished = restarted.toBuilder().setRuntime("idle").setRuntimeUpdatedAt(now.plusSeconds(1).toString()).build()
        assertFalse(buildActivityEntries(listOf(finished)).single().running)
        assertEquals(now.plusSeconds(1), buildActivityEntries(listOf(finished)).single().sortAt)
    }

    @Test fun `running rows with missing timestamps have stable fallback and tie order`() {
        val a = card("a", "running").toBuilder().setRuntimeUpdatedAt("bad").build()
        val b = a.toBuilder().setId("b").build()
        for (cards in listOf(listOf(a, b), listOf(b, a))) {
            for (updatedId in listOf("a", "b")) {
                val updated = cards.map { if (it.id == updatedId) it.toBuilder().setLastActivityAt(now.toString()).build() else it }
                assertEquals(listOf("a", "b"), buildActivityEntries(updated).map { it.card.id })
            }
        }
    }

    @Test fun `causal state beats later metadata timestamps in duplicate activity projections`() {
        fun versioned(value: Card, sequence: Long): Card = value.toBuilder()
            .addStateFields(CardStateField.newBuilder().setName("summary").setRevision("summary-$sequence")
                .addVersions(CardStateVersion.newBuilder().putClock("owner", sequence)
                    .setRank(sequence.toString()).setValue(value)))
            .addStateFields(CardStateField.newBuilder().setName("placement").setRevision("placement-$sequence")
                .addVersions(CardStateVersion.newBuilder().putClock("owner", sequence)
                    .setRank(sequence.toString()).setValue(value)))
            .build()
        for (scope in listOf("card", "chat")) {
            val running = versioned(card("one", "running", scope), 1)
                .toBuilder().setUpdatedAt(now.plusSeconds(60).toString()).setTitle("Renamed").build()
            val complete = versioned(card("one", "idle", scope, "review", ago = 30).toBuilder()
                .setResponseSeq(20).setSeenResponseSeq(20).build(), 2)
            for (copies in listOf(listOf(running, complete), listOf(complete, running), listOf(running, complete, running))) {
                val entry = buildActivityEntries(copies).single()
                assertFalse(entry.running)
                assertFalse(entry.needsYou)
                assertEquals("review", entry.card.lane)
                assertEquals("Renamed", entry.card.title)
                assertEquals(now.minusSeconds(30), entry.at)
            }
            val nextTurn = versioned(card("one", "running", scope, ago = 10), 3)
            assertTrue(buildActivityEntries(listOf(complete, nextTurn, running)).single().running)
        }
    }

    @Test fun `message and runtime timestamps compete but metadata edits never reset age`() {
        for (runtime in listOf("running", "idle", "waiting_for_user", "failed")) {
            val message = card("card", runtime).toBuilder()
                .setLastActivityAt(now.minusSeconds(120).toString())
                .setUpdatedAt(now.toString()).setPhaseChangedAt(now.toString()).build()
            assertEquals("2m", activityAge(buildActivityEntries(listOf(message)).single().at, now))
            val finished = message.toBuilder().setRuntimeUpdatedAt(now.minusSeconds(60).toString()).build()
            assertEquals("1m", activityAge(buildActivityEntries(listOf(finished)).single().at, now))
            val malformed = message.toBuilder().setRuntimeUpdatedAt("bad").build()
            assertEquals(now.minusSeconds(120), buildActivityEntries(listOf(malformed)).single().at)
            val unavailable = malformed.toBuilder().setLastActivityAt("bad").build()
            assertNull(buildActivityEntries(listOf(unavailable)).single().at)
        }
    }

    @Test fun `missing and malformed timestamps do not invent completed duration`() {
        val missing = card("missing", "failed").toBuilder().setRuntimeUpdatedAt("bad").build()
        assertNull(buildActivityEntries(listOf(missing)).single().at)
        assertTrue(activityTimeline(buildActivityEntries(listOf(missing)), now, 1).isEmpty())
        assertEquals("Time unavailable", activityAge(null, now))
        assertEquals(Destination.ACTIVITY, DieterUiState().destination)
    }
}
