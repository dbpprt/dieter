package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ScheduleEditorPolicyTest {
    @Test
    fun friendlyTimingProducesDaemonCron() {
        assertEquals("30 14 * * 1-5", scheduleCron("Weekdays", "14:30", "1", ""))
        assertEquals("5 8 * * *", scheduleCron("Daily", "08:05", "1", ""))
        assertEquals("45 16 * * 4", scheduleCron("Weekly", "16:45", "4", ""))
        assertEquals("*/10 * * * *", scheduleCron("Custom", "09:00", "1", "*/10 * * * *"))
        assertEquals("Weekly", scheduleRepeat("45 16 * * 4"))
        assertEquals("4", scheduleWeekday("45 16 * * 4"))
    }

    @Test
    fun templateInsertionAndRenderingUseAdvertisedPlaceholders() {
        val variables = mapOf(
            "date" to "2026-08-25",
            "scheduled_at" to "2026-08-25T07:00:00Z",
            "project" to "Dieter",
            "board" to "Main",
            "schedule" to "Morning",
        )
        assertEquals("Morning · 2026-08-25", renderScheduleTemplate("{{schedule}} · {{date}}", variables))
        assertEquals(
            "Work in Dieter / Main at 2026-08-25T07:00:00Z",
            renderScheduleTemplate("Work in {{project}} / {{board}} at {{scheduled_at}}", variables),
        )
        assertEquals("Daily {{date}}", appendScheduleVariable("Daily", "date"))
    }

    @Test
    fun runPreviewUsesTheScheduleTimezone() {
        assertEquals("Aug 25, 09:00", schedulePreviewLabel("2026-08-25T07:00:00Z", "Europe/Berlin"))
        assertEquals("Aug 25, 07:00", schedulePreviewLabel("2026-08-25T07:00:00Z", "UTC"))
    }
}
