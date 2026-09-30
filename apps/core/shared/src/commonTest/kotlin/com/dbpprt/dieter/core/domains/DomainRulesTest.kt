package com.dbpprt.dieter.core.domains

import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import com.dbpprt.dieter.api.gateway.v1.ProviderResetCredits
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Execution
import com.dbpprt.dieter.api.v1.ExecutionEvent
import com.dbpprt.dieter.api.v1.ExecutionStream
import com.dbpprt.dieter.api.v1.Label
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.core.executions.Processes
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.core.quotas.QuotaLevel
import com.dbpprt.dieter.core.quotas.Quotas
import com.dbpprt.dieter.core.schedules.Cadence
import com.dbpprt.dieter.core.schedules.CadenceKind
import com.dbpprt.dieter.core.schedules.ScheduleDrafts
import com.dbpprt.dieter.core.schedules.SchedulePresentations
import com.dbpprt.dieter.core.schedules.ScheduleTemplates
import com.dbpprt.dieter.core.schedules.SchedulesPresentation
import com.dbpprt.dieter.core.search.ListFilters
import com.dbpprt.dieter.core.search.SearchDocument
import com.dbpprt.dieter.core.search.TaskSearchIndex
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

class DomainRulesTest {
    @Test
    fun friendlyTimingProducesDaemonCron() {
        assertEquals("30 14 * * 1-5", Cadence(CadenceKind.WEEKDAYS, 14, 30).cron())
        assertEquals("5 8 * * *", Cadence(CadenceKind.DAILY, 8, 5).cron())
        assertEquals("45 16 * * 4", Cadence(CadenceKind.WEEKLY, 16, 45, weekday = 4).cron())
        assertEquals("*/10 * * * *", Cadence(CadenceKind.CUSTOM, custom = " */10 * * * * ").cron())
        assertEquals("0 23 * * 1", Cadence(CadenceKind.WEEKLY, 30, -2, weekday = 9).cron())
        assertEquals(Cadence(CadenceKind.WEEKLY, 16, 45, 4), Cadence.parse("45 16 * * 4"))
        assertEquals(CadenceKind.WEEKDAYS, Cadence.parse("0 9 * * 1-5").kind)
        assertEquals(CadenceKind.CUSTOM, Cadence.parse("*/10 * * * *").kind, "a stepped cron is never mistaken for a daily one")
        assertEquals(CadenceKind.CUSTOM, Cadence.parse("0 9 1 * *").kind)
    }

    @Test
    fun templatesRenderAndInsertAdvertisedPlaceholders() {
        val values = mapOf("date" to "2026-08-25", "scheduled_at" to "2026-08-25T07:00:00Z", "project" to "Dieter", "board" to "Main", "schedule" to "Nightly")
        assertEquals("2026-08-25 2026-08-25T07:00:00Z Dieter Main Nightly {{unknown}}", ScheduleTemplates.render("{{date}} {{scheduled_at}} {{project}} {{board}} {{schedule}} {{unknown}}", values))
        assertEquals("Daily {{date}}", ScheduleTemplates.insert("Daily", "date"))
        assertEquals("Daily {{date}}", ScheduleTemplates.insert("Daily ", "date"))
        assertEquals("{{board}}", ScheduleTemplates.insert("", "board"))
    }

