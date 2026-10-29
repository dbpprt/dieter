package com.getdieter.core.client

import com.getdieter.api.v1.Card
import com.getdieter.core.activity.Activity
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Instant

class ActivitySliceTest {
    @Test
    fun pinsLeadFeedWithoutChangingActivityOrDuplicatingRows() {
        val cards =
            listOf(
                Card(id = "new", runtime = "running", runtime_updated_at = "2026-10-16T12:00:00Z"),
                Card(id = "old", runtime = "failed", runtime_updated_at = "2026-10-15T12:00:00Z"),
                Card(id = "archived", runtime = "failed", archived = true),
            )
        val items = Activity.project(cards, emptyMap(), emptyList(), emptyList())
        val now = Instant.parse("2026-10-16T13:00:00Z")
        val pinned = activitySlice(items, now, setOf("old", "archived", "unknown"))
        assertEquals(listOf("old", "new"), pinned.rows.map { it.card?.id })
        assertTrue(pinned.rows.first().pinned)
        val unpinned = activitySlice(items, now)
        assertEquals(listOf("new", "old"), unpinned.rows.map { it.card?.id })
        assertEquals(unpinned.summary, pinned.summary)
        assertEquals(unpinned.island_ids, pinned.island_ids)
    }

    @Test
    fun hiddenCountsReportWhatTheInboxRulesLeftOut() {
        val items =
            Activity.project(
                listOf(Card(id = "x", runtime = "running")),
                emptyMap(),
                emptyList(),
                emptyList(),
            )
        assertEquals(0, activitySlice(items, Instant.parse("2026-10-16T13:00:00Z")).summary?.hidden)
        assertEquals(
            3,
            activitySlice(items, Instant.parse("2026-10-16T13:00:00Z"), hidden = 3).summary?.hidden,
        )
    }
}
