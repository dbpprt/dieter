package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Subagent
import org.junit.Assert.assertEquals
import org.junit.Test

class SubagentDisplayTest {
    @Test
    fun removesAgentSuffixFromVisibleTaskTitle() {
        assertEquals("Discover repo structure", cleanSubagentTitle("Discover repo structure (agent 3)"))
    }

    @Test
    fun preservesAgentIdentityInTheMetadataFooter() {
        assertEquals("agent 3", subagentAgentLabel("Discover repo structure (agent 3)", "Explore"))
        assertEquals("Explore", subagentAgentLabel("Discover repo structure", "Explore"))
    }

    @Test
    fun prefersTheConciseAgentNameOverTheDispatchPrompt() {
        val subagent = Subagent.newBuilder()
            .setName("Discover repo structure (agent 3)")
            .setTask("Explore the entire repository and return a detailed report")
            .setAssignment("Discover repo structure (agent 3)")
            .build()

        assertEquals("Discover repo structure", subagentDisplayTitle(subagent))
    }

    @Test
    fun replacesAGenericAgentNameWithTheInformativeAssignment() {
        val subagent = Subagent.newBuilder()
            .setName("task")
            .setAgentType("task")
            .setTask("Read the remaining routes")
            .setAssignment("Trace every remaining route and report the request flow")
            .build()

        assertEquals("Read the remaining routes", subagentDisplayTitle(subagent))
    }

    @Test
    fun presentsDistinctNarrativeAndTechnicalDetails() {
        val subagent = Subagent.newBuilder()
            .setAssignment("Inspect the Android UI")
            .setTask("  Inspect   the Android UI ")
            .setDescription("Compare the dedicated tab with the conversation")
            .setCurrentTool("functions.exec")
            .setCurrentToolArgs("{\"cmd\":\"rg Subagent\"}")
            .addRecentOutput("Found CardDetailScreen.kt")
            .build()

        assertEquals(
            listOf("Assignment", "Description"),
            subagentNarrativeSections(subagent).map { it.label },
        )
        assertEquals(
            listOf("Current tool", "Recent output"),
            subagentTechnicalSections(subagent).map { it.label },
        )
    }

    @Test
    fun presentsOperationalMetricsAndRealContextProgress() {
        val subagent = Subagent.newBuilder()
            .setToolCount(7)
            .setRequests(3)
            .setTokens(1_288_847)
            .setContextTokens(128_953)
            .setContextWindow(1_000_000)
            .setCost(0.423)
            .setDetached(true)
            .setTranscriptAvailable(true)
            .build()

        assertEquals(
            listOf(
                "7 tool calls",
                "3 requests",
                "1.3M processed",
                "129k / 1.0M context (13%)",
                "$0.42",
                "detached",
                "transcript captured",
            ),
            subagentOperationalMetrics(subagent),
        )
        assertEquals(0.128953f, subagentContextProgress(subagent))
        assertEquals(null, subagentContextProgress(Subagent.getDefaultInstance()))
    }

    @Test
    fun boundsVeryLargeRawDetails() {
        assertEquals("1234…", boundedSubagentDetail("123456", maxChars = 4))
    }

    @Test
    fun usesAUsefulFallbackForBlankTitles() {
        assertEquals("Subagent", cleanSubagentTitle("  "))
        assertEquals("agent", subagentAgentLabel("", ""))
    }
}
