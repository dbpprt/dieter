package com.getdieter.core.providers

import com.getdieter.client.v1.ProviderSeverity
import com.getdieter.core.client.rules.ProviderExports
import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_HOME
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.laptop
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderFixtures.tokens
import com.getdieter.core.providers.ProviderFixtures.usage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

class ProviderUsageTest {
    private val now = Instant.parse("2026-11-14T12:00:00Z")

    @Test
    fun usageIsTheFreshestOfAnyMachineAndTokensAddUp() {
        val view =
            ProviderFixtures.view(
                account(CLAUDE_WORK, "claude", "Work"),
                login(
                    CLAUDE_WORK,
                    "mac",
                    usage = usage("2026-11-14T10:00:00Z", "five_hour" to 90.0),
                    tokens = tokens(1_000_000, 5_000_000),
                ),
                login(
                    CLAUDE_WORK,
                    "box",
                    usage = usage("2026-11-14T11:50:00Z", "five_hour" to 38.0, "weekly" to 12.0),
                    tokens = tokens(200_000, 3_400_000, observedAt = "2026-11-14T11:55:00Z"),
                ),
            )
        val work = view.account(CLAUDE_WORK)!!
        assertEquals("2026-11-14T11:50:00Z", work.usage?.observedAt, "box observed last")
        assertEquals(62, ProviderUsages.remaining(work.usage), "100 minus the highest use")
        assertEquals(1_200_000, work.tokens?.fiveHour?.total)
        assertEquals(8_400_000, work.tokens?.sevenDay?.total)
        assertEquals("2026-11-14T11:55:00Z", work.tokens?.observedAt)
        assertEquals("1.2M tokens in 5 h · 8.4M in 7 days", ProviderUsages.tokensText(work.tokens))
        assertEquals("", ProviderUsages.tokensText(null))
        assertFalse(ProviderUsages.stale(work.usage!!.observedAt, now))
        assertTrue(ProviderUsages.stale("2026-11-14T11:00:00Z", now), "older than 30 minutes")
        assertTrue(ProviderUsages.stale("", now), "never observed")
    }

