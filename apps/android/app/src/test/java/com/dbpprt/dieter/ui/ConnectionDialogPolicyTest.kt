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
    fun reconnectNeverOpensTheConnectionDialogAutomatically() {
        assertNull(connectionDialogDelayMs(true, ConnectionPhase.RECONNECTING, 10_000L, 10_000L))
        assertNull(connectionDialogDelayMs(true, ConnectionPhase.RECONNECTING, 10_000L, 70_001L))
        assertNull(
            connectionDialogDelayMs(
                true,
                ConnectionPhase.UNAVAILABLE,
                10_000L,
                70_001L,
                hasCachedWorkspace = true,
            ),
        )
    }

    @Test
    fun userActionableFailureGetsGraceBeforeOpeningTheDialog() {
        assertEquals(
            CONNECTION_DIALOG_GRACE_MS,
            connectionDialogDelayMs(true, ConnectionPhase.AUTH_REQUIRED, 10_000L, 10_000L),
        )
        assertEquals(
            0L,
            connectionDialogDelayMs(true, ConnectionPhase.AUTH_REQUIRED, 10_000L, 70_001L),
        )
        assertEquals(
            0L,
            connectionDialogDelayMs(true, ConnectionPhase.INCOMPATIBLE, 10_000L, 70_001L),
        )
        assertEquals(
            0L,
            connectionDialogDelayMs(
                true,
                ConnectionPhase.UNAVAILABLE,
                10_000L,
                70_001L,
                hasCachedWorkspace = false,
            ),
        )
        assertNull(connectionDialogDelayMs(false, ConnectionPhase.STOPPED, null, 70_001L))
    }

    @Test
    fun dismissedInterruptionStaysDismissedAcrossFailurePhases() {
        assertEquals(
            true,
            connectionDialogDismissalApplies(10_000L, true, ConnectionPhase.RECONNECTING, 10_000L),
        )
        assertEquals(
            true,
            connectionDialogDismissalApplies(10_000L, true, ConnectionPhase.UNAVAILABLE, 10_000L),
        )
        assertFalse(connectionDialogDismissalApplies(10_000L, true, ConnectionPhase.RECONNECTING, 20_000L))
        assertFalse(connectionDialogDismissalApplies(10_000L, true, ConnectionPhase.CONNECTED, 10_000L))
        assertEquals(
            true,
            connectionDialogDismissalApplies(10_000L, false, ConnectionPhase.CONNECTED, 10_000L),
        )
    }
}