    @Test
    fun scheduleDraftsNormalizeLegacyValues() {
        val boards = listOf(Board(id = "b1", labels = listOf(Label(id = "l1"))), Board(id = "b2"))
        val fresh = ScheduleDrafts.make(null, "p", "Europe/Berlin", boards, selectedBoardId = "b2", harnesses = emptyList())
        assertEquals("0 9 * * 1-5", fresh.cron)
        assertEquals("b2", fresh.board_id)
        assertEquals("draft", fresh.action)
        assertEquals("skip_if_open", fresh.open_card_policy)
        assertEquals("worktree", fresh.workspace_mode)
        val legacy = ScheduleDrafts.make(Schedule(id = "s", board_id = "gone", action = "run", open_card_policy = "always", workspace_mode = ""), "p", "UTC", boards, null, emptyList())
        assertEquals("b1", legacy.board_id)
        assertEquals("run", legacy.action)
        assertEquals("project", legacy.workspace_mode, "an existing schedule without a mode runs in the project")
        assertFalse(ScheduleDrafts.canSave(fresh))
        assertTrue(ScheduleDrafts.canSave(fresh.copy(name = "Nightly", prompt_template = "Do it")))
        assertEquals(listOf("l1"), ScheduleDrafts.onBoard(fresh.copy(label_ids = listOf("l1", "l2")), boards[0]).label_ids)
        assertEquals(listOf("Europe/Berlin", "America/New_York", "UTC"), ScheduleDrafts.timezoneOptions("Europe/Berlin", "America/New_York", listOf("UTC")))
        assertEquals(SchedulesPresentation.FAILED, SchedulePresentations.resolve(loaded = true, loading = false, hasSchedules = false, error = "x"))
        assertEquals(SchedulesPresentation.LOADING, SchedulePresentations.resolve(loaded = false, loading = false, hasSchedules = false, error = null))
        assertEquals(SchedulesPresentation.EMPTY, SchedulePresentations.resolve(loaded = true, loading = false, hasSchedules = false, error = null))
    }

    @Test
    fun processOutputIsBoundedAtCharacterBoundaries() {
        val (small, trimmedSmall) = Processes.append("ab".encodeUtf8(), "c".encodeUtf8())
        assertEquals("abc", small.utf8())
        assertFalse(trimmedSmall)
        val big = "é".repeat(Processes.MAX_STREAM_BYTES / 2 + 10).encodeUtf8()
        val (kept, trimmed) = Processes.append("x".encodeUtf8(), big)
        assertTrue(trimmed)
        assertTrue(kept.size <= Processes.MAX_STREAM_BYTES)
        assertTrue(kept.utf8().all { it == 'é' }, "the kept output starts on a character")
    }

