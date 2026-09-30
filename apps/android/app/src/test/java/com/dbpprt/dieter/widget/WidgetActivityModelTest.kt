package com.dbpprt.dieter.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** The widget formats the last sync as an absolute local time; the core owns the wording. */
class WidgetActivityModelTest {
    private val now = Instant.parse("2026-09-26T10:00:00Z")

    @Test fun offlineTimestampRemainsHonestWithoutAHostRefresh() {
        val first = widgetStatusText(now.toEpochMilli(), false)
        assertTrue(first.startsWith("Offline · updated "))
        assertEquals(first, widgetStatusText(now.toEpochMilli(), false))
        assertEquals("Not synced yet", widgetStatusText(0, false))
    }
}
