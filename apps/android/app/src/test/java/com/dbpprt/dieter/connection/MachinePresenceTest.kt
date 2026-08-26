package com.dbpprt.dieter.connection

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MachinePresenceTest {
    private val now = Instant.parse("2026-08-25T12:00:00Z").toEpochMilli()

    @Test
    fun gatewayPresenceIsAuthoritativeAcrossClockSkew() {
        assertTrue(machinePresenceOnline(true, "2026-08-25T11:00:00Z", now))
        assertFalse(machinePresenceOnline(false, "2026-08-25T11:59:59Z", now))
        assertTrue(machinePresenceOnline(true, "", now))
    }

    @Test
    fun ageLabelIsCompact() {
        assertEquals("5s ago", machinePresenceAgeLabel("2026-08-25T11:59:55Z", now))
        assertEquals("2m ago", machinePresenceAgeLabel("2026-08-25T11:58:00Z", now))
    }
}
