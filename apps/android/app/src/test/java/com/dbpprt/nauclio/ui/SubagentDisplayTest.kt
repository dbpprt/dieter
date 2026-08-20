package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Subagent
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
    fun usesAUsefulFallbackForBlankTitles() {
        assertEquals("Subagent", cleanSubagentTitle("  "))
        assertEquals("agent", subagentAgentLabel("", ""))
    }
}
