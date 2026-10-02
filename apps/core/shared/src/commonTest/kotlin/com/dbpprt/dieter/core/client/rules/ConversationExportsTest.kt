package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.TaskPlanItem
import com.dbpprt.dieter.api.v1.TaskPlanPhase
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.MessageDelivery
import com.dbpprt.dieter.client.v1.TaskPlanSummary
import com.dbpprt.dieter.client.v1.TimelineMessages
import com.dbpprt.dieter.client.v1.TimelineStepKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant

class ConversationExportsTest {
    @Test
    fun longMessagesRevealTheirGroupsFromTheTail() {
        // Ported from the Mac's longTurnOpensAtTailAndRevealsEveryEarlierGroupWithStableIdentity.
        val ids = (0 until 20).map { "g$it" }
        assertEquals(12, ConversationExports.initialGroups())
        assertEquals(8, ConversationExports.visibleStart(ids, ""))
        assertEquals(3, ConversationExports.visibleStart(ids, "g3"), "a pinned group stays first while output streams")
        assertEquals(8, ConversationExports.visibleStart(ids, "gone"), "a pinned group that left shows the tail")
        assertEquals(0, ConversationExports.visibleStart(ids.take(4), ""))
        assertEquals(0, ConversationExports.visibleStart(emptyList(), "g3"))
        var start = ConversationExports.visibleStart(ids, "")
        while (start > 0) start = ConversationExports.visibleStart(ids, ids[maxOf(0, start - ConversationExports.initialGroups())])
        assertEquals(0, start, "revealing earlier groups reaches the first")
    }

    @Test
    fun timelineRowsLayOutMessagesAsTheConversationSliceDoes() {
        val messages = TimelineMessages(
            messages = listOf(
                UiMessage(id = "u1", role = "user", parts = listOf(MessagePart(type = "text", text = "Fix it"))),
                UiMessage(id = "a1", role = "assistant", parts = listOf(MessagePart(type = "reasoning", text = "Thinking"), MessagePart(type = "dynamic-tool", tool_name = "bash", state = "output-available"))),
                UiMessage(id = "a2", role = "assistant", parts = listOf(MessagePart(type = "dynamic-tool", tool_name = "read", state = "output-available"))),
                UiMessage(id = "a3", role = "assistant", parts = listOf(MessagePart(type = "text", text = "Done"), MessagePart(type = "text", text = "Really"))),
                UiMessage(id = "q", role = "user", parts = listOf(MessagePart(type = "text", text = "queued"))),
            ),
        )
        val rows = ConversationExports.timelineRows(messages, queuedIds = listOf("q"), showReasoning = false).items
        assertEquals(listOf("message:u1", "tools:a1", "message:a3"), rows.map { it.id }, "routine-only messages fold into one row; queued ones are not rows")
        assertEquals(MessageDelivery.MESSAGE_DELIVERY_SYNCED, rows[0].delivery)
        assertTrue(rows[1].activity && rows[1].message_ids == listOf("a1", "a2"))
        assertEquals(2, rows[1].groups.single().steps.count { it.kind == TimelineStepKind.TIMELINE_STEP_KIND_TOOL })
        val prose = rows[2].groups.single().steps.single()
        assertEquals("Done\n\nReally", prose.text, "adjacent prose is coalesced")
        assertTrue(rows[2].copyable)
        val reasoning = ConversationExports.timelineRows(messages, emptyList(), showReasoning = true).items
        assertTrue(reasoning.any { row -> row.groups.any { group -> group.steps.any { it.kind == TimelineStepKind.TIMELINE_STEP_KIND_REASONING } } }, "reasoning shows when asked")
        assertEquals("message:q", reasoning.last().id)
    }

    @Test
    fun copyTextJoinsARowsProse() {
        val messages = TimelineMessages(
            messages = listOf(
                UiMessage(parts = listOf(MessagePart(type = "text", text = "First"), MessagePart(type = "dynamic-tool", tool_name = "bash", output_preview = "x"))),
                UiMessage(parts = listOf(MessagePart(type = "reasoning", text = "hidden"), MessagePart(type = "text", text = "Last  "))),
            ),
        )
        assertEquals("First\n\nLast  ", ConversationExports.copyText(messages))
        assertEquals("", ConversationExports.copyText(TimelineMessages()))
    }

    @Test
    fun taskPlansCountAbandonedWorkAsFinished() {
        val plan = TaskPlan(
            state = "active",
            phases = listOf(
                TaskPlanPhase(
                    tasks = listOf(
                        TaskPlanItem(content = "Write tests", status = "completed"),
                        TaskPlanItem(content = "Drop the old path", status = "abandoned"),
                        TaskPlanItem(content = "Verify", active_form = "Verifying", status = "in_progress"),
                        TaskPlanItem(content = "Ship", status = "pending"),
                    ),
                ),
            ),
        )
        assertEquals(
            TaskPlanSummary(
                completed = 2, total = 4, active = true,
                task_texts = listOf("Write tests", "Drop the old path", "Verifying", "Ship"),
            ),
            ConversationExports.taskPlan(plan),
            "the Mac counted only completed tasks",
        )
        assertEquals(TaskPlanSummary(), ConversationExports.taskPlan(TaskPlan()))
    }

    @Test
    fun subagentsReadAsTheTranscriptShowsThem() {
        // Ported from the Mac's SubagentUsagePresentationTests.
        val now = Instant.parse("2026-09-30T10:05:00Z").toEpochMilliseconds()
        val agent = Subagent(
            id = "s", name = "Researcher (agent 2)", provider = "openai", model = "sol", status = "running",
            tokens = 1_288_847, context_tokens = 128_953, context_window = 1_000_000, started_at = "2026-09-30T10:02:30Z",
            tool_count = 3, assignment = "Find the bug", recent_output = listOf("line"),
        )
        val summary = ConversationExports.subagent(agent, now)
        assertEquals("Researcher", summary.title)
        assertEquals("agent 2", summary.agent_label)
        assertEquals("openai/sol", summary.identity)
        assertTrue(summary.active)
        assertFalse(summary.completed)
        assertEquals("2m 30s", summary.elapsed)
        assertEquals("", summary.status_line, "nothing current and no description")
        val working = ConversationExports.subagent(agent.copy(current_tool = "bash"), now)
        assertEquals("Using bash", working.status_line)
        assertEquals(listOf("Current tool", "Recent output"), working.details.map { it.label })
        assertEquals(listOf("1.3M processed", "129k / 1.0M context (13%)"), summary.usage_metrics)
        assertEquals(0.128953, summary.context_fraction, 1e-9)
        assertEquals(listOf("Assignment"), summary.narrative.map { it.label })
        assertEquals(listOf("Recent output"), summary.details.map { it.label })
        assertTrue(summary.details.single().monospace)

        val unmeasured = ConversationExports.subagent(Subagent(tokens = 1_200), now)
        assertEquals(listOf("1.2k processed"), unmeasured.usage_metrics)
        assertEquals(-1.0, unmeasured.context_fraction, "unknown context")
        assertEquals("", unmeasured.elapsed)
        assertTrue(ConversationExports.subagent(Subagent(), now).usage_metrics.isEmpty())
    }
}
