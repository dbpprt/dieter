package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

class MachinePresenceTest {
    private val received = Instant.parse("2026-10-01T12:00:00Z")

    private fun machine(id: String, serverOnline: Boolean = true, lastSeenAt: String = "", receivedAt: Instant = received) = Machine(
        id = id, name = id, serverOnline = serverOnline, lastSeenAt = lastSeenAt, releaseVersion = "1.0.0", minimumReleaseVersion = "1.0.0",
        compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE, generation = 1, remoteDesktop = null, receivedAt = receivedAt,
    )

    @Test fun gatewayClockNeverMeetsTheDeviceClock() {
        // A heartbeat the gateway stamped just now reads as future on a phone 70 ms behind, and as old on one minutes ahead.
        val justStamped = machine("m1", lastSeenAt = (received + 70.milliseconds).toString())
        val longAgo = machine("m2", lastSeenAt = (received - 10.minutes).toString())
        for (now in listOf(received, received + 1.seconds, received + 44.seconds)) {
            assertTrue(justStamped.online(now), "fresh report at $now")
            assertTrue(longAgo.online(now), "fresh report at $now")
        }
    }

    @Test fun onlyTheGatewayOrAStaleReportTakesAMachineOffline() {
        assertFalse(machine("m1", serverOnline = false).online(received))
        assertTrue(machine("m1").online(received + MachinePresence.STALE_AFTER - 1.milliseconds))
        assertFalse(machine("m1").online(received + MachinePresence.STALE_AFTER))
        // A device clock stepping backwards does not age a report.
        assertTrue(machine("m1").online(received - 5.seconds))
    }

    @Test fun nextExpiryFollowsTheOldestOnlineReport() {
        val machines = listOf(
            machine("old", receivedAt = received - 10.seconds),
            machine("new"),
            machine("gone", serverOnline = false, receivedAt = received - 20.seconds),
        )
        assertEquals(received + 35.seconds, MachinePresence.nextExpiry(machines, received))
        assertEquals(received + 45.seconds, MachinePresence.nextExpiry(machines, received + 35.seconds))
        assertNull(MachinePresence.nextExpiry(machines, received + 45.seconds))
    }
}
