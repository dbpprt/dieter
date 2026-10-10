package com.dbpprt.dieter.core.schedules

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.EffortConfig
import com.dbpprt.dieter.api.v1.EffortOption
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.Label
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.api.v1.ScheduleRun
import com.dbpprt.dieter.client.v1.ScheduleRow
import com.dbpprt.dieter.client.v1.ScheduleRunRow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ScheduleRulesTest {
    @Test
    fun friendlyTimingProducesDaemonCron() {
        assertEquals("30 14 * * 1-5", Cadence(CadenceKind.WEEKDAYS, 14, 30).cron())
        assertEquals("5 8 * * *", Cadence(CadenceKind.DAILY, 8, 5).cron())
        assertEquals("45 16 * * 4", Cadence(CadenceKind.WEEKLY, 16, 45, weekday = 4).cron())
        assertEquals("*/10 * * * *", Cadence(CadenceKind.CUSTOM, custom = " */10 * * * * ").cron())
        assertEquals("0 23 * * 1", Cadence(CadenceKind.WEEKLY, 30, -2, weekday = 9).cron())
        // Ported from the Mac's scheduleTimingTurnsFriendlyChoicesIntoFiveFieldCron.
        val weekly = Cadence.parse("45 16 * * 4")
        assertEquals(Cadence(CadenceKind.WEEKLY, 16, 45, 4), weekly)
        assertEquals("45 16 * * 4", weekly.cron())
        assertEquals(CadenceKind.WEEKDAYS, Cadence.parse("0 9 * * 1-5").kind)
        assertEquals(Cadence(CadenceKind.DAILY, 8, 5), Cadence.parse("  5 8 * * *  "))
        assertEquals(
            CadenceKind.CUSTOM,
            Cadence.parse("*/10 * * * *").kind,
            "a stepped cron is never mistaken for a daily one",
        )
        assertEquals(CadenceKind.CUSTOM, Cadence.parse("0 9 1 * *").kind)
        assertEquals(
            "0 9 * * *",
            Cadence.parse("00 09 * * *").cron(),
            "zero-padded fields read as numbers",
        )
    }

    @Test
    fun onlyExpressionsTheDaemonAcceptsAreFriendly() {
        assertEquals(
            CadenceKind.CUSTOM,
            Cadence.parse("0 9 * * 1-5 x").kind,
            "the daemon takes exactly five fields",
        )
        assertEquals(
            CadenceKind.CUSTOM,
            Cadence.parse("0 0 9 * * 1-5").kind,
            "the daemon has no seconds field",
        )
        assertEquals(
            CadenceKind.CUSTOM,
            Cadence.parse("0 9 * * 7").kind,
            "the daemon's days of week are 0-6",
        )
        assertEquals(CadenceKind.CUSTOM, Cadence.parse("TZ=UTC 0 9 * * *").kind)
        assertEquals(CadenceKind.CUSTOM, Cadence.parse("@daily").kind)
        assertEquals(CadenceKind.CUSTOM, Cadence.parse("0 9 * * MON-FRI").kind)
        assertEquals(
            Cadence(CadenceKind.CUSTOM, 9, 0, 1, "75 9 * * *"),
            Cadence.parse("75 9 * * *"),
            "an out-of-range minute is never clamped into another time",
        )
        assertEquals(
            Cadence(CadenceKind.CUSTOM, 9, 0, 1, "0 25 * * *"),
            Cadence.parse("0 25 * * *"),
        )
        assertEquals(
            Cadence(CadenceKind.CUSTOM, 14, 30, 1, "30 14 1 * *"),
            Cadence.parse("30 14 1 * *"),
            "a custom expression keeps its time",
        )
        assertEquals(Cadence(CadenceKind.CUSTOM, 9, 0, 1, ""), Cadence.parse(""))
    }

    @Test
    fun summariesReadAsSentencesWithTheirZone() {
        assertEquals(
            "Weekdays at 09:00 · Europe/Berlin",
            Cadence.timing("0 9 * * 1-5", "Europe/Berlin"),
        )
        assertEquals("Every day at 08:05 · UTC", Cadence.timing("5 8 * * *", "UTC"))
        assertEquals("Every Thursday at 16:45 · UTC", Cadence.timing("45 16 * * 4", "UTC"))
        assertEquals("Every Sunday at 09:00", Cadence.timing("0 9 * * 0", ""))
        assertEquals("Custom schedule · UTC", Cadence.timing("*/10 * * * *", "UTC"))
        assertEquals("Weekdays at 09:00", Cadence(CadenceKind.WEEKDAYS).summary())
        assertEquals(
            "Custom schedule",
            Cadence(CadenceKind.CUSTOM, custom = "*/5 * * * *").summary(),
        )
    }

    @Test
    fun switchingToCustomStartsFromTheCurrentTiming() {
        val weekdays = Cadence.parse(ScheduleDrafts.DEFAULT_CRON).copy(hour = 14, minute = 30)
        val custom = weekdays.withKind(CadenceKind.CUSTOM)
        assertEquals("30 14 * * 1-5", custom.custom)
        assertEquals("30 14 * * 1-5", custom.cron())
        assertEquals("30 14 * * 4", custom.withKind(CadenceKind.WEEKLY).copy(weekday = 4).cron())
        val typed =
            Cadence.parse("*/10 * * * *").withKind(CadenceKind.DAILY).withKind(CadenceKind.CUSTOM)
        assertEquals(
            "*/10 * * * *",
            typed.cron(),
            "an entered expression survives switching away and back",
        )
    }

    @Test
    fun weekdaysRunMondayFirstWithCronNumbers() {
        assertEquals(listOf(1, 2, 3, 4, 5, 6, 0), Cadence.WEEKDAY_ORDER)
        assertEquals(
            listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"),
            Cadence.WEEKDAY_ORDER.map { Cadence.weekdayShortName(it) },
        )
        assertEquals("Monday", Cadence.WEEKDAYS.first().second)
        assertEquals(0 to "Sunday", Cadence.WEEKDAYS.last())
        assertEquals("Mon", Cadence.weekdayShortName(9))
        assertEquals("Monday", Cadence.weekdayName(-1))
    }

    @Test
    fun templatesRenderAndInsertAdvertisedPlaceholders() {
        val values =
            mapOf(
                "date" to "2026-08-25",
                "scheduled_at" to "2026-08-25T07:00:00Z",
                "project" to "Dieter",
                "board" to "Main",
                "schedule" to "Nightly",
            )
        assertEquals(
            "2026-08-25 2026-08-25T07:00:00Z Dieter Main Nightly {{unknown}}",
            ScheduleTemplates.render(
                "{{date}} {{scheduled_at}} {{project}} {{board}} {{schedule}} {{unknown}}",
                values,
            ),
        )
        assertEquals("Daily {{date}}", ScheduleTemplates.insert("Daily", "date"))
        assertEquals("Daily {{date}}", ScheduleTemplates.insert("Daily ", "date"))
        assertEquals("{{board}}", ScheduleTemplates.insert("", "board"))
        assertEquals(
            listOf("{{date}}", "{{scheduled_at}}", "{{project}}", "{{board}}", "{{schedule}}"),
            ScheduleTemplates.VARIABLES.map(ScheduleTemplates::token),
        )
        // Ported from the Mac's scheduleTemplatePreviewMatchesDaemonVariableSyntax.
        val morning = values + ("schedule" to "Morning")
        assertEquals(
            "Morning · 2026-08-25",
            ScheduleTemplates.render("{{schedule}} · {{date}}", morning),
        )
        assertEquals(
            "Work in Dieter / Main at 2026-08-25T07:00:00Z",
            ScheduleTemplates.render(
                "Work in {{project}} / {{board}} at {{scheduled_at}}",
                morning,
            ),
        )
    }

    @Test
    fun theTemplateExampleFillsBlankNamesAndEmptyOutput() {
        val values =
            ScheduleTemplates.exampleValues(" ", null, "", "2026-08-25T07:00:00Z", "2026-08-25")
        assertEquals(
            "Project / Board / Schedule · 2026-08-25",
            ScheduleTemplates.render("{{project}} / {{board}} / {{schedule}} · {{date}}", values),
        )
        assertEquals(
            "Card title preview",
            ScheduleTemplates.example("  ", values, ScheduleTemplates.TITLE_PLACEHOLDER),
        )
        assertEquals(
            "Agent task preview",
            ScheduleTemplates.example("", values, ScheduleTemplates.PROMPT_PLACEHOLDER),
        )
        assertEquals(
            "Review Project",
            ScheduleTemplates.example(
                "Review {{project}}",
                values,
                ScheduleTemplates.PROMPT_PLACEHOLDER,
            ),
        )
        assertEquals("Occurrence date in the schedule timezone", ScheduleTemplates.help("date"))
        assertEquals(
            ScheduleTemplates.VARIABLES.size,
            ScheduleTemplates.VARIABLES.map(ScheduleTemplates::help).toSet().size,
            "every placeholder has its own help",
        )
        assertEquals("unknown", ScheduleTemplates.help("unknown"))
    }

    @Test
    fun scheduleDraftsNormalizeMissingAndRetiredValues() {
        val boards = listOf(Board(id = "b1", labels = listOf(Label(id = "l1"))), Board(id = "b2"))
        val fresh =
            ScheduleDrafts.make(
                null,
                "p",
                "Europe/Berlin",
                boards,
                selectedBoardId = "b2",
                harnesses = emptyList(),
            )
        assertEquals("0 9 * * 1-5", fresh.cron)
        assertEquals("Europe/Berlin", fresh.timezone)
        assertEquals("Scheduled work · {{date}}", fresh.title_template)
        assertTrue(fresh.enabled)
        assertEquals("b2", fresh.board_id)
        assertEquals("draft", fresh.action)
        assertEquals("skip_if_open", fresh.open_card_policy)
        assertEquals("latest", fresh.misfire_policy)
        assertEquals("worktree", fresh.workspace_mode)
        assertEquals("", fresh.provider, "without agents a draft starts without one")
        val stored =
            ScheduleDrafts.make(
                Schedule(
                    id = "s",
                    board_id = "gone",
                    action = "run",
                    open_card_policy = "always",
                    workspace_mode = "",
                ),
                "p",
                "UTC",
                boards,
                null,
                emptyList(),
            )
        assertEquals("b1", stored.board_id)
        assertEquals("run", stored.action)
        assertEquals("always", stored.open_card_policy)
        assertEquals(
            "project",
            stored.workspace_mode,
            "an existing schedule without a mode runs in the project",
        )
        assertFalse(ScheduleDrafts.canSave(fresh))
        assertTrue(ScheduleDrafts.canSave(fresh.copy(name = "Nightly", prompt_template = "Do it")))
        assertEquals(
            listOf("l1"),
            ScheduleDrafts.onBoard(fresh.copy(label_ids = listOf("l1", "l2")), boards[0]).label_ids,
        )
        assertEquals(
            listOf("Europe/Berlin", "America/New_York", "UTC"),
            ScheduleDrafts.timezoneOptions("Europe/Berlin", "America/New_York", listOf("UTC")),
        )
        assertEquals(
            listOf(
                "Europe/Paris",
                "Europe/Berlin",
                "UTC",
                "America/New_York",
                "asia/tokyo",
                "Europe/London",
            ),
            ScheduleDrafts.timezoneOptions(
                "Europe/Paris",
                "Europe/Berlin",
                listOf("Europe/London", "asia/tokyo", "UTC", "America/New_York", ""),
            ),
            "the selection, device zone, and UTC lead; the rest sort case-insensitively",
        )
        assertEquals(
            listOf("Europe/Berlin", "UTC"),
            ScheduleDrafts.timezoneOptions("", "Europe/Berlin", emptyList()),
        )
    }

    @Test
    fun anExistingScheduleLoadsEveryEditableField() {
        // Ported from the Mac's testScheduleEditorLoadsEveryEditableScheduleField.
        val schedule =
            Schedule(
                id = "s",
                checkout_id = "c1",
                project_id = "project",
                board_id = "board",
                name = "Morning review",
                description = "Review the project",
                cron = "15 8 * * 1",
                timezone = "Europe/Berlin",
                enabled = false,
                action = "run",
                title_template = "Review · {{date}}",
                prompt_template = "Review {{project}}",
                provider = "codex",
                model = "gpt-5.6-sol",
                effort = "high",
                label_ids = listOf("label_mac"),
                open_card_policy = "always",
                misfire_policy = "latest",
                provider_options = mapOf("personality" to "pragmatic"),
                vault_access = true,
            )
        val agents =
            listOf(
                Harness(
                    id = "claude",
                    default_model = "opus",
                    models = listOf(HarnessModel(id = "opus")),
                )
            )
        val draft =
            ScheduleDrafts.make(
                schedule,
                "project",
                "UTC",
                listOf(Board(id = "board")),
                null,
                agents,
            )
        val expected =
            ScheduleDraft(
                checkout_id = "c1",
                project_id = "project",
                board_id = "board",
                name = "Morning review",
                description = "Review the project",
                cron = "15 8 * * 1",
                timezone = "Europe/Berlin",
                enabled = false,
                action = "run",
                title_template = "Review · {{date}}",
                prompt_template = "Review {{project}}",
                provider = "codex",
                model = "gpt-5.6-sol",
                effort = "high",
                label_ids = listOf("label_mac"),
                open_card_policy = "always",
                misfire_policy = "latest",
                provider_options = mapOf("personality" to "pragmatic"),
                workspace_mode = "project",
                vault_access = true,
            )
        assertEquals(expected, draft, "a saved agent is kept even when the machine offers others")
    }

    @Test
    fun aDraftWithoutAnAgentGetsTheMachinesFirst() {
        val codex =
            Harness(
                id = "codex",
                default_model = "sol",
                models =
                    listOf(
                        HarnessModel(id = "spark", default_effort = "low"),
                        HarnessModel(id = "sol", default_effort = "high"),
                    ),
            )
        val fresh =
            ScheduleDrafts.make(
                null,
                "p",
                "UTC",
                emptyList(),
                null,
                listOf(codex, Harness(id = "claude")),
            )
        assertEquals(
            listOf("codex", "sol", "high"),
            listOf(fresh.provider, fresh.model, fresh.effort),
        )
        assertEquals("", fresh.board_id, "a project without boards has no board yet")
        val stale = codex.copy(default_model = "retired")
        val fallback = ScheduleDrafts.make(null, "p", "UTC", emptyList(), null, listOf(stale))
        assertEquals(
            listOf("codex", "spark", "low"),
            listOf(fallback.provider, fallback.model, fallback.effort),
            "a missing default model falls back to the first",
        )
        val unassigned =
            ScheduleDrafts.make(
                Schedule(id = "s", provider = "", model = "", effort = ""),
                "p",
                "UTC",
                emptyList(),
                null,
                listOf(codex),
            )
        assertEquals(
            listOf("codex", "sol", "high"),
            listOf(unassigned.provider, unassigned.model, unassigned.effort),
            "an existing schedule without an agent gets one too",
        )
    }

    @Test
    fun savingNeedsEveryRequiredField() {
        assertTrue(
            ScheduleDrafts.canSave(
                "Nightly",
                "Title",
                "Prompt",
                "0 9 * * *",
                "UTC",
                "b",
                "worktree",
            )
        )
        assertFalse(
            ScheduleDrafts.canSave("  ", "Title", "Prompt", "0 9 * * *", "UTC", "b", "worktree")
        )
        assertFalse(
            ScheduleDrafts.canSave("Nightly", "Title", " \n", "0 9 * * *", "UTC", "b", "worktree")
        )
        assertFalse(
            ScheduleDrafts.canSave("Nightly", "Title", "Prompt", " ", "UTC", "b", "worktree")
        )
        assertFalse(
            ScheduleDrafts.canSave("Nightly", "Title", "Prompt", "0 9 * * *", " ", "b", "worktree")
        )
        assertFalse(
            ScheduleDrafts.canSave("Nightly", "Title", "Prompt", "0 9 * * *", "UTC", "", "worktree")
        )
        assertFalse(
            ScheduleDrafts.canSave("Nightly", "Title", "Prompt", "0 9 * * *", "UTC", "b", "")
        )
        val normalized =
            ScheduleDrafts.normalized(
                ScheduleDraft(
                    name = " Nightly ",
                    cron = " 0 9 * * * ",
                    label_ids = listOf("b", "a"),
                    misfire_policy = "",
                ),
                "p",
                "c",
            )
        assertEquals(
            listOf("Nightly", "0 9 * * *", "latest", "p", "c"),
            listOf(
                normalized.name,
                normalized.cron,
                normalized.misfire_policy,
                normalized.project_id,
                normalized.checkout_id,
            ),
        )
        assertEquals(listOf("a", "b"), normalized.label_ids)
    }

    @Test
    fun placementsReadAsTheirLanes() {
        // Ported from the Mac's ScheduleActionPresentation assertions.
        assertEquals("Todo", ScheduleDrafts.placementTitle("draft"))
        assertEquals("Running", ScheduleDrafts.placementTitle("run"))
        assertEquals("Todo", ScheduleDrafts.placementTitle(""))
        assertEquals(
            "The daemon creates the card and starts its agent turn when admission allows.",
            ScheduleDrafts.placementDetail("run"),
        )
        assertEquals(
            "The daemon creates a draft in Todo and waits for you to start it.",
            ScheduleDrafts.placementDetail("draft"),
        )
    }

    @Test
    fun theListNeverClaimsEmptyBeforeItLoaded() {
        // Ported from the Mac's
        // schedulesDoNotPresentAnAuthoritativeEmptyStateBeforeLoadingCompletes and its failed-load
        // check.
        assertEquals(
            SchedulesPresentation.LOADING,
            SchedulePresentations.resolve(
                loaded = false,
                loading = false,
                hasSchedules = false,
                error = null,
            ),
        )
        assertEquals(
            SchedulesPresentation.LOADING,
            SchedulePresentations.resolve(
                loaded = true,
                loading = true,
                hasSchedules = false,
                error = null,
            ),
        )
        assertEquals(
            SchedulesPresentation.EMPTY,
            SchedulePresentations.resolve(
                loaded = true,
                loading = false,
                hasSchedules = false,
                error = null,
            ),
        )
        assertEquals(
            SchedulesPresentation.LOADED,
            SchedulePresentations.resolve(
                loaded = true,
                loading = true,
                hasSchedules = true,
                error = null,
            ),
        )
        assertEquals(
            SchedulesPresentation.FAILED,
            SchedulePresentations.resolve(
                loaded = true,
                loading = false,
                hasSchedules = false,
                error = "x",
            ),
        )
        assertEquals(
            SchedulesPresentation.FAILED,
            SchedulePresentations.resolve(
                loaded = false,
                loading = false,
                hasSchedules = false,
                error = "x",
            ),
        )
        assertEquals(
            SchedulesPresentation.LOADING,
            SchedulePresentations.resolve(
                loaded = false,
                loading = true,
                hasSchedules = false,
                error = "x",
            ),
            "a retry shows progress",
        )
        assertEquals(
            SchedulesPresentation.LOADED,
            SchedulePresentations.resolve(
                loaded = true,
                loading = false,
                hasSchedules = true,
                error = "x",
            ),
            "a failed reload keeps the list",
        )
        assertEquals(
            "1 automation",
            SchedulePresentations.subtitle(loaded = true, totalCount = 1, error = null),
        )
        assertEquals(
            "3 automations",
            SchedulePresentations.subtitle(loaded = true, totalCount = 3, error = "x"),
        )
        assertEquals(
            "0 automations",
            SchedulePresentations.subtitle(loaded = true, totalCount = 0, error = null),
        )
        assertEquals(
            "Loading automations…",
            SchedulePresentations.subtitle(loaded = false, totalCount = 0, error = null),
        )
        assertEquals(
            "Automations unavailable",
            SchedulePresentations.subtitle(loaded = false, totalCount = 0, error = "x"),
        )
    }

    @Test
    fun rowsCarryTimingPlacementAndStatus() {
        val running =
            Schedule(
                id = "a",
                cron = "0 9 * * 1-5",
                timezone = "Europe/Berlin",
                enabled = true,
                action = "run",
            )
        assertEquals(
            ScheduleRow(
                id = "a",
                timing = "Weekdays at 09:00 · Europe/Berlin",
                placement = "Running",
                status = "Enabled",
                subtitle =
                    "The daemon creates the card and starts its agent turn when admission allows.",
                next_run_fallback = "No next run",
                provider_label = "Agent",
                model_label = "Default model",
                effort_label = "Default",
            ),
            SchedulePresentations.row(running),
        )
        val paused =
            Schedule(
                id = "b",
                cron = "*/10 * * * *",
                timezone = "UTC",
                enabled = false,
                action = "draft",
                description = " Triage ",
                next_run_at = "2026-08-25T07:00:00Z",
            )
        assertEquals(
            ScheduleRow(
                id = "b",
                timing = "Custom schedule · UTC",
                placement = "Todo",
                status = "Paused",
                subtitle = "Triage",
                next_run_fallback = "",
                provider_label = "Agent",
                model_label = "Default model",
                effort_label = "Default",
            ),
            SchedulePresentations.row(paused),
        )
    }

    @Test
    fun rowsNameTheAgentByTheOwnersCatalog() {
        val schedule =
            Schedule(
                id = "a",
                cron = "0 9 * * *",
                provider = "codex",
                model = "sol",
                effort = "high",
                owner_daemon_id = "d1",
            )
        val codex =
            Harness(
                id = "codex",
                name = "Codex",
                models =
                    listOf(HarnessModel(id = "sol", name = "Sol", efforts = listOf("low", "high"))),
                effort = EffortConfig(options = listOf(EffortOption("high", "High effort"))),
            )
        val named = SchedulePresentations.row(schedule, listOf(codex))
        assertEquals(
            listOf("Codex", "Sol", "High effort"),
            listOf(named.provider_label, named.model_label, named.effort_label),
        )
        val raw = SchedulePresentations.row(schedule)
        assertEquals(
            listOf("codex", "sol", "High"),
            listOf(raw.provider_label, raw.model_label, raw.effort_label),
            "without a catalog the IDs show",
        )
        assertEquals(
            "Default",
            SchedulePresentations.row(schedule.copy(effort = "default"), listOf(codex))
                .effort_label,
        )
        val view = SchedulesView(projectId = "p", loaded = true, schedules = listOf(schedule))
        assertEquals(
            listOf("Codex"),
            view.rows { if (it == "d1") listOf(codex) else emptyList() }.map { it.provider_label },
        )
    }

    @Test
    fun runsReadTheirStatusToneAndTrigger() {
        val labels =
            listOf(
                "pending",
                "starting",
                "running",
                "completed",
                "interrupted",
                "failed",
                "skipped",
                "cancelled",
                "",
                "needs_input",
                "FAILED",
            )
        assertEquals(
            listOf(
                "Pending",
                "Starting",
                "Running",
                "Completed",
                "Interrupted",
                "Failed",
                "Skipped",
                "Cancelled",
                "Unknown",
                "Needs input",
                "Failed",
            ),
            labels.map(SchedulePresentations::runStatus),
        )
        assertEquals(
            listOf(
                ScheduleRunRow.Tone.TONE_NEUTRAL,
                ScheduleRunRow.Tone.TONE_ACTIVE,
                ScheduleRunRow.Tone.TONE_ACTIVE,
                ScheduleRunRow.Tone.TONE_SUCCESS,
                ScheduleRunRow.Tone.TONE_NEUTRAL,
                ScheduleRunRow.Tone.TONE_FAILURE,
                ScheduleRunRow.Tone.TONE_NEUTRAL,
                ScheduleRunRow.Tone.TONE_FAILURE,
                ScheduleRunRow.Tone.TONE_NEUTRAL,
                ScheduleRunRow.Tone.TONE_NEUTRAL,
                ScheduleRunRow.Tone.TONE_FAILURE,
            ),
            labels.map(SchedulePresentations::runTone),
        )
        val manual =
            ScheduleRun(
                id = "r1",
                status = "completed",
                manual = true,
                scheduled_for = "2026-08-25T07:00:00Z",
                created_at = "2026-08-25T07:00:01Z",
                message = "done",
                card_id = "c",
            )
        assertEquals(
            ScheduleRunRow(
                id = "r1",
                status = "Completed",
                tone = ScheduleRunRow.Tone.TONE_SUCCESS,
                trigger = "Manual",
                at = "2026-08-25T07:00:00Z",
                message = "done",
                card_id = "c",
            ),
            SchedulePresentations.runRow(manual),
        )
        val skipped =
            SchedulePresentations.runRow(
                ScheduleRun(id = "r2", status = "skipped", created_at = "2026-08-25T07:00:01Z")
            )
        assertEquals(
            listOf("Scheduled", "2026-08-25T07:00:01Z", ""),
            listOf(skipped.trigger, skipped.at, skipped.card_id),
        )
    }

    @Test
    fun theViewShowsRowsInListOrder() {
        val view =
            SchedulesView(
                projectId = "p",
                loaded = true,
                totalCount = 2,
                schedules =
                    listOf(
                        Schedule(id = "a", cron = "5 8 * * *", timezone = "UTC"),
                        Schedule(id = "b", cron = "0 9 * * 1-5"),
                    ),
                runs = listOf(ScheduleRun(id = "r", status = "failed")),
            )
        assertEquals(listOf("a", "b"), view.rows().map { it.id })
        assertEquals(
            listOf("Every day at 08:05 · UTC", "Weekdays at 09:00"),
            view.rows().map { it.timing },
        )
        assertEquals(listOf("Failed"), view.runRows.map { it.status })
        assertEquals("2 automations", view.subtitle)
        assertEquals(SchedulesPresentation.LOADED, view.presentation)
    }
}
