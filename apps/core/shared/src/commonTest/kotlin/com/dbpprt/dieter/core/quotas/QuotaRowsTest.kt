package com.dbpprt.dieter.core.quotas

import com.dbpprt.dieter.api.gateway.v1.ProviderCreditBalance
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaMachine
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaRefreshState
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSummary
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindowKind
import com.dbpprt.dieter.api.gateway.v1.ProviderResetCredits
import com.dbpprt.dieter.api.gateway.v1.ProviderSpendAllowance
import com.dbpprt.dieter.client.v1.QuotaDetail
import com.dbpprt.dieter.client.v1.QuotaMachineRow
import com.dbpprt.dieter.client.v1.QuotaSeverity
import com.dbpprt.dieter.core.client.quotasSlice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant

class QuotaRowsTest {
    private val openAI = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX
    private val claude = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE
    private val available = ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE

    private val account = ProviderQuotaSnapshot(
        account_key = "acct_8d9c1a2b3c4d", display_email = "dev@example.com", plan = "pro plus", availability = available,
        fresh_until = "2026-09-30T12:30:00Z", refresh_state = ProviderQuotaRefreshState.PROVIDER_QUOTA_REFRESH_STATE_REFRESHING,
        windows = listOf(
            ProviderQuotaWindow(id = "w5", kind = ProviderQuotaWindowKind.PROVIDER_QUOTA_WINDOW_KIND_FIVE_HOUR, remaining_percent = 45, resets_at = "2026-09-30T14:00:00Z"),
            ProviderQuotaWindow(id = "wk", label = "Weekly Codex", remaining_percent = 5),
            ProviderQuotaWindow(id = "wm", kind = ProviderQuotaWindowKind.PROVIDER_QUOTA_WINDOW_KIND_MONTHLY),
        ),
        credits = ProviderCreditBalance(balance = "$12.00"),
        spend_allowance = ProviderSpendAllowance(used = "$3", limit = "$20"),
        reset_credits = ProviderResetCredits(available_count = 2),
    )

    @Test
    fun accountsCarryEveryDisplayRule() {
        val row = QuotaRows.account(openAI, account)
        assertEquals("acct_8d9c1a2b3c4d", row.account_key)
        assertEquals("dev", row.label)
        assertEquals("dev@example.com", row.identity)
        assertEquals("Pro plus", row.subtitle, "only the plan's first letter is capitalized")
        assertEquals(5, row.remaining)
        assertEquals(QuotaSeverity.QUOTA_SEVERITY_CRITICAL, row.severity)
        assertTrue(row.available)
        assertEquals("", row.unavailable, "an available account shows no availability")
        assertEquals("No numeric limit reported", row.status)
        assertTrue(row.can_reset)
        assertTrue(row.included)
        assertTrue(row.refreshing)
        assertEquals(Instant.parse("2026-09-30T12:30:00Z").toEpochMilliseconds(), row.fresh_until_millis)
        assertEquals("OpenAI · dev@example.com · 5% remaining", row.summary_line)
        assertEquals(
            listOf(
                QuotaDetail(label = "Account", text = "••2b3c4d"),
                QuotaDetail(label = "Credits", text = "$12.00", monetary = true),
                QuotaDetail(label = "Spend", text = "$3 / $20", monetary = true),
                QuotaDetail(label = "Reset credits", text = "2 available"),
            ),
            row.details,
        )
        assertEquals(listOf("Account", "Reset credits"), row.details.filter { !it.monetary }.map { it.label }, "views without money drop monetary rows")
    }

    @Test
    fun accountsListTheMachinesThatReportedThem() {
        val reported = account.copy(
            machines = listOf(ProviderQuotaMachine(daemon_id = "d_studio", name = "Studio", online = true), ProviderQuotaMachine(daemon_id = "d_1234567890", online = false)),
        )
        assertEquals(
            listOf(QuotaMachineRow("d_studio", "Studio", true, "Online"), QuotaMachineRow("d_1234567890", "d_123456", false, "Offline")),
            QuotaRows.account(openAI, reported).machines,
            "an unnamed machine shows the start of its ID",
        )
        assertTrue(QuotaRows.account(openAI, account).machines.isEmpty())
    }

