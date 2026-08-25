package com.dbpprt.dieter.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncStreamLivenessTest {
    @Test
    fun restartsAfterHeartbeatDeadline() {
        val lastFrame = 1_000L

        assertFalse(syncStreamIsStale(lastFrame, lastFrame + SYNC_STALE_AFTER_MS - 1))
        assertTrue(syncStreamIsStale(lastFrame, lastFrame + SYNC_STALE_AFTER_MS))
    }

    @Test
    fun waitsForFirstFrameAndIgnoresClockRollback() {
        assertFalse(syncStreamIsStale(lastFrameAtMs = 0, nowMs = 100_000))
        assertFalse(syncStreamIsStale(lastFrameAtMs = 10_000, nowMs = 9_999))
    }

    @Test
    fun foregroundWaitsForANewSyncFrameBeforeReportingConnected() {
        assertEquals(ConnectionPhase.SYNCING, foregroundConnectionPhase(ConnectionPhase.CONNECTED, becameForeground = true))
        assertEquals(ConnectionPhase.CONNECTED, foregroundConnectionPhase(ConnectionPhase.CONNECTED, becameForeground = false))
        assertEquals(ConnectionPhase.RECONNECTING, foregroundConnectionPhase(ConnectionPhase.RECONNECTING, becameForeground = true))
    }
}
