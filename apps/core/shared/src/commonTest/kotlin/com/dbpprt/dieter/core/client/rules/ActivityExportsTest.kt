package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.ActivityTimelineBar
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant

class ActivityExportsTest {
    private val now = Instant.parse("2026-09-30T12:00:00Z").toEpochMilliseconds()
    private val minute = 60_000L
    private val hour = 60 * minute

    @Test
    fun searchUsesTheInboxFilter() {
        assertTrue(ActivityExports.activityMatches(" train", "Ship it", "", "Release train"))
        assertTrue(ActivityExports.activityMatches("", "x", "", ""))
        assertFalse(ActivityExports.activityMatches("gateway", "Ship it", "Dieter", ""))
    }

    @Test
    fun untitledConversationsAreNamedByKind() {
        assertEquals("Ship it", ActivityExports.conversationTitle("Ship it", "card", "b1"))
        assertEquals("Untitled chat", ActivityExports.conversationTitle(" ", "chat", ""))
        assertEquals("Untitled card", ActivityExports.conversationTitle("", "chat", "b1"), "a chat filed on a board is a card")
    }

    @Test
    fun timelineBarsUseFractionsOfTheWindow() {
        val bar = ActivityExports.timelineBar(now - 2 * hour, now - minute, running = false, nowMillis = now, hours = 1)
        assertEquals(ActivityTimelineBar(shown = true, start_fraction = 0.0, end_fraction = 3540.0 / 3600, point = false), bar)
        assertEquals(ActivityTimelineBar(shown = true, start_fraction = 0.5, end_fraction = 0.5, point = true), ActivityExports.timelineBar(0, now - hour / 2, false, now, 1))
        assertEquals(1.0, ActivityExports.timelineBar(now - minute, 0, running = true, nowMillis = now, hours = 6).end_fraction, "running work reaches now")
        assertEquals(ActivityTimelineBar(), ActivityExports.timelineBar(0, now - 2 * hour, false, now, 1), "outside the window")
        assertEquals(ActivityTimelineBar(), ActivityExports.timelineBar(0, 0, false, now, 1), "no time")
    }
}
