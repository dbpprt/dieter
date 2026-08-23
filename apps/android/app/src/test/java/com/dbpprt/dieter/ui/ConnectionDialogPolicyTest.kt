package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ConnectionPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectionDialogPolicyTest {
    @Test
    fun connectedStartupNeverOpensTheConnectionDialog() {
        assertFalse(DieterUiState().connectionDialogVisible)
        assertNull(connectionDialogDelayMs(true, ConnectionPhase.CONNECTED, 1_000L, 80_000L))
    }

    @Test
    fun transientReconnectGetsAFullSilentGracePeriod() {
        assertEquals(
            CONNECTION_DIALOG_GRACE_MS,
            connectionDialogDelayMs(true, ConnectionPhase.RECONNECTING, 10_000L, 10_000L),
        )
        assertEquals(
            30_000L,
            connectionDialogDelayMs(true, ConnectionPhase.RECONNECTING, 10_000L, 40_000L),
        )
    }

    @Test
    fun prolongedFailureBecomesDialogEligible() {
        assertEquals(
            0L,
            connectionDialogDelayMs(true, ConnectionPhase.UNAVAILABLE, 10_000L, 70_001L),
        )
        assertNull(connectionDialogDelayMs(false, ConnectionPhase.STOPPED, null, 70_001L))
    }
}
