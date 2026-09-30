package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardStateField
import com.dbpprt.dieter.api.v1.CardStateVersion
import kotlin.test.Test
import kotlin.test.assertEquals

// The cases shipped by both apps today: apps/android CardStateProjectionTest.kt
// and apps/mac CardStateProjectionTests.swift. They run on JVM, iOS, and macOS.
class CardStateProjectionTest {
    private fun card(lane: String, runtime: String, placement: Long, summary: Long): Card {
        val placementValue = Card(board_id = "board", lane = lane, order_key = "key-$placement")
        val summaryValue = Card(runtime = runtime, runtime_updated_at = "time-$summary", response_seq = summary, seen_response_seq = summary)
        fun field(name: String, count: Long, value: Card) = CardStateField(
            name = name, revision = "$name-$count",
            versions = listOf(CardStateVersion(clock = mapOf("owner" to count), rank = "$count", value_ = value)),
        )
        return Card(
            id = "card", owner_daemon_id = "owner", project_id = "project", board_id = "board", lane = lane, runtime = runtime,
            order_key = "key-$placement", placement_revision = "placement-$placement", runtime_updated_at = "time-$summary",
            state_fields = listOf(field("placement", placement, placementValue), field("summary", summary, summaryValue)),
        )
    }

    private fun List<Card>.fold() = drop(1).fold(first()) { merged, next -> mergeCardState(next, merged) }

    @Test
    fun delayedReplicasCannotReopenFinishedCardsOrRestoreOldRuntime() {
        val running = card("running", "running", 1, 1)
        val review = card("review", "idle", 2, 2)
        val done = card("done", "idle", 3, 3)
        for (sequence in listOf(listOf(running, review, done, running, review), listOf(done, review, running, done), listOf(review, running, done))) {
            val merged = sequence.fold()
            assertEquals("done", merged.lane)
            assertEquals("idle", merged.runtime)
            assertEquals(3L, merged.seen_response_seq)
            assertEquals(done.placement_revision, merged.placement_revision)
        }
        // A new placement must not carry an old runtime back into the UI.
        val mixed = mergeCardState(card("done", "running", 3, 1), review)
        assertEquals("done", mixed.lane)
        assertEquals("idle", mixed.runtime)
    }

    @Test
    fun concurrentBranchesRemainUntilAResolutionCoversBoth() {
        fun branch(lane: String, actor: String): Card {
            val base = card(lane, "idle", 2, 1)
            val version = base.state_fields[0].versions[0].copy(clock = mapOf("owner" to 1L, actor to 1L), rank = actor)
            return base.copy(state_fields = listOf(base.state_fields[0].copy(versions = listOf(version)), base.state_fields[1]))
        }
        val a = branch("review", "a")
        val b = branch("done", "b")
        val ab = mergeCardState(b, a)
        assertEquals(ab.state_fields, mergeCardState(a, b).state_fields)
        assertEquals("done", ab.lane)
        assertEquals(UNOBSERVED_JOIN, ab.placement_revision)
        assertEquals("done", mergeCardState(card("todo", "idle", 1, 1), ab).lane)

        val resolvedVersion = a.state_fields[0].versions[0].copy(clock = mapOf("owner" to 1L, "a" to 2L, "b" to 1L))
        val resolved = a.copy(state_fields = listOf(a.state_fields[0].copy(revision = "resolved", versions = listOf(resolvedVersion)), a.state_fields[1]))
        val latest = listOf(ab, resolved, b, a).fold()
        assertEquals("review", latest.lane)
        assertEquals("resolved", latest.placement_revision)
    }

    @Test
    fun clocksCompareAsUnsigned() {
        // uint64 counters above Long.MAX_VALUE arrive as negative Longs.
        val low = card("review", "idle", 1, 1)
        val highVersion = low.state_fields[0].versions[0].copy(clock = mapOf("owner" to -1L), rank = "9")
        val high = card("done", "idle", 2, 1).let {
            it.copy(state_fields = listOf(it.state_fields[0].copy(versions = listOf(highVersion.copy(value_ = it.state_fields[0].versions[0].value_))), it.state_fields[1]))
        }
        assertEquals("done", mergeCardState(low, high).lane)
    }
}