    @Test
    fun processEventsApplyInSequenceAndResetReplays() {
        val processes = Processes(com.dbpprt.dieter.core.session.MachineSessions(
            com.dbpprt.dieter.core.routing.RouteSelector(Offline, null, com.dbpprt.dieter.core.routing.RoutingPolicy(false), com.dbpprt.dieter.core.routing.WebRtcCooldown(kotlin.time.Clock.System), com.dbpprt.dieter.core.runtime.SilentLogger),
            kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined),
        ), kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined))
        val target = com.dbpprt.dieter.core.executions.ProcessTarget("d", "p", "c")
        val execution = Execution(id = "e", project_id = "p", card_id = "c", status = "running", sequence = 1)
        processes.receive(ExecutionEvent(execution = execution, sequence = 1, stream = ExecutionStream.EXECUTION_STREAM_STDOUT, data_ = "one ".encodeUtf8(), reset = true), target)
        processes.receive(ExecutionEvent(execution = execution.copy(sequence = 2), sequence = 2, stream = ExecutionStream.EXECUTION_STREAM_STDERR, data_ = "oops".encodeUtf8()), target)
        processes.receive(ExecutionEvent(execution = execution, sequence = 2, stream = ExecutionStream.EXECUTION_STREAM_STDOUT, data_ = "dup".encodeUtf8()), target)
        processes.receive(ExecutionEvent(execution = execution.copy(sequence = 3), sequence = 3, stream = ExecutionStream.EXECUTION_STREAM_PTY, data_ = "two".encodeUtf8()), target)
        processes.receive(ExecutionEvent(execution = execution.copy(card_id = "other"), sequence = 4, stream = ExecutionStream.EXECUTION_STREAM_STDOUT, data_ = "foreign".encodeUtf8()), target)
        assertEquals("one two", processes.view.value.stdout.utf8())
        assertEquals("oops", processes.view.value.stderr.utf8())
    }

    private object Offline : com.dbpprt.dieter.core.platform.RpcTransport {
        override fun gateway(access: com.dbpprt.dieter.core.platform.GatewayAccess) = error("offline")
        override fun relay(access: com.dbpprt.dieter.core.platform.GatewayAccess, daemonId: String) = error("offline")
        override fun direct(target: com.dbpprt.dieter.core.platform.DirectTarget, tokens: com.dbpprt.dieter.core.platform.DaemonTokenSource) = error("offline")
    }

    @Test
    fun quotaPresentationIsComputedOnce() {
        val now = Instant.parse("2026-09-30T12:00:00Z")
        assertEquals("Resets in 2h", Quotas.resetText((now + 2.hours + 30.minutes).toString(), now, fine = false))
        assertEquals("Resets in 2h 30m", Quotas.resetText((now + 2.hours + 30.minutes).toString(), now))
        assertEquals("Resets in 1d 2h", Quotas.resetText((now + 26.hours).toString(), now))
        assertEquals("Reset due", Quotas.resetText(now.toString(), now))
        assertEquals("Reset time unavailable", Quotas.resetText("soon", now))
        val account = ProviderQuotaSnapshot(
            account_key = "k".repeat(32), display_email = "dev@example.com", availability = ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
            windows = listOf(ProviderQuotaWindow(remaining_percent = 40), ProviderQuotaWindow(remaining_percent = 8), ProviderQuotaWindow()),
            reset_credits = ProviderResetCredits(available_count = 1),
        )
        assertEquals(8, Quotas.remaining(account))
        assertEquals(QuotaLevel.CRITICAL, Quotas.level(8))
        assertEquals(QuotaLevel.UNKNOWN, Quotas.level(null))
        assertEquals("dev", Quotas.accountLabel(account))
        assertEquals("••kkkk", Quotas.accountLabel(account.copy(display_email = "")))
        assertTrue(Quotas.stale(account, now))
        assertTrue(Quotas.included(account))
        assertTrue(Quotas.canReset(ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, account))
        val groups = listOf(ProviderQuotaGroup(provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, accounts = listOf(account)))
        assertEquals(account, Quotas.forConversation(Card(provider = "claude", provider_account_key = account.account_key), groups)?.second, "the account key decides, not the provider name")
        assertNull(Quotas.forConversation(Card(), groups))
    }

    @Test
    fun searchMatchesPrefixesOfEveryTermAndRanksTitles() {
        val index = TaskSearchIndex(listOf(
            SearchDocument("1", "Fix login", "Users cannot sign in", "Dieter · Main", "2026-01-01"),
            SearchDocument("2", "Login page redesign", "", "", "2026-01-03"),
            SearchDocument("3", "Café menu", "Résumé upload", "", "2026-01-02"),
            SearchDocument("4", "Archived login", "", "", "2026-01-05", archived = true),
            SearchDocument("1", "Old title", "", "", "2025-01-01"),
        ))
        assertEquals(listOf("2", "1"), index.search("login").map { it.id }, "a leading title match ranks first")
        assertEquals(listOf("1"), index.search("fix log").map { it.id })
        assertEquals(listOf("3"), index.search("resume cafe").map { it.id }, "accents are ignored")
        assertEquals(listOf("1"), index.search("dieter main").map { it.id }, "location is searchable")
        assertTrue(index.search("login missing").isEmpty())
        assertTrue(index.search("   ").isEmpty())
        assertEquals("Fix login", index.search("fix").single().title, "the newer copy of a document wins")
    }

    @Test
    fun chatSearchMatchesProjectAndFolderNames() {
        val chats = listOf(Card(id = "a", title = "Alpha", project_id = "p1"), Card(id = "b", title = "Beta", project_id = "p2"), Card(id = "c", title = "Gamma", project_id = "p2"))
        val projects = listOf(Project(id = "p1", name = "Website"), Project(id = "p2", name = "Backend"))
        val folders = listOf(NavigationFolder("f", "Research", listOf("c")))
        assertEquals(listOf("a"), ListFilters.chats(chats, projects, folders, " alp ").map { it.id })
        assertEquals(listOf("b", "c"), ListFilters.chats(chats, projects, folders, "BACK").map { it.id })
        assertEquals(listOf("c"), ListFilters.chats(chats, projects, folders, "research").map { it.id })
        assertEquals(chats, ListFilters.chats(chats, projects, folders, ""))
        assertEquals(listOf("p2"), ListFilters.chatProjects(projects, listOf(chats[1]), "beta").map { it.id })
        assertEquals(projects, ListFilters.chatProjects(projects, emptyList(), ""))
    }
}
