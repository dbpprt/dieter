package com.dbpprt.dieter.widget

import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

class WidgetUsageModelTest {
    private val now = Instant.parse("2026-09-26T10:00:00Z")

    private fun window(
        label: String,
        remaining: Int?,
        resetsAt: String = "2026-09-26T18:00:00Z",
    ) = ProviderQuotaWindow(label = label, remaining_percent = remaining, resets_at = resetsAt)

    private fun account(
        email: String = "dev@example.com",
        available: Boolean = true,
        freshUntil: String = "2026-09-26T11:00:00Z",
        windows: List<ProviderQuotaWindow> = listOf(window("Weekly", 42)),
        provider: ProviderQuotaProvider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE,
    ) = ProviderQuotaSnapshot(
        provider = provider,
        account_key = "key-$email",
        display_email = email,
        availability = if (available) ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE
        else ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT,
        fresh_until = freshUntil,
        windows = windows,
    )

    private fun group(vararg accounts: ProviderQuotaSnapshot, provider: ProviderQuotaProvider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE) =
        ProviderQuotaGroup(provider = provider, accounts = accounts.toList())

    private fun model(
        snapshots: List<UsageAccountSnapshot>,
        small: Boolean = false,
        now: Instant = this.now,
    ) = buildUsageModel(snapshots, now.toEpochMilli() - 60_000, true, small, now)

    @Test fun bindingWindowIsTheMostConstrainedOne() {
        val snapshots = usageSnapshots(listOf(group(account(windows = listOf(
            window("Weekly", 55, resetsAt = "2026-09-29T18:00:00Z"),
            window("Session", 12, resetsAt = "2026-09-26T18:00:00Z"),
        )))))
        val row = model(snapshots).accounts.single()
        assertEquals(12, row.remainingPercent)
        assertEquals("Session · Resets in 8h 0m", row.resetLine)
    }

    @Test fun lowestAccountDrivesSmallVariantHeadline() {
        val snapshots = usageSnapshots(listOf(
            group(account(email = "a@example.com", windows = listOf(window("Weekly", 80)))),
            group(account(email = "b@example.com", windows = listOf(window("Weekly", 7))),
                provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX),
        ))
        val small = model(snapshots, small = true)
        assertEquals(7, small.lowest?.remainingPercent)
        assertEquals("OpenAI", small.lowest?.source)
        assertEquals("2 accounts · lowest 7%", small.summary)

        val large = model(snapshots)
        assertEquals(listOf("a@example.com", "b@example.com"), large.accounts.map { it.title })
    }

    @Test fun signedOutAccountShowsReasonInsteadOfPercentage() {
        val snapshots = usageSnapshots(listOf(group(account(available = false, windows = listOf(window("Weekly", 42)))))
        )
        val result = model(snapshots)
        val row = result.accounts.single()
        assertEquals(42, row.remainingPercent)
        assertEquals("Signed out", row.availabilityText)
        assertEquals("1 account", result.summary)
    }

    @Test fun emptyStateSaysNoUsageYet() {
        val neverFetched = buildUsageModel(emptyList(), fetchedAtMs = 0, connected = false, small = false, now = now)
        assertEquals("No usage yet", neverFetched.emptyTitle)
        assertEquals("Provider usage at a glance", neverFetched.summary)
        assertFalse(neverFetched.hasAccounts)
        val fetchedEmpty = buildUsageModel(emptyList(), fetchedAtMs = now.toEpochMilli(), connected = true, small = false, now = now)
        assertEquals("No provider accounts", fetchedEmpty.emptyTitle)
    }

    @Test fun staleFreshUntilMarksRefreshPending() {
        val snapshots = usageSnapshots(listOf(group(account(freshUntil = "2026-09-26T09:00:00Z",
            windows = listOf(window("Weekly", 42, resetsAt = ""))))))
        val row = model(snapshots).accounts.single()
        assertEquals("Weekly · Last reported · refresh pending", row.resetLine)
    }

    @Test fun statusTextReflectsConnection() {
        assertEquals("Not synced yet", usageStatusText(0L, connected = false, now))
        val fetchedAt = now.toEpochMilli() - 60_000
        val time = DateTimeFormatter.ofPattern("MMM d, HH:mm").withZone(ZoneId.systemDefault())
            .format(Instant.ofEpochMilli(fetchedAt))
        assertEquals("Offline · updated $time", usageStatusText(fetchedAt, connected = false, now))
        assertEquals("Updated $time", usageStatusText(fetchedAt, connected = true, now))
    }

    @Test fun largeVariantCapsVisibleAccountsAndCountsHidden() {
        val groups = (1..8).map { index ->
            group(account(email = "user$index@example.com", windows = listOf(window("Weekly", index * 10))))
        }
        val result = buildUsageModel(usageSnapshots(groups), now.toEpochMilli() - 60_000, true, false, now, maxAccounts = 6)
        assertEquals(6, result.accounts.size)
        assertEquals(2, result.hiddenAccounts)
        assertEquals("8 accounts · lowest 10%", result.summary)
        assertTrue(result.hasAccounts)
    }
}
