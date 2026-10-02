package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.ScheduleCadence
import com.dbpprt.dieter.client.v1.ScheduleEditorOptions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ScheduleExportsTest {
    private val weekdays = ScheduleCadence.Kind.KIND_WEEKDAYS.value
    private val weekly = ScheduleCadence.Kind.KIND_WEEKLY.value
    private val custom = ScheduleCadence.Kind.KIND_CUSTOM.value

    @Test
    fun aCronOpensInTheFriendlyEditor() {
        val cadence = ScheduleCadence.ADAPTER.decode(ScheduleCadence.ADAPTER.encode(ScheduleExports.cadence("45 16 * * 4")))
        assertEquals(
            ScheduleCadence(kind = ScheduleCadence.Kind.KIND_WEEKLY, hour = 16, minute = 45, weekday = 4, custom = "", cron = "45 16 * * 4", time = "16:45", summary = "Every Thursday at 16:45"),
            cadence,
        )
        val stepped = ScheduleExports.cadence(" */10 * * * * ")
        assertEquals(listOf(custom, 9, 0), listOf(stepped.kind.value, stepped.hour, stepped.minute))
        assertEquals(listOf("*/10 * * * *", "*/10 * * * *", "Custom schedule"), listOf(stepped.custom, stepped.cron, stepped.summary))
    }

    @Test
    fun choicesBuildTheCronTheDaemonReceives() {
        val cadence = ScheduleExports.cadenceOf(weekdays, 14, 30, 1, "")
        assertEquals(listOf("30 14 * * 1-5", "14:30", "Weekdays at 14:30"), listOf(cadence.cron, cadence.time, cadence.summary))
        val clamped = ScheduleExports.cadenceOf(weekly, 30, -2, 9, "")
        assertEquals(listOf("0 23 * * 1", 23, 0, 1), listOf(clamped.cron, clamped.hour, clamped.minute, clamped.weekday))
        assertEquals("*/5 * * * *", ScheduleExports.cadenceOf(custom, 9, 0, 1, " */5 * * * * ").cron)
        assertEquals(custom, ScheduleExports.cadenceOf(42, 9, 0, 1, "0 9 1 * *").kind.value, "an unknown kind is custom")
    }

    @Test
    fun switchingToCustomStartsFromTheCurrentCron() {
        val switched = ScheduleExports.cadenceSwitched(weekdays, 14, 30, 1, "", custom)
        assertEquals(listOf(custom, 14, 30), listOf(switched.kind.value, switched.hour, switched.minute))
        assertEquals("30 14 * * 1-5", switched.custom)
        assertEquals("30 14 * * 1-5", switched.cron)
        val back = ScheduleExports.cadenceSwitched(custom, 9, 0, 1, "*/10 * * * *", weekly)
        assertEquals(listOf("0 9 * * 1", "*/10 * * * *"), listOf(back.cron, back.custom), "the typed expression is kept for switching back")
    }

    @Test
    fun timingTimezonesTemplatesAndSaving() {
        assertEquals("Weekdays at 09:00 · Europe/Berlin", ScheduleExports.timing("0 9 * * 1-5", "Europe/Berlin"))
        assertEquals("Custom schedule", ScheduleExports.timing("*/10 * * * *", ""))
        assertEquals(listOf("Europe/Paris", "Europe/Berlin", "UTC", "Asia/Tokyo"), ScheduleExports.timezones("Europe/Paris", "Europe/Berlin", listOf("UTC", "Asia/Tokyo", "Europe/Paris")))
        assertEquals("Daily {{date}}", ScheduleExports.insertVariable("Daily", "date"))
        assertEquals("Morning in Project · 2026-08-25", ScheduleExports.templateExample("{{schedule}} in {{project}} · {{date}}", "Card title preview", "2026-08-25", "2026-08-25T07:00:00Z", "", "Main", "Morning"))
        assertEquals("Card title preview", ScheduleExports.templateExample(" ", "Card title preview", "2026-08-25", "2026-08-25T07:00:00Z", "Dieter", "Main", "Morning"))
        assertTrue(ScheduleExports.canSave("Nightly", "Title", "Prompt", "0 9 * * *", "UTC", "b", "worktree"))
        assertFalse(ScheduleExports.canSave("Nightly", "Title", "Prompt", "0 9 * * *", "UTC", "b", ""))
    }

    @Test
    fun theOptionsListEveryChoiceAndTheScreensWording() {
        val options = ScheduleEditorOptions.ADAPTER.decode(ScheduleEditorOptions.ADAPTER.encode(ScheduleExports.editorOptions()))
        assertEquals(listOf("Weekdays", "Daily", "Weekly", "Custom"), options.cadences.map { it.title })
        assertEquals(listOf("0", "1", "2", "3"), options.cadences.map { it.key })
        assertEquals(listOf("1", "2", "3", "4", "5", "6", "0"), options.weekdays.map { it.key })
        assertEquals(listOf("Mon", "Sunday"), listOf(options.weekdays.first().title, options.weekdays.last().detail))
        assertEquals(listOf("{{date}}", "{{scheduled_at}}", "{{project}}", "{{board}}", "{{schedule}}"), options.variables.map { it.title })
        assertEquals("Occurrence date in the schedule timezone", options.variables.first().detail)
        assertEquals(listOf("draft" to "Todo", "run" to "Running"), options.placements.map { it.key to it.title })
        assertEquals("The daemon creates a draft in Todo and waits for you to start it.", options.placements.first().detail)
        assertEquals(listOf("skip_if_open" to "Skip if open", "always" to "Always create"), options.open_policies.map { it.key to it.title })
        assertEquals("Missed occurrences are collapsed to the latest one after the daemon returns.", options.misfire_note)
        assertEquals(listOf("Card title preview", "Agent task preview"), listOf(options.title_placeholder, options.prompt_placeholder))
        assertEquals("Five fields: minute, hour, day of month, month, day of week.", options.cron_help)
        assertEquals(listOf("New schedule", "Edit schedule"), listOf(options.new_title, options.edit_title))
        assertEquals(listOf("No schedules", "Automate cards and chats with cron schedules."), listOf(options.empty_title, options.empty_detail))
        assertEquals(listOf("Load more schedules", "Loading…"), listOf(options.load_more, options.loading_more))
        assertEquals(
            listOf("Loading occurrences…", "No occurrences yet.", "Load older runs", "Loading older runs…"),
            listOf(options.runs_loading, options.runs_empty, options.load_older_runs, options.loading_older_runs),
        )
    }
}
