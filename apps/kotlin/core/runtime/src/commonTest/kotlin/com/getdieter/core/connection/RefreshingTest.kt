package com.getdieter.core.connection

import com.getdieter.api.gateway.v1.CompatibilityStatus
import com.getdieter.core.machines.Machine
import com.getdieter.core.trust.TrustState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

class RefreshingTest {
    private val now = Instant.fromEpochSeconds(1_800_000_000)

    private fun machine(
        id: String,
        online: Boolean = true,
        compatibility: CompatibilityStatus = CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE,
    ) =
        Machine(
            id = id,
            name = id,
            serverOnline = online,
            lastSeenAt = "",
            releaseVersion = "1.2.0",
            minimumReleaseVersion = "1.2.0",
            compatibility = compatibility,
            generation = 1,
            remoteDesktop = null,
            receivedAt = now,
        )

    private val directory =
        MachineDirectory(
            listOf(
                machine("live"),
                machine("resuming"),
                machine("catching-up"),
                machine("connecting"),
                machine("new"),
                machine("stale"),
                machine("offline", online = false),
                machine(
                    "outdated",
                    compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_UPDATE_REQUIRED,
                ),
            ),
            now,
        )

    private val syncs =
        mapOf(
            "live" to MachineSync(SyncState.LIVE),
            "resuming" to MachineSync(SyncState.LIVE, interruptedAt = now - 3.seconds),
            "catching-up" to MachineSync(SyncState.CATCHING_UP),
            "connecting" to MachineSync(SyncState.CONNECTING),
            "stale" to MachineSync(SyncState.STALE, since = now - 1.seconds),
            "offline" to MachineSync(SyncState.OFFLINE),
            "outdated" to MachineSync(SyncState.INCOMPATIBLE),
        )

    private fun refreshing(
        phase: ConnectionPhase,
        trust: TrustState = TrustState.TRUSTED,
        retryAt: Instant? = null,
    ) = MachineSyncs.refreshing(ConnectionState(phase, retryAt = retryAt), trust, directory, syncs)

    /**
     * Coming back from the background, every row shows what was cached when the app left, so all of
     * them refresh until the session is up; a cold start knows no machine yet, so a card without a
     * known owner refreshes too.
     */
    @Test
    fun everyViewRefreshesWhileTheSessionConnects() {
        val connecting = refreshing(ConnectionPhase.CONNECTING)
        assertEquals(Refreshing.ALL, connecting)
        assertTrue(connecting.includes("live"))
        assertTrue(connecting.includes(null))
        assertEquals(Refreshing.ALL, refreshing(ConnectionPhase.RECONNECTING))
        // Connected, but the roster is still being read: streams have not started.
        assertEquals(Refreshing.ALL, refreshing(ConnectionPhase.CONNECTED, TrustState.UNKNOWN))
    }

    /** Once connected, each machine refreshes until its stream is caught up and open. */
    @Test
    fun aConnectedSessionRefreshesOnlyMachinesNotYetCurrent() {
        val connected = refreshing(ConnectionPhase.CONNECTED)
        assertFalse(connected.all)
        assertEquals(setOf("resuming", "catching-up", "connecting", "new"), connected.machines)
        assertFalse(connected.includes("live"))
        assertFalse(connected.includes(null))
        // Machines that say why their view is old never also refresh.
        listOf("stale", "offline", "outdated").forEach { assertFalse(connected.includes(it)) }
    }

    /** Nothing refreshes while nothing is being fetched, or while the person has to act. */
    @Test
    fun nothingRefreshesWhileTheAppWaits() {
        listOf(
                ConnectionPhase.DISCONNECTED,
                ConnectionPhase.AUTH_REQUIRED,
                ConnectionPhase.UPDATE_REQUIRED,
            )
            .forEach { assertEquals(Refreshing.NONE, refreshing(it)) }
        // Waiting out a backoff after a failed attempt: the connection notice says so instead.
        assertEquals(
            Refreshing.NONE,
            refreshing(ConnectionPhase.RECONNECTING, retryAt = now + 2.seconds),
        )
        listOf(TrustState.NO_ROSTER, TrustState.PENDING, TrustState.REVOKED, TrustState.CONFLICT)
            .forEach { trust ->
                assertEquals(Refreshing.NONE, refreshing(ConnectionPhase.CONNECTED, trust))
                assertEquals(Refreshing.NONE, refreshing(ConnectionPhase.CONNECTING, trust))
            }
    }
}
