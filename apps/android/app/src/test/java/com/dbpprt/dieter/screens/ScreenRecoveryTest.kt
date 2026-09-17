package com.dbpprt.dieter.screens

import io.grpc.Status
import org.junit.Assert.*
import org.junit.Test

class ScreenRecoveryTest {
    @Test fun retriesContinueWithCappedFrequencyForTheLifetimeOfTheScreen() {
        val recovery = ScreenRecovery()
        assertEquals(250L, recovery.nextDelay(0))
        recovery.streaming(1_000)
        assertEquals(500L, recovery.nextDelay(1_500))
        recovery.streaming(3_500)
        assertEquals(1_000L, recovery.nextDelay(4_000))
        recovery.streaming(8_000)
        assertEquals(2_000L, recovery.nextDelay(8_500))
        repeat(1_000) { assertTrue(recovery.nextDelay(10_000L + it) <= 5_000L) }
    }

    @Test fun stableVideoRestoresBudgetButDisconnectedTimeDoesNotCount() {
        val recovery = ScreenRecovery()
        assertEquals(250L, recovery.nextDelay(0))
        recovery.streaming(1_000)
        recovery.streaming(5_000)
        assertEquals(250L, recovery.nextDelay(11_000))
        recovery.streaming(12_000)
        recovery.interrupted(13_000)
        assertEquals(500L, recovery.nextDelay(60_000))
    }

    @Test fun transportAndMissingSessionsReopenButTrustAndPolicyFailuresDoNot() {
        listOf(Status.NOT_FOUND, Status.UNAVAILABLE, Status.DEADLINE_EXCEEDED, Status.UNAUTHENTICATED,
            Status.RESOURCE_EXHAUSTED, Status.ABORTED).forEach { assertTrue(ScreenRecovery.retryable(it.asException())) }
        listOf(Status.PERMISSION_DENIED, Status.INVALID_ARGUMENT, Status.FAILED_PRECONDITION,
            Status.CANCELLED).forEach { assertFalse(ScreenRecovery.retryable(it.asException())) }
        assertFalse(ScreenRecovery.retryable(IllegalArgumentException("Invalid screen-sharing signature")))
        assertTrue(ScreenRecovery.retryableClosure("session lease expired"))
        listOf("native capture rendition stopped", "native daemon heartbeat expired",
            "native capture helper unresponsive", "native capture helper stopped").forEach {
            assertTrue(ScreenRecovery.retryableClosure(it))
        }
        assertFalse(ScreenRecovery.retryableClosure("capture permission denied"))
        assertFalse(ScreenRecovery.retryableClosure("remote desktop disabled"))
        assertFalse(ScreenRecovery.retryableClosure("remote desktop control disabled"))
        assertFalse(ScreenRecovery.retryableClosure("client closed"))
    }
}
