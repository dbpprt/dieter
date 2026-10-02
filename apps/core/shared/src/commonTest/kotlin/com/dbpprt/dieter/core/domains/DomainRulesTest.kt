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
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.executions.ProcessTarget
import com.dbpprt.dieter.core.executions.Processes
import com.dbpprt.dieter.core.quotas.QuotaLevel
import com.dbpprt.dieter.core.quotas.Quotas
import com.dbpprt.dieter.core.search.SearchDocument
import com.dbpprt.dieter.core.search.TaskSearchIndex
import com.dbpprt.dieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okio.ByteString.Companion.encodeUtf8

class DomainRulesTest {
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
        val processes = Processes(offlineSessions(), CoroutineScope(Dispatchers.Unconfined))
        val target = ProcessTarget("d", "p", "c")
        val execution = Execution(id = "e", project_id = "p", card_id = "c", status = "running", sequence = 1)
        processes.receive(ExecutionEvent(execution = execution, sequence = 1, stream = ExecutionStream.EXECUTION_STREAM_STDOUT, data_ = "one ".encodeUtf8(), reset = true), target)
        processes.receive(ExecutionEvent(execution = execution.copy(sequence = 2), sequence = 2, stream = ExecutionStream.EXECUTION_STREAM_STDERR, data_ = "oops".encodeUtf8()), target)
        processes.receive(ExecutionEvent(execution = execution, sequence = 2, stream = ExecutionStream.EXECUTION_STREAM_STDOUT, data_ = "dup".encodeUtf8()), target)
        processes.receive(ExecutionEvent(execution = execution.copy(sequence = 3), sequence = 3, stream = ExecutionStream.EXECUTION_STREAM_PTY, data_ = "two".encodeUtf8()), target)
        processes.receive(ExecutionEvent(execution = execution.copy(card_id = "other"), sequence = 4, stream = ExecutionStream.EXECUTION_STREAM_STDOUT, data_ = "foreign".encodeUtf8()), target)
        assertEquals("one two", processes.view.value.stdout.utf8())
        assertEquals("oops", processes.view.value.stderr.utf8())
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

        val cards = listOf(Card(id = "c", scope = "chat", project_id = "p"), Card(id = "f", scope = "chat", project_id = "p", board_id = "b"), Card(id = "t", scope = "board", project_id = "p", board_id = "b"))
        val documents = TaskSearchIndex.documents(cards, listOf(Project(id = "p", name = "Dieter")), listOf(Board(id = "b", name = "Main")))
        assertEquals(listOf("c"), documents.filter { it.chat }.map { it.id }, "a chat filed on a board is found as a card")
        assertEquals("Dieter · Main", documents.single { it.id == "f" }.location)
    }
}
