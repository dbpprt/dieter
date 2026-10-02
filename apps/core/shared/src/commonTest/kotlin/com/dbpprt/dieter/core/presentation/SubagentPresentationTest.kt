package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.Subagent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant

class SubagentPresentationTest {
    private val now = Instant.parse("2026-09-30T12:00:00Z")
    private fun present(agent: Subagent) = SubagentPresentation(agent, now)

    @Test
    fun titlesPreferTheConciseNameAndSkipGenericOnes() {
        val named = present(
            Subagent(
                name = "Discover repo structure (agent 3)", agent_type = "Explore",
                task = "Explore the entire repository and return a detailed report", assignment = "Discover repo structure (agent 3)",
            ),
        )
        assertEquals("Discover repo structure", named.title)
        assertEquals("agent 3", named.agentLabel)
        assertEquals("Explore", present(Subagent(name = "Discover repo structure", agent_type = "Explore")).agentLabel)
        val generic = Subagent(name = "task", agent_type = "task", task = "Read the remaining routes", assignment = "Trace every remaining route and report the request flow")
        assertEquals("Read the remaining routes", present(generic).title, "the task wins over the assignment")
        assertEquals("Explore", present(Subagent(name = "worker", agent_type = "Explore")).title)
        assertEquals("Read the remaining routes", present(Subagent(name = "Agent (agent 2)", assignment = "Read the remaining routes")).title, "a generic name stays generic with its suffix")
        assertEquals("Subagent", present(Subagent(name = "  ")).title)
        assertEquals("agent", present(Subagent()).agentLabel)
    }

    @Test
    fun identityStatusAndElapsedTime() {
        assertEquals("claude-code/opus · plugin", present(Subagent(provider = "claude-code", model = "opus", agent_source = "plugin")).identity)
        assertEquals("opus", present(Subagent(model = "opus")).identity)
        assertEquals("local", present(Subagent()).identity)
        assertTrue(present(Subagent(status = "running")).active)
        assertTrue(present(Subagent(status = "Pending")).active)
        assertFalse(present(Subagent(status = "completed")).active)
        assertEquals(2, SubagentPresentation.active(listOf(Subagent(status = "running"), Subagent(status = "pending"), Subagent(status = "failed"))))
        assertTrue(present(Subagent(status = "Completed")).completed)
        assertEquals("running", present(Subagent(status = "running")).statusLabel)
        assertEquals("pending", present(Subagent(status = " ")).statusLabel, "an agent that reported nothing yet is pending")
        assertEquals("45s", present(Subagent(duration_ms = 45_000)).elapsedLabel)
        assertEquals("3m 12s", present(Subagent(started_at = "2026-09-30T11:50:00Z", ended_at = "2026-09-30T11:53:12Z")).elapsedLabel)
        assertEquals("1m 30s", present(Subagent(started_at = "2026-09-30T11:58:30Z")).elapsedLabel, "a running agent counts up to now")
        assertEquals("", present(Subagent()).elapsedLabel)
        assertEquals("", present(Subagent(started_at = "2026-09-30T12:05:00Z")).elapsedLabel, "clock skew never shows negative time")
    }

    @Test
    fun narrativeTechnicalAndCurrentActivityAreDistinct() {
        val agent = present(
            Subagent(
                assignment = "Inspect the Android UI", task = "  Inspect   the Android UI ", description = "Compare the dedicated tab with the conversation",
                current_tool = "functions.exec", current_tool_args = "{\"cmd\":\"rg Subagent\"}", recent_output = listOf("Found CardDetailScreen.kt", "  "),
            ),
        )
        assertEquals(listOf("Assignment", "Description"), agent.narrative.map { it.label }, "a task repeating the assignment is shown once")
        assertEquals(listOf("Current tool", "Recent output"), agent.technical.map { it.label })
        assertEquals(listOf("functions.exec\n{\"cmd\":\"rg Subagent\"}", "Found CardDetailScreen.kt"), agent.technical.map { it.value })
        assertTrue(agent.technical.all { it.monospace })
        assertEquals(listOf("Description", "Current tool", "Recent output"), agent.details.map { it.label })
        assertEquals("Using functions.exec", agent.nowLine)
        assertEquals("Using functions.exec", agent.statusLine)
        assertNull(present(Subagent(name = "Run the tests", activity = "  Run the   tests ")).nowLine, "activity repeating the title adds nothing")
        assertNull(present(Subagent(name = "Worker two", assignment = "Fix the build", activity = "fix the build")).nowLine)
        assertEquals("Compare tabs", present(Subagent(description = " Compare tabs ")).statusLine)
        assertNull(present(Subagent()).statusLine)
    }

    @Test
    fun operationalMetricsIncludeUsageCostAndCaptureState() {
        val agent = present(
            Subagent(
                model = "sol", tool_count = 7, requests = 3, tokens = 1_288_847, context_tokens = 128_953, context_window = 1_000_000,
                cost = 0.423, detached = true, transcript_available = true,
            ),
        )
        assertEquals(
            listOf("7 tool calls", "3 requests", "1.3M processed", "129k / 1.0M context (13%)", "\$0.42", "detached", "transcript captured"),
            agent.operationalMetrics,
        )
        assertEquals(listOf("sol", "7 tools", "1.3M processed", "129k / 1.0M context (13%)"), agent.summaryMetrics)
        assertEquals(0.128953, agent.contextFraction)
        assertNull(present(Subagent()).contextFraction)
        assertEquals(1.0, present(Subagent(context_tokens = 2_000, context_window = 1_000)).contextFraction)
        assertEquals(listOf("1 tool call", "1 request"), present(Subagent(tool_count = 1, requests = 1)).operationalMetrics)
        assertTrue(present(Subagent()).operationalMetrics.isEmpty())
        assertEquals("\$0.0040", SubagentPresentation.cost(0.004))
        assertEquals("\$12.50", SubagentPresentation.cost(12.5))
    }

    @Test
    fun detailSectionsAreBounded() {
        assertEquals("1234…", SubagentPresentation.DetailSection("Output", "123456").bounded(maxChars = 4))
        assertEquals("12…", SubagentPresentation.DetailSection("Output", "12 456").bounded(maxChars = 3))
        assertEquals("short", SubagentPresentation.DetailSection("Output", "short").bounded())
    }
}