    @Test
    fun windowsCarryTheirNameRemainingSeverityAndRawReset() {
        val windows = QuotaRows.account(openAI, account).windows
        assertEquals(listOf("5 hour", "Weekly Codex", "Monthly"), windows.map { it.name })
        assertEquals(listOf(45, 5, -1), windows.map { it.remaining })
        assertEquals(
            listOf(QuotaSeverity.QUOTA_SEVERITY_NORMAL, QuotaSeverity.QUOTA_SEVERITY_CRITICAL, QuotaSeverity.QUOTA_SEVERITY_UNKNOWN),
            windows.map { it.severity },
        )
        assertEquals("2026-09-30T14:00:00Z", windows[0].resets_at)
        assertEquals(QuotaSeverity.QUOTA_SEVERITY_LOW, QuotaRows.window(ProviderQuotaWindow(remaining_percent = 30)).severity)
        assertEquals(100, QuotaRows.window(ProviderQuotaWindow(remaining_percent = 140)).remaining, "percentages stay within 0-100")
    }

    @Test
    fun unavailableAndKeyOnlyAccounts() {
        val keyOnly = ProviderQuotaSnapshot(
            account_key = "k".repeat(28) + "wxyz", plan = "", included_in_summary = false, status_code = "rate_limited",
            availability = ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT,
        )
        val row = QuotaRows.account(claude, keyOnly)
        assertEquals("••wxyz", row.label)
        assertEquals("Account · ••kkwxyz", row.identity)
        assertEquals("Excluded from summary", row.subtitle)
        assertEquals(-1, row.remaining)
        assertEquals(QuotaSeverity.QUOTA_SEVERITY_UNKNOWN, row.severity)
        assertFalse(row.available)
        assertEquals("Signed out", row.unavailable)
        assertEquals("rate limited", row.status)
        assertFalse(row.can_reset, "only OpenAI accounts with a credit can reset")
        assertFalse(row.included)
        assertEquals(0L, row.fresh_until_millis, "unknown freshness, which reads as stale")
        assertEquals("Claude · ••wxyz · Signed out", row.summary_line)
        assertEquals("Pro · ••kkwxyz", QuotaRows.account(claude, keyOnly.copy(plan = "pro")).identity)
    }

    @Test
    fun groupsSummarizeTheirAccountsAndLowestAllowance() {
        val group = ProviderQuotaGroup(
            provider = openAI, accounts = listOf(account, account.copy(account_key = "second", included_in_summary = false)),
            summary = ProviderQuotaSummary(remaining_percent = 5, excluded_account_count = 1),
        )
        val rows = QuotaRows.of(listOf(group, ProviderQuotaGroup(provider = claude)))
        assertEquals(listOf("OpenAI", "Claude"), rows.map { it.provider_name })
        assertEquals(listOf("2 accounts · 1 excluded", "0 accounts"), rows.map { it.summary })
        assertEquals(listOf(5, -1), rows.map { it.lowest_remaining })
        assertEquals(listOf("acct_8d9c1a2b3c4d", "second"), rows[0].accounts.map { it.account_key })
        assertEquals(openAI, rows[0].provider)
    }

    @Test
    fun theSliceCarriesTheRowsNextToTheRawGroups() {
        val groups = listOf(ProviderQuotaGroup(provider = openAI, accounts = listOf(account)))
        val slice = quotasSlice(QuotasView(groups = groups, live = true))
        assertEquals(groups, slice.groups)
        assertEquals(QuotaRows.of(groups), slice.group_rows)
        assertEquals("dev", slice.group_rows.single().accounts.single().label)
    }
}
