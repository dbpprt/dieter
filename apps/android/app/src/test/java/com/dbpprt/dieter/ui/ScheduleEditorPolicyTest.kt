package com.dbpprt.dieter.ui

import java.time.Month
import java.time.format.TextStyle
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

/** Cron and template rules are core tests; the preview uses the device's date formatting. */
class ScheduleEditorPolicyTest {
    @Test
    fun runPreviewUsesTheScheduleTimezone() {
        val month = Month.AUGUST.getDisplayName(TextStyle.SHORT, Locale.getDefault())
        assertEquals("$month 25, 09:00", schedulePreviewLabel("2026-08-25T07:00:00Z", "Europe/Berlin"))
        assertEquals("$month 25, 07:00", schedulePreviewLabel("2026-08-25T07:00:00Z", "UTC"))
    }
}
