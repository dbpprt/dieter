package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaMachine
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.client.v1.QuotaGroupList
import com.dbpprt.dieter.core.quotas.QuotaRows
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Instant

class QuotaExportsTest {
    private val now = Instant.parse("2026-09-30T12:00:00Z").toEpochMilliseconds()
    private val hour = 3_600_000L

    @Test
    fun resetTimesUseCompactUnits() {
        assertEquals("Resets in 2h 30m", QuotaExports.resetText("2026-09-30T14:30:00Z", now, fine = true))
        assertEquals("Resets in 2h", QuotaExports.resetText("2026-09-30T14:30:00Z", now, fine = false))
        assertEquals("Resets in 1d 2h", QuotaExports.resetText("2026-10-01T14:00:00Z", now, fine = true))
        assertEquals("Resets in 2h 30m", QuotaExports.resetText("2026-09-30T14:30:00.250Z", now, fine = true), "fractional seconds parse")
        assertEquals("Reset due", QuotaExports.resetText("2026-09-30T11:00:00Z", now, fine = true))
        assertEquals("Reset time unavailable", QuotaExports.resetText("soon", now, fine = true))
    }

    @Test
    fun warningsPutUnavailabilityBeforeStaleness() {
        assertEquals("Signed out", QuotaExports.warning("Signed out", now + hour, now))
        assertEquals("Last reported · refresh pending", QuotaExports.warning("", 0, now))
        assertEquals("", QuotaExports.warning("", now + hour, now), "an available, current account has no warning")
    }

    @Test
    fun groupsTheCoreDoesNotWatchBecomeTheSameRows() {
        val group = ProviderQuotaGroup(
            provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
            accounts = listOf(ProviderQuotaSnapshot(account_key = "k", display_email = "dev@example.com", machines = listOf(ProviderQuotaMachine(daemon_id = "d", name = "Studio", online = true)))),
        )
        val rows = QuotaExports.rows(QuotaGroupList(listOf(group))).rows
        assertEquals(QuotaRows.of(listOf(group)), rows)
        assertEquals(listOf("Studio" to "Online"), rows.single().accounts.single().machines.map { it.name to it.state })
    }
}
