package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionStatusPresentationTest {
    @Test
    fun lastConnectedLabelsUseCompactRelativeAges() {
        val now = 100_000_000L
        assertEquals("Last connected unknown", lastConnectedLabel(null, now))
        assertEquals("Last connected just now", lastConnectedLabel(now - 59_000L, now))
        assertEquals("Last connected 1m ago", lastConnectedLabel(now - 60_000L, now))
        assertEquals("Last connected 1h ago", lastConnectedLabel(now - 3_600_000L, now))
    }
}
