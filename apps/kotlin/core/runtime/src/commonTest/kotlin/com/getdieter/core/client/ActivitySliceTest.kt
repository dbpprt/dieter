package com.getdieter.core.client

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Subagent
import com.getdieter.client.v1.ActivityRow.Section
import com.getdieter.core.activity.Activity
import com.getdieter.core.activity.InboxSection
import com.getdieter.core.activity.InboxStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant

class ActivitySliceTest {
    private val now = Instant.parse("2026-10-16T13:00:00Z")

    private fun card(
        id: String,
        runtime: String,
        at: String,
        lane: String = "todo",
        summary: String = "",
        activity: String = at,
        subagents: Int = 0,
    ) =
        Card(
            id = id,
            title = id,
            board_id = "b",
            lane = lane,
            runtime = runtime,
            summary = summary,
            initial_prompt_sent_at = "2026-10-16T08:00:00Z",
            runtime_updated_at = "2026-10-16T${at}:00Z",
            last_activity_at = "2026-10-16T${activity}:00Z",
            active_subagents = List(subagents) { Subagent(status = "running") },
        )

    private val cards =
        listOf(
            card("ask", "waiting_for_user", "12:30", summary = "Tag it stable now,\n  or keep it?"),
            card("fail", "failed", "11:00", summary = "disk full"),
            // Streaming moves its latest activity, never its place: it sorts by its turn start.
            card("run-old", "running", "10:00", activity = "12:59", subagents = 3),
            card("run-new", "running", "12:00"),
            card("pin-idle", "idle", "09:00"),
            card("rev", "idle", "12:45", lane = "review"),
            card("done", "idle", "12:50"),
        )

    private val items = Activity.project(cards, emptyMap(), emptyList(), emptyList())

    @Test
    fun rowsComeInSectionOrderNewestFirstWithinEachAndPinsStayInTheirSection() {
        val pins = setOf("fail", "run-new", "pin-idle", "archived", "unknown")
        val slice = activitySlice(items, now, pins)
        assertEquals(
            listOf("ask", "fail", "run-new", "run-old", "pin-idle", "done", "rev"),
            slice.rows.map { it.card?.id },
        )
        assertEquals(
            listOf(
                Section.SECTION_ATTENTION,
                Section.SECTION_ATTENTION,
                Section.SECTION_RUNNING,
                Section.SECTION_RUNNING,
                Section.SECTION_PINNED,
                Section.SECTION_RECENT,
                Section.SECTION_RECENT,
            ),
            slice.rows.map { it.section },
        )
        val rows = slice.rows.associateBy { it.card!!.id }
        assertTrue(rows.getValue("fail").pinned, "a pinned failure stays in Needs you")
        assertTrue(rows.getValue("fail").needs_you)
        assertTrue(rows.getValue("run-new").pinned)
        assertFalse(rows.getValue("run-old").pinned)

        val unpinned = activitySlice(items, now)
        assertEquals(
            listOf("ask", "fail", "run-new", "run-old", "done", "rev", "pin-idle"),
            unpinned.rows.map { it.card?.id },
            "without its pin an idle row is recent, by its latest activity",
        )
        assertTrue(unpinned.rows.none { it.section == Section.SECTION_PINNED })
        assertEquals(unpinned.summary, slice.summary)
        assertEquals(unpinned.island_ids, slice.island_ids)
    }

    @Test
    fun rowsCarryTheirPreviewAgentsAndTheSummaryItsHeadline() {
        val rows = activitySlice(items, now).rows.associateBy { it.card!!.id }
        assertEquals("Tag it stable now, or keep it?", rows.getValue("ask").preview)
        assertEquals("Agent failed: disk full", rows.getValue("fail").preview)
        assertEquals("Working on your request", rows.getValue("run-old").preview)
        assertEquals("Ready for review", rows.getValue("rev").preview)
        assertEquals("Finished", rows.getValue("done").preview)
        assertEquals("3 agents", rows.getValue("run-old").agents)
        assertEquals("", rows.getValue("run-new").agents)
        assertTrue(rows.getValue("fail").can_finish, "a failed card can be finished")
        assertEquals("2 need you · 2 running", activitySlice(items, now).summary?.headline)
        assertEquals("All caught up", activitySlice(emptyList(), now).summary?.headline)
    }

    @Test
    fun statusFiltersNarrowRowsAndKeepTheirSections() {
        val rows = activitySlice(items, now, setOf("fail", "run-new", "pin-idle")).rows
        assertEquals(
            mapOf(
                InboxStatus.ALL to 7,
                InboxStatus.NEEDS_YOU to 2,
                InboxStatus.RUNNING to 2,
                InboxStatus.PINNED to 3,
                InboxStatus.REVIEW to 1,
            ),
            InboxStatus.counts(rows),
        )
        val pinned = rows.filter(InboxStatus.PINNED::matches)
        assertEquals(
            listOf(
                InboxSection.NEEDS_YOU to listOf("fail"),
                InboxSection.RUNNING to listOf("run-new"),
                InboxSection.PINNED to listOf("pin-idle"),
            ),
            InboxSection.group(pinned).map { (section, group) ->
                section to group.map { it.card!!.id }
            },
            "Pinned matches every pin, each in its own section",
        )
        assertEquals(InboxStatus.REVIEW, InboxStatus.named("REVIEW"))
        assertEquals(InboxStatus.ALL, InboxStatus.named("bogus"))
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
        assertEquals(0, activitySlice(items, now).summary?.hidden)
        assertEquals(3, activitySlice(items, now, hidden = 3).summary?.hidden)
    }
}
