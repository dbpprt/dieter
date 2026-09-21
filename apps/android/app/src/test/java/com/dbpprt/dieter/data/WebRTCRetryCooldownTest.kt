package com.dbpprt.dieter.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRTCRetryCooldownTest {
    @Test
    fun failuresBackOffFromTwoMinutesAndCapAtFifteen() {
        var now = 1_000L
        val cooldown = WebRTCRetryCooldown { now }
        val expected = listOf(120_000L, 240_000L, 480_000L, 900_000L, 900_000L)

        expected.forEachIndexed { index, delay ->
            val state = cooldown.recordFailure("office")
            assertEquals(index + 1, state.consecutiveFailures)
            assertEquals(delay, state.remainingMillis)
            assertFalse(cooldown.allowsAttempt("office"))
            now = state.retryAtMillis
            assertTrue(cooldown.allowsAttempt("office"))
        }
    }

    @Test
    fun successClearsCooldownWithoutAffectingOtherMachines() {
        val cooldown = WebRTCRetryCooldown { 5_000L }
        cooldown.recordFailure("office")
        cooldown.recordFailure("home")

        cooldown.recordSuccess("office")

        assertTrue(cooldown.allowsAttempt("office"))
        assertNull(cooldown.snapshot("office"))
        assertFalse(cooldown.allowsAttempt("home"))
    }

    @Test
    fun candidateDiagnosticsContainOnlyKindsAndCounts() {
        val summary = ControlRTCBridge.candidateSummary(
            "a=candidate:1 1 udp 1 10.0.0.1 123 typ host\n" +
                "a=candidate:2 1 udp 1 203.0.113.1 456 typ srflx\n" +
                "a=candidate:3 1 tcp 1 192.0.2.1 789 typ relay\n",
        )
        assertEquals(ControlRTCBridge.CandidateSummary(1, 1, 1), summary)
    }
}