    @Test
    fun severityAndWording() {
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_CRITICAL, ProviderUsages.severity(10))
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_LOW, ProviderUsages.severity(30))
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_NORMAL, ProviderUsages.severity(31))
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_UNKNOWN, ProviderUsages.severity(null))
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_UNKNOWN, ProviderExports.severity(-1))
        assertEquals("62% left", ProviderUsages.leftText(62))
        assertEquals("", ProviderExports.usageText(-1))
        assertEquals("Claude 62% left", ProviderUsages.providerText("claude", 62))
        assertEquals(0, ProviderUsages.remaining(UsageWindowRecord(usedPercent = 140.0)))
        assertEquals(null, ProviderUsages.remaining(UsageWindowRecord()))
        assertEquals("5 hour", ProviderUsages.windowName(UsageWindowRecord(kind = "five_hour")))
        assertEquals("Opus", ProviderUsages.windowName(UsageWindowRecord("model", "Opus")))
        val millis = now.toEpochMilliseconds()
        assertEquals(
            "Resets in 2h",
            ProviderExports.resetText(
                (now + 2.hours + 30.minutes).toString(),
                millis,
                fine = false,
            ),
        )
        assertEquals(
            "Resets in 2h 30m",
            ProviderExports.resetText((now + 2.hours + 30.minutes).toString(), millis, fine = true),
        )
        assertEquals("Resets in 1d 2h", ProviderUsages.resetText((now + 26.hours).toString(), now))
        assertEquals("Reset due", ProviderUsages.resetText(now.toString(), now))
        assertEquals("Reset time unavailable", ProviderUsages.resetText("soon", now))
        assertEquals(
            "Updated 3m ago",
            ProviderExports.usageUpdated((now - 3.minutes).toString(), millis),
        )
        assertEquals("Not reported yet", ProviderExports.usageUpdated("", millis))
        assertEquals("ABCD-EFGH", ProviderExports.deviceCode(" abcdefgh "))
        assertEquals("ABCD-12345", ProviderExports.deviceCode("abcd-12345"))
        assertEquals(
            "Expires in 14:05",
            ProviderExports.codeExpiry((now + 845.seconds).toString(), millis),
        )
        assertEquals("Expired", ProviderExports.codeExpiry(now.toString(), millis))
        assertEquals("", ProviderExports.codeExpiry("", millis))
        assertEquals("Reset usage limits (1 credit)", ProviderUsages.resetLabel(1))
        assertEquals("Reset usage limits (2 credits)", ProviderUsages.resetLabel(2))
    }

    @Test
    fun theSummaryTakesTheTightestIncludedAccount() {
        val view =
            ProviderFixtures.view(
                account(CLAUDE_WORK, "claude", "Work"),
                account(CLAUDE_HOME, "claude", "Home", included = false),
                account(CHATGPT_TEAM, "chatgpt", "Team"),
                login(CLAUDE_WORK, "mac", usage = usage("2026-11-14T11:50:00Z", "weekly" to 38.0)),
                login(CLAUDE_HOME, "mac", usage = usage("2026-11-14T11:50:00Z", "weekly" to 95.0)),
                login(CHATGPT_TEAM, "box"),
            )
        val summary = ProviderUsages.summary(view.accounts)
        assertEquals(listOf("claude", "chatgpt"), summary.items.map { it.provider })
        val claude = summary.items[0]
        assertEquals(62, claude.remaining, "the excluded account does not count")
        assertEquals("Claude 62% left", claude.text)
        assertEquals(CLAUDE_WORK, claude.account_id)
        assertEquals(-1, summary.items[1].remaining, "nothing reported for ChatGPT")
        assertEquals("", summary.items[1].text)
        assertEquals("62% left", summary.text)
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_NORMAL, summary.severity)
    }

    @Test
    fun readinessFollowsTheMachinesLoginRecord() {
        val view =
            ProviderFixtures.view(
                account(CLAUDE_WORK, "claude", "Work"),
                login(CLAUDE_WORK, "mac"),
                login(CLAUDE_WORK, "box", state = ProviderKinds.EXPIRED),
                login(CLAUDE_WORK, "laptop", state = ProviderKinds.SIGNED_OUT),
                machines = listOf(ProviderFixtures.mac, ProviderFixtures.box, laptop),
            )
        assertEquals(Readiness.READY, ProviderReadiness.of(view, CLAUDE_WORK, "mac").readiness)
        val expired = ProviderReadiness.of(view, CLAUDE_WORK, "box")
        assertEquals(Readiness.EXPIRED, expired.readiness)
        assertEquals("Sign-in expired on box", expired.reason)
        val offline = ProviderReadiness.of(view, CLAUDE_WORK, "laptop")
        assertEquals(Readiness.MACHINE_OFFLINE, offline.readiness)
        assertEquals("laptop is offline", offline.reason)
        val missing = ProviderReadiness.of(view, CHATGPT_TEAM, "mac")
        assertEquals(Readiness.NO_ACCOUNT, missing.readiness)
        assertEquals(Readiness.READY, ProviderReadiness.of(view, CLAUDE_WORK, "").readiness)
        val signedOut =
            ProviderReadiness.of(
                ProviderFixtures.view(
                    account(CLAUDE_WORK, "claude", "Work"),
                    login(CLAUDE_WORK, "box", state = ProviderKinds.SIGNED_OUT),
                ),
                CLAUDE_WORK,
                "box",
            )
        assertEquals(Readiness.SIGNED_OUT, signedOut.readiness)
        assertEquals("Not signed in on box", signedOut.reason)
        assertEquals(
            "Not signed in on box",
            ProviderExports.readinessReason(ProviderKinds.NOT_SIGNED_IN, "box", online = true),
        )
        assertEquals(
            "",
            ProviderExports.readinessReason(ProviderKinds.SIGNED_IN, "box", online = false),
        )
    }
}
