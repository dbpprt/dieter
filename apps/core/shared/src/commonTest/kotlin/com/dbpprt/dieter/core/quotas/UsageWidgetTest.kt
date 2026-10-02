package com.dbpprt.dieter.core.quotas

import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant

/** Ported from the Android usage widget's model test, with the core's staleness and identity rules. */
class UsageWidgetTest {
    private val now = Instant.parse("2026-09-26T10:00:00Z")
    private val fetched = "Sep 26, 09:59"

    private fun window(label: String, remaining: Int?, resetsAt: String = "2026-09-26T18:00:00Z") =
        ProviderQuotaWindow(label = label, remaining_percent = remaining, resets_at = resetsAt)

    private fun account(
        email: String = "dev@example.com",
        available: Boolean = true,
        freshUntil: String = "2026-09-26T11:00:00Z",
        windows: List<ProviderQuotaWindow> = listOf(window("Weekly", 42)),
    ) = ProviderQuotaSnapshot(
        account_key = "key-$email",
        display_email = email,
        availability = if (available) ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE else ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT,
        fresh_until = freshUntil,
        windows = windows,
    )

    private fun group(vararg accounts: ProviderQuotaSnapshot, provider: ProviderQuotaProvider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE) =
        ProviderQuotaGroup(provider = provider, accounts = accounts.toList())

    private fun model(groups: List<ProviderQuotaGroup>, small: Boolean = false) = UsageWidget.build(groups, fetched, connected = true, small = small, now = now)

    @Test fun bindingWindowIsTheMostConstrainedOne() {
        val row = model(listOf(group(account(windows = listOf(
            window("Weekly", 55, resetsAt = "2026-09-29T18:00:00Z"),
            window("Session", 12, resetsAt = "2026-09-26T18:00:00Z"),
        ))))).accounts.single()
        assertEquals(12, row.remainingPercent)
        assertEquals("Session · Resets in 8h 0m", row.resetLine)
        assertEquals(QuotaLevel.LOW, row.level)
    }

    @Test fun withoutAReportedPercentageTheFirstWindowBinds() {
        val row = model(listOf(group(account(windows = listOf(window("Usage", null), window("Weekly", null)))))).accounts.single()
        assertNull(row.remainingPercent)
        assertEquals("Resets in 8h 0m", row.resetLine, "the generic \"Usage\" label is left out")
        assertEquals(QuotaLevel.UNKNOWN, row.level)
    }

    @Test fun lowestAccountDrivesSmallVariantHeadline() {
        val groups = listOf(
            group(account(email = "a@example.com", windows = listOf(window("Weekly", 80)))),
            group(account(email = "b@example.com", windows = listOf(window("Weekly", 7))), provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX),
        )
        val small = model(groups, small = true)
        assertTrue(small.small)
        assertEquals(7, small.lowest?.remainingPercent)
        assertEquals("OpenAI", small.lowest?.source)
        assertEquals("2 accounts · lowest 7%", small.summary)
        assertEquals(QuotaLevel.CRITICAL, small.level)
        assertEquals(listOf("a@example.com", "b@example.com"), model(groups).accounts.map { it.title })
    }

    @Test fun signedOutAccountShowsReasonInsteadOfPercentage() {
        val result = model(listOf(group(account(available = false, windows = listOf(window("Weekly", 42))))))
        val row = result.accounts.single()
        assertEquals(42, row.remainingPercent)
        assertEquals("Signed out", row.availabilityText)
        assertEquals(QuotaLevel.UNKNOWN, row.level, "an unavailable account has no severity tint")
        assertEquals("1 account", result.summary)
        assertNull(result.lowest, "unavailable accounts never drive the headline")
    }

    @Test fun emptyStateSaysNoUsageYet() {
        val neverFetched = UsageWidget.build(emptyList(), fetchedTime = null, connected = false, small = false, now = now)
        assertEquals("No usage yet", neverFetched.emptyTitle)
        assertEquals("Provider usage at a glance", neverFetched.summary)
        assertEquals("Sign in to a supported provider on a Dieter machine.", neverFetched.emptyBody)
        assertFalse(neverFetched.hasAccounts)
        assertEquals("No provider accounts", UsageWidget.build(emptyList(), fetched, connected = true, small = false, now = now).emptyTitle)
    }

    @Test fun staleFreshUntilMarksRefreshPending() {
        val past = model(listOf(group(account(freshUntil = "2026-09-26T09:00:00Z", windows = listOf(window("Weekly", 42, resetsAt = ""))))))
        assertEquals("Weekly · Last reported · refresh pending", past.accounts.single().resetLine)
        val unknown = model(listOf(group(account(freshUntil = "", windows = listOf(window("Weekly", 42, resetsAt = ""))))))
        assertEquals("Weekly · Last reported · refresh pending", unknown.accounts.single().resetLine, "unknown freshness is stale, as the gateway judges it")
        val current = model(listOf(group(account(windows = listOf(window("Weekly", 42, resetsAt = ""))))))
        assertEquals("Weekly", current.accounts.single().resetLine)
    }

    @Test fun statusTextReflectsConnection() {
        assertEquals("Not synced yet", UsageWidget.build(emptyList(), null, connected = false, small = false, now = now).statusText)
        assertEquals("Syncing…", UsageWidget.build(emptyList(), null, connected = true, small = false, now = now).statusText)
        assertEquals("Offline · updated $fetched", UsageWidget.build(emptyList(), fetched, connected = false, small = false, now = now).statusText)
        assertEquals("Updated $fetched", UsageWidget.build(emptyList(), fetched, connected = true, small = false, now = now).statusText)
    }

    @Test fun largeVariantCapsVisibleAccountsAndCountsHidden() {
        val groups = (1..8).map { index -> group(account(email = "user$index@example.com", windows = listOf(window("Weekly", index * 10)))) }
        val result = UsageWidget.build(groups, fetched, connected = true, small = false, now = now, maxAccounts = 6)
        assertEquals(6, result.accounts.size)
        assertEquals(2, result.hiddenAccounts)
        assertEquals("8 accounts · lowest 10%", result.summary)
        assertTrue(result.hasAccounts)
    }

    @Test fun accountsWithoutAnEmailUseTheCoreIdentity() {
        val keyOnly = ProviderQuotaSnapshot(
            account_key = "acct_abcdef", plan = "pro", fresh_until = "2026-09-26T11:00:00Z",
            availability = ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
        )
        assertEquals("Pro · ••abcdef", model(listOf(group(keyOnly))).accounts.single().title)
    }
}
