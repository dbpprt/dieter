package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundSyncModeTest {
    @Test
    fun legacyPreferencePreservesItsExistingBehavior() {
        assertEquals(BackgroundSyncMode.LIVE, BackgroundSyncMode.resolve(null, legacyEnabled = true))
        assertEquals(BackgroundSyncMode.APP_ONLY, BackgroundSyncMode.resolve(null, legacyEnabled = false))
        assertEquals(BackgroundSyncMode.LIVE, BackgroundSyncMode.resolve("live", legacyEnabled = false))
    }

    @Test
    fun foregroundAlwaysRunsButBackgroundRespectsTheModeAndWindow() {
        BackgroundSyncMode.entries.forEach { mode ->
            assertTrue(backgroundConnectionShouldRun(true, true, false, mode, false))
        }
        assertTrue(backgroundConnectionShouldRun(true, false, true, BackgroundSyncMode.LIVE, false))
        assertTrue(backgroundConnectionShouldRun(true, false, true, BackgroundSyncMode.PERIODIC, true))
        assertFalse(backgroundConnectionShouldRun(true, false, true, BackgroundSyncMode.PERIODIC, false))
        assertFalse(backgroundConnectionShouldRun(true, false, true, BackgroundSyncMode.APP_ONLY, true))
        assertFalse(backgroundConnectionShouldRun(false, true, true, BackgroundSyncMode.LIVE, true))
    }

    @Test
    fun runningWorkKeepsSmartModeLive() {
        val idle = state(Card.newBuilder().setId("idle").setRuntime("idle").build())
        val running = state(Card.newBuilder().setId("running").setRuntime("running").build())

        assertFalse(hasActiveBackgroundWork(idle))
        assertTrue(hasActiveBackgroundWork(running))
    }

    @Test
    fun smartModeUsesBoundedOneMinuteCycles() {
        assertEquals(60_000L, DieterSyncService.BACKGROUND_POLL_INTERVAL_MS)
        assertEquals(30_000L, DieterSyncService.BACKGROUND_SYNC_WINDOW_TIMEOUT_MS)
    }

    @Test
    fun onlyARecentProjectedLiveConversationIsAlreadyCurrent() {
        assertTrue(
            liveSyncCoversConversation(
                BackgroundSyncMode.LIVE,
                ConnectionPhase.CONNECTED,
                lastFrameAtMs = 100_000L,
                nowMs = 110_000L,
                includedInProjection = true,
            ),
        )
        assertFalse(
            liveSyncCoversConversation(
                BackgroundSyncMode.PERIODIC,
                ConnectionPhase.CONNECTED,
                lastFrameAtMs = 100_000L,
                nowMs = 110_000L,
                includedInProjection = true,
            ),
        )
        assertFalse(
            liveSyncCoversConversation(
                BackgroundSyncMode.LIVE,
                ConnectionPhase.CONNECTED,
                lastFrameAtMs = 100_000L,
                nowMs = 145_000L,
                includedInProjection = true,
            ),
        )
        assertFalse(
            liveSyncCoversConversation(
                BackgroundSyncMode.LIVE,
                ConnectionPhase.CONNECTED,
                lastFrameAtMs = 100_000L,
                nowMs = 110_000L,
                includedInProjection = false,
            ),
        )
    }

    private fun state(card: Card) = DieterConnectionState(
        desiredConnected = true,
        backgroundSyncMode = BackgroundSyncMode.PERIODIC,
        activeGatewayId = "gateway",
        configuredConnections = emptyList(),
        endpointConnections = emptyList(),
        chats = listOf(card),
    )
}
