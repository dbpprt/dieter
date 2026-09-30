package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.UiMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class TimelineTest {
    private fun text(value: String) = MessagePart(type = "text", text = value)
    private fun tool(id: String, name: String = "bash", state: String = "") = MessagePart(type = "dynamic-tool", tool_call_id = id, tool_name = name, state = state)
    private fun part(type: String, text: String = "") = MessagePart(type = type, text = text)
    private fun assistant(vararg parts: MessagePart) = UiMessage(id = "a", role = "assistant", parts = parts.toList())

    private fun steps(parts: List<MessagePart>, reasoning: Boolean = false, subagents: List<Subagent> = emptyList()) =
        TimelineBuilder.steps(UiMessage(id = "a", role = "assistant", parts = parts), "a", TimelineOptions(showReasoning = reasoning), hidePlanTools = false, subagents = subagents)

    private fun List<StepGroup>.toolIds() = filter { it.activity }.map { group -> group.steps.map { it.part.tool_call_id } }

    @Test
    fun routineGroupsSplitAroundVisibleProse() {
        val groups = TimelineBuilder.group(
            steps(listOf(text("First"), tool("a"), tool("b"), part("step-start"), text("Middle"), tool("c"), part("reasoning", "Hidden trace"), tool("d"), text("Last"))),
        )
        assertEquals(listOf(false, true, false, true, false), groups.map { it.activity })
        assertEquals(listOf(listOf("a", "b"), listOf("c", "d")), groups.toolIds())
        assertEquals(listOf("First", "Middle", "Last"), groups.filterNot { it.activity }.map { it.steps.single().text })

        val traced = TimelineBuilder.group(steps(listOf(tool("a"), part("reasoning", "Inspecting"), tool("b")), reasoning = true))
        assertEquals(listOf(listOf(StepKind.TOOL, StepKind.REASONING, StepKind.TOOL)), traced.map { group -> group.steps.map { it.kind } }, "visible reasoning is routine activity")
        assertTrue(traced.single().activity)
    }

    @Test
    fun failedToolsStayInTheRoutineGroupButApprovalsInterruptIt() {
        val failed = tool("failed", state = "output-error").copy(error_text = "{\"error\":\"command exited 1\"}", output_preview = "{\"error\":\"command exited 1\"}")
        val approval = tool("approval", state = "approval-requested")
        val groups = TimelineBuilder.group(steps(listOf(tool("before"), failed, tool("after"), approval, tool("later"))))
        assertEquals(listOf(true, false, true), groups.map { it.activity })
        assertEquals(listOf(listOf("before", "failed", "after"), listOf("later")), groups.toolIds())
        assertEquals(approval, groups[1].steps.single().part)
        assertEquals(ToolStatus.FAILED, Tools.status(failed))
        assertEquals(ToolStatus.NEEDS_APPROVAL, Tools.status(approval))
        assertIs<TimelineItem.Activity>(TimelineBuilder.build(listOf(assistant(tool("before"), failed))).items.single(), "a failed tool still folds into activity")
        assertTrue(Parts.isRoutineActivity(failed))
        assertFalse(Parts.isRoutineActivity(approval))
        assertTrue(Parts.isRoutineActivity(part("reasoning", "x")))
        assertFalse(Parts.isRoutineActivity(MessagePart(type = "reasoning", text = "x", state = "error")))
        assertFalse(Parts.isRoutineActivity(text("x")))
    }

    @Test
    fun delegatedAgentsTakeThePlaceOfTheirFirstDelegatingCall() {
        val child = Subagent(id = "child", message_id = "a", parent_tool_call_id = "delegate")
        val plan = TaskPlan(id = "plan", message_id = "a")
        val timeline = TimelineBuilder.build(
            listOf(assistant(tool("a"), tool("delegate", "task"), text("After delegation"), tool("plan", "update_plan"), tool("b"))),
            plans = listOf(plan),
            subagents = listOf(child),
        )
        val item = assertIs<TimelineItem.Message>(timeline.items.single())
        assertEquals(listOf(StepKind.TOOL, StepKind.SUBAGENTS, StepKind.TEXT, StepKind.TOOL), item.steps.map { it.kind }, "the rendered plan hides its tool call")
        assertEquals(listOf("a", "b"), item.steps.filter { it.kind == StepKind.TOOL }.map { it.part.tool_call_id })
        assertEquals("a:subagents", item.steps[1].id)
        assertEquals(listOf(true, false, false, true), item.groups.map { it.activity })
        assertEquals(listOf(child), item.subagents)
        assertEquals(listOf(plan), item.plans)
        assertIs<TimelineItem.Activity>(TimelineBuilder.build(listOf(assistant(tool("plan", "update_plan")))).items.single(), "without a rendered plan its tool call stays")

        val agents = listOf(Subagent(id = "one", parent_tool_call_id = "d1"), Subagent(id = "two", parent_tool_call_id = "d2"))
        assertEquals(listOf(StepKind.TEXT, StepKind.SUBAGENTS, StepKind.TEXT), steps(listOf(text("Plan"), tool("d1", "task"), text("Waiting"), tool("d2", "task")), subagents = agents).map { it.kind })
        assertEquals(listOf(StepKind.TEXT, StepKind.TOOL, StepKind.SUBAGENTS), steps(listOf(text("Done"), tool("x")), subagents = listOf(Subagent(id = "free"), Subagent(id = "elsewhere", parent_tool_call_id = "gone"))).map { it.kind }, "agents without a delegating call follow the message")
        assertEquals(listOf(StepKind.TOOL, StepKind.SUBAGENTS), steps(listOf(tool("d1", "task", state = "approval-requested")), subagents = listOf(Subagent(parent_tool_call_id = "d1"))).map { it.kind }, "an approval is never hidden behind its agents")
    }

    @Test
    fun structuredActivityRendersWithoutParts() {
        val empty = UiMessage(id = "e", role = "assistant")
        assertTrue(TimelineBuilder.build(listOf(empty)).items.isEmpty())
        val planned = assertIs<TimelineItem.Message>(TimelineBuilder.build(listOf(empty), plans = listOf(TaskPlan(id = "plan", message_id = "e"))).items.single())
        assertTrue(planned.steps.isEmpty())
        val delegated = assertIs<TimelineItem.Message>(TimelineBuilder.build(listOf(empty), subagents = listOf(Subagent(id = "worker", message_id = "e"))).items.single())
        assertEquals(listOf(StepKind.SUBAGENTS), delegated.steps.map { it.kind })
    }

    @Test
    fun emptyEnvelopesAndDiagnosticsRenderNothing() {
        val shown = TimelineOptions(showReasoning = true)
        val envelopes = listOf(
            assistant(), assistant(text("   ")), assistant(part("reasoning", "")), assistant(part("step-start", "step")),
            assistant(MessagePart(type = "text", state = "error", text = "Turn failed — codex exited 1\nprovider stderr")),
        )
        for (message in envelopes) assertTrue(TimelineBuilder.build(listOf(message), options = shown).items.isEmpty(), message.parts.toString())
        assertTrue(Parts.isVisible(part("tool-call"), false))
        assertTrue(Parts.isVisible(part("dynamic-tool"), false))
        assertFalse(Parts.isVisible(part("image"), false), "an image without content has nothing to show")
        assertTrue(Parts.isVisible(MessagePart(type = "image", url = "data:image/png;base64,iVBORw0KGgo="), false))
        assertEquals("read_file", Parts.toolName(part("tool-read_file")))
    }

    @Test
    fun reasoningOnlyMessagesFollowTheVisibilitySetting() {
        assertFalse(TimelineOptions().showReasoning)
        val reasoning = assistant(part("reasoning", "Considering the request"))
        assertTrue(TimelineBuilder.build(listOf(reasoning)).items.isEmpty())
        assertIs<TimelineItem.Activity>(TimelineBuilder.build(listOf(reasoning), options = TimelineOptions(showReasoning = true)).items.single())
        val mixed = assertIs<TimelineItem.Message>(TimelineBuilder.build(listOf(assistant(part("reasoning", "Trace"), text("Answer")))).items.single())
        assertEquals(listOf(StepKind.TEXT), mixed.steps.map { it.kind })
        val custom = part("custom-diagnostic", "Visible extension content")
        val file = MessagePart(type = "file", filename = "screen.png")
        assertEquals(listOf(StepKind.REASONING, StepKind.OTHER, StepKind.ATTACHMENT), steps(listOf(part("reasoning", "Trace"), custom, file), reasoning = true).map { it.kind })
        assertEquals(listOf(StepKind.OTHER, StepKind.ATTACHMENT), steps(listOf(part("reasoning", "Trace"), custom, file)).map { it.kind }, "hidden reasoning never falls through to text")
    }

    @Test
    fun historyWindowStartsAtTheTailAndKeepsItsBoundaryWhileStreaming() {
        val parts = (0 until 340).flatMap { listOf(text("Step $it"), tool("$it")) }
        val groups = TimelineBuilder.group(steps(parts))
        assertEquals(680, groups.size)
        val start = TimelineBuilder.visibleStart(groups)
        assertEquals(TimelineBuilder.INITIAL_GROUPS, groups.size - start)
        val streamed = TimelineBuilder.group(steps(parts + text("Step 340")))
        assertEquals(start, TimelineBuilder.visibleStart(streamed, groups[start].id), "new output does not move the first shown group")
        assertEquals("Step 0", groups[TimelineBuilder.visibleStart(groups, groups.first().id)].steps.single().text)
        assertEquals(8, TimelineBuilder.visibleStart(groups.take(20), groups[start].id), "a shorter replacement shows its tail")
        assertEquals(0, TimelineBuilder.visibleStart(groups.take(4)))
        assertEquals(0, TimelineBuilder.visibleStart(emptyList(), groups[start].id))
    }
}
