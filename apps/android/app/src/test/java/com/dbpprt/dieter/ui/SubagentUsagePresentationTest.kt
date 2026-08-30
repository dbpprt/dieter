package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SubagentUsagePresentationTest {
    @Test
    fun distinguishesCumulativeProcessingFromCurrentContext() {
        assertEquals(
            listOf("1.3M processed", "129k / 1.0M context (13%)"),
            subagentUsageMetrics(tokens = 1_288_847, contextTokens = 128_953, contextWindow = 1_000_000),
        )
    }

    @Test
    fun omitsUnavailableMeasurements() {
        assertEquals(emptyList<String>(), subagentUsageMetrics(tokens = 0, contextTokens = 0, contextWindow = 0))
        assertEquals(listOf("1.2k processed"), subagentUsageMetrics(tokens = 1_200, contextTokens = 0, contextWindow = 0))
    }
}
