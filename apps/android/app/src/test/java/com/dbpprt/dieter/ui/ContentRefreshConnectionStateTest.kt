package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ConnectionPhase
import org.junit.Assert.assertEquals
import org.junit.Test

class ContentRefreshConnectionStateTest {
    @Test
    fun contentRefreshCannotOverrideTheAuthoritativeConnectionState() {
        val syncing = DieterUiState(
            connectionPhase = ConnectionPhase.SYNCING,
            connectionError = "Waiting for a workspace frame",
        )

        val refreshed = syncing.copy(
            connectionPhase = ConnectionPhase.CONNECTED,
            connectionError = null,
            conversationScrollRequest = 7,
        ).preserveConnectionPresentation(syncing)

        assertEquals(ConnectionPhase.SYNCING, refreshed.connectionPhase)
        assertEquals("Waiting for a workspace frame", refreshed.connectionError)
        assertEquals(7, refreshed.conversationScrollRequest)
    }

    @Test
    fun contentRefreshKeepsConnectedStateConnected() {
        val connected = DieterUiState(connectionPhase = ConnectionPhase.CONNECTED)

        val refreshed = connected.copy(conversationScrollRequest = 1)
            .preserveConnectionPresentation(connected)

        assertEquals(ConnectionPhase.CONNECTED, refreshed.connectionPhase)
        assertEquals(1, refreshed.conversationScrollRequest)
    }
}
