package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.UiMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

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
    fun routineWorkAcrossMessagesFoldsIntoOneStableGroup() {
        fun message(id: String, vararg parts: MessagePart) = UiMessage(id = id, role = "assistant", parts = parts.toList())
        val user = UiMessage(id = "u", role = "user", parts = listOf(text("hi")))
        val reasoning = part("reasoning", "plan")
        val shown = TimelineOptions(showReasoning = true)
        val timeline = TimelineBuilder.build(listOf(user, message("r1", reasoning, tool("e", "apply_patch")), message("r2", tool("c")), message("prose", text("Starting"), text("with a plan"))), options = shown)
        assertEquals(listOf("message:u", "tools:r1", "message:prose"), timeline.items.map { it.id })
        assertEquals("Reasoning · 1 edit · 1 command", assertIs<TimelineItem.Activity>(timeline.items[1]).summary.english())
        assertEquals("Starting\n\nwith a plan", assertIs<TimelineItem.Message>(timeline.items[2]).steps.single().text, "adjacent prose reads as one step")
        val grown = TimelineBuilder.build(listOf(user, message("r1", reasoning), message("r2", tool("c")), message("r3", tool("d", "read"))), options = shown)
        assertEquals("tools:r1", grown.items[1].id, "the group keeps its ID while tools stream in")
        assertEquals("1 command · 1 tool call", ActivitySummary(0, mapOf(ToolCategory.OTHER to 1, ToolCategory.COMMAND to 1)).english())
        assertEquals("14 edits · 7 commands", ActivitySummary(0, mapOf(ToolCategory.COMMAND to 7, ToolCategory.EDIT to 14)).english())
        val unnamed = UiMessage(role = "user", parts = listOf(text("hi")))
        assertEquals(listOf("message:position:0", "message:position:1"), TimelineBuilder.build(listOf(unnamed, unnamed)).items.map { it.id }, "messages without an ID are keyed by position")
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
    fun emptyEnvelopesAndTheBannersDiagnosticsRenderNothing() {
        // The failure banner covers message "a", so its diagnostic part is left to the banner.
        val shown = TimelineOptions(showReasoning = true, failedMessageId = "a")
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
    fun copyingAMessageTakesItsProseOnly() {
        val message = assistant(text("First **paragraph**."), tool("t"), part("reasoning", "hidden"), MessagePart(type = "file", filename = "a.png", text = "a.png"), text("Last `paragraph`.  "))
        assertEquals("First **paragraph**.\n\nLast `paragraph`.  ", Parts.copyText(message))
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

    @Test
    fun failureDiagnosticsShowAsAttentionOutsideTheBannersMessage() {
        // Ported from the Mac's diagnosticsRemainVisibleEvenWhenReasoningIsHidden.
        val diagnostic = MessagePart(type = "reasoning", text = "Provider failed", state = "error", error_text = "Connection closed")
        val message = assistant(diagnostic)
        val item = assertIs<TimelineItem.Message>(TimelineBuilder.build(listOf(message)).items.single(), "an earlier turn's error stays readable, even with reasoning hidden")
        assertEquals(listOf(StepKind.ATTENTION), item.steps.map { it.kind })
        assertEquals(listOf(false), item.groups.map { it.activity })
        assertTrue(TimelineBuilder.build(listOf(message), options = TimelineOptions(failedMessageId = "a")).items.isEmpty(), "the banner carries its own message's diagnostics")

        val toolAndError = assistant(tool("t"), MessagePart(type = "text", state = "error", text = "Turn failed — exited 1"))
        assertEquals(listOf(StepKind.TOOL, StepKind.ATTENTION), assertIs<TimelineItem.Message>(TimelineBuilder.build(listOf(toolAndError)).items.single()).steps.map { it.kind })
        assertIs<TimelineItem.Activity>(TimelineBuilder.build(listOf(toolAndError), options = TimelineOptions(failedMessageId = "a")).items.single())
        assertTrue(Parts.isVisible(diagnostic, showReasoning = false, hideFailures = false))
        assertFalse(Parts.isVisible(diagnostic, showReasoning = true))
    }

    @Test
    fun alternatingReasoningAndToolsBecomeOneStableActivity() {
        // Ported from the Mac's alternatingReasoningAndToolsBecomeOneStableSummaryBetweenMessages;
        // the Mac keyed this run "message:r1", the core keys every routine run "tools:<first>".
        fun message(id: String, vararg parts: MessagePart, role: String = "assistant") = UiMessage(id = id, role = role, parts = parts.toList())
        val messages = listOf(
            message("user", text("Please investigate"), role = "user"),
            message("r1", part("reasoning", "Inspect first")),
            message("t1", tool("1", "exec_command")),
            message("r2", part("thinking", "Apply the change")),
            message("t2", MessagePart(type = "tool-apply_patch", tool_call_id = "2")),
            message("answer", text("Implemented.")),
        )
        val shown = TimelineOptions(showReasoning = true)
        val timeline = TimelineBuilder.build(messages, options = shown)
        assertEquals(listOf("message:user", "tools:r1", "message:answer"), timeline.items.map { it.id })
        val activity = assertIs<TimelineItem.Activity>(timeline.items[1])
        assertEquals(listOf("r1", "t1", "r2", "t2"), activity.messageIds)
        assertEquals(2, activity.summary.reasoning)
        assertEquals("Reasoning · 1 edit · 1 command", activity.summary.english())
        val growing = TimelineBuilder.build(messages.dropLast(1) + message("t3", tool("3", "Read")), options = shown)
        assertEquals(activity.id, growing.items[1].id, "incoming tool calls grow the same disclosure")
        assertEquals(listOf("r1", "t1", "r2", "t2", "t3"), growing.items[1].messageIds)
    }

    @Test
    fun mixedAssistantMessagesKeepProseVisibleAndCoalesceIt() {
        // Ported from the Mac's mixedAssistantMessageKeepsProseVisibleAndCoalescesTextSelection.
        val source = UiMessage(
            id = "mixed", role = "assistant",
            parts = listOf(
                text("Starting"), text("with a plan"), part("reasoning", "Inspect"), tool("b", "Bash"),
                part("thinking", "Check"), tool("r", "Read"), text("Finished"), MessagePart(type = "image", url = "data:image/png;base64,eA=="),
            ),
        )
        val groups = TimelineBuilder.group(TimelineBuilder.steps(source, "mixed", TimelineOptions(showReasoning = true), hidePlanTools = false))
        assertEquals(listOf(false, true, false, false), groups.map { it.activity })
        assertEquals("Starting\n\nwith a plan", groups[0].steps.single().text)
        assertEquals(0, groups[0].steps.single().partIndex, "coalesced prose points at its first part")
        assertEquals(listOf("reasoning", "dynamic-tool", "thinking", "dynamic-tool"), groups[1].steps.map { it.part.type })
        assertEquals(listOf(2, 3, 4, 5), groups[1].steps.map { it.partIndex })
        assertEquals("Finished", groups[2].steps.single().text)
        assertEquals(StepKind.ATTACHMENT, groups[3].steps.single().kind)
        assertIs<TimelineItem.Message>(TimelineBuilder.build(listOf(source), options = TimelineOptions(showReasoning = true)).items.single())
    }

    @Test
    fun failedToolsStayInActivityWhileApprovalsAndUserMessagesBreakIt() {
        // Ported from the Mac's toolFailuresStayInActivityWhileApprovalsAndUserMessagesBreakGroups.
        val failed = tool("failed", "Bash", state = "output-error").copy(error_text = "The command exited with status 1")
        val approval = tool("approval", "Write", state = "approval-requested")
        val messages = listOf(
            UiMessage(id = "r1", role = "assistant", parts = listOf(part("reasoning", "Thinking"))),
            UiMessage(id = "failed", role = "assistant", parts = listOf(failed)),
            UiMessage(id = "r2", role = "assistant", parts = listOf(part("reasoning", "Recovering"))),
            UiMessage(id = "approval", role = "assistant", parts = listOf(approval)),
            UiMessage(id = "human", role = "Human", parts = listOf(part("reasoning", "This is my text"))),
        )
        val items = TimelineBuilder.build(messages, options = TimelineOptions(showReasoning = true)).items
        assertEquals(listOf("tools:r1", "message:approval", "message:human"), items.map { it.id })
        assertTrue(assertIs<TimelineItem.Message>(items[2]).user, "a human message is the user's, in any case")
        assertTrue(Parts.needsAttention(failed) && Parts.needsAttention(approval))
        assertEquals(failed.error_text, assertIs<TimelineItem.Activity>(items[0]).steps[1].part.error_text)
    }

    @Test
    fun hiddenReasoningAddsNoRowsAndPlansKeepTheirMessage() {
        // Ported from the Mac's hiddenReasoningDoesNotCreateExtraRowsAndStructuredDetailsStayVisible.
        val messages = listOf(
            UiMessage(id = "r1", role = "assistant", parts = listOf(part("reasoning", "Thinking"))),
            UiMessage(id = "tool", role = "assistant", parts = listOf(tool("b", "Bash"))),
            UiMessage(id = "r2", role = "assistant", parts = listOf(part("thinking", "Checking"))),
            UiMessage(id = "tool2", role = "assistant", parts = listOf(tool("r", "Read"))),
        )
        val hidden = assertIs<TimelineItem.Activity>(TimelineBuilder.build(messages).items.single())
        assertEquals(listOf("Bash", "Read"), hidden.steps.map { Parts.toolName(it.part) })
        assertEquals(listOf("tool", "tool2"), hidden.messageIds)
        assertEquals("1 command · 1 read", hidden.summary.english(), "the Mac titled this \"1 command · 1 tool call\"")
        val withPlan = TimelineBuilder.build(messages, plans = listOf(TaskPlan(id = "plan", message_id = "tool")), options = TimelineOptions(showReasoning = true))
        assertEquals(listOf("tools:r1", "message:tool", "tools:r2"), withPlan.items.map { it.id })
        assertEquals(listOf("plan"), assertIs<TimelineItem.Message>(withPlan.items[1]).plans.map { it.id })
    }

    @Test
    fun toolCallsGroupBetweenProseAndNameTheirCategories() {
        // Ported from the Mac's assistantMessagePartsCollapseAdjacentToolCallsIntoGroups,
        // hiddenReasoningDoesNotSplitAdjacentToolCallGroups, prefixedToolPartTypesGroupAndDeriveToolNames,
        // and toolCallGroupSummaryMatchesCompactEditAndCommandLabels.
        fun names(groups: List<StepGroup>) = groups.map { group -> group.steps.map { Parts.toolName(it.part) } }
        val mixed = TimelineBuilder.group(
            steps(listOf(text("Starting"), tool("bash", "Bash"), MessagePart(type = "tool-call", tool_name = "Edit"), text("Finished"), MessagePart(type = "tool", tool_name = "browser.open"))),
        )
        assertEquals(listOf(false, true, false, true), mixed.map { it.activity })
        assertEquals(listOf("Bash", "Edit"), names(mixed)[1])

        val reasoning = part("reasoning", "Thinking about the change")
        assertEquals(listOf(listOf("Bash", "Edit")), names(TimelineBuilder.group(steps(listOf(reasoning, tool("b", "Bash"), reasoning, tool("e", "Edit"))))))
        assertEquals(listOf(4), TimelineBuilder.group(steps(listOf(reasoning, tool("b", "Bash"), reasoning, tool("e", "Edit")), reasoning = true)).map { it.steps.size }, "visible reasoning joins the routine group (the Mac split it into four)")
        assertEquals(listOf(listOf("Bash", "Edit")), names(TimelineBuilder.group(steps(listOf(tool("b", "Bash"), part("reasoning", "  \n"), tool("e", "Edit")), reasoning = true))))

        val prefixed = TimelineBuilder.group(steps(listOf(MessagePart(type = "tool-Read"), MessagePart(type = "tool-Bash"))))
        assertTrue(prefixed.single().activity)
        assertEquals(listOf(listOf("Read", "Bash")), names(prefixed))
        assertEquals("1 command · 1 read", ActivitySummary.of(prefixed.single().steps).english(), "the Mac titled this \"1 command, 1 tool call\"")

        assertEquals("1 command", ActivitySummary.ofTools(listOf("Bash")).english())
        assertEquals("14 edits · 7 commands", ActivitySummary.ofTools(List(14) { "Edit" } + List(7) { "exec_command" }).english())
        assertEquals("2 tool calls", ActivitySummary.ofTools(listOf("browser.open", "mcp/custom")).english())
        assertEquals("1 read", ActivitySummary.ofTools(listOf("mcp__files__read_file")).english())
        assertEquals("1 write", ActivitySummary.ofTools(listOf("write_file")).english(), "the Mac counted write_file as an edit")
    }

    @Test
    fun adjacentToolOnlyMessagesFoldIntoOneStableRow() {
        // Ported from the Mac's adjacentToolOnlyAssistantMessagesCollapseIntoOneStableTimelineGroup and
        // reasoningOnlyMessagesMergeIntoToolTimelineGroupsWhenReasoningHidden.
        val items = TimelineBuilder.build(
            listOf(
                UiMessage(id = "message_1", role = "assistant", parts = listOf(tool("tool_1", "exec_command"))),
                UiMessage(id = "message_2", role = "assistant", parts = listOf(MessagePart(type = "tool-call", tool_call_id = "tool_2", tool_name = "apply_patch"))),
                UiMessage(id = "message_3", role = "assistant", parts = listOf(text("Implemented."))),
            ),
        ).items
        assertEquals(listOf("tools:message_1", "message:message_3"), items.map { it.id })
        assertEquals(listOf("exec_command", "apply_patch"), assertIs<TimelineItem.Activity>(items[0]).steps.map { Parts.toolName(it.part) })

        val traced = UiMessage(id = "message_1", role = "assistant", parts = listOf(part("reasoning", "Deliberating"), tool("tool_1", "Bash")))
        assertEquals(listOf("tools:message_1"), TimelineBuilder.build(listOf(traced)).items.map { it.id })
        assertEquals(listOf("tools:message_1"), TimelineBuilder.build(listOf(traced), options = TimelineOptions(showReasoning = true)).items.map { it.id }, "visible reasoning is routine too")
    }

    @Test
    fun rowsCopyTheirProseAndShowTheirLastMessagesTime() {
        // Ported from the Mac's MessageFooterTests.
        val source = "  # A heading\n\n**Bold** and [a link](https://example.com).\n\n```swift\nlet emoji = \"👋\"\n```\n\n"
        for (role in listOf("user", "assistant")) {
            val message = UiMessage(id = "m", role = role, parts = listOf(text(source)), metadata_json = """{"createdAt":"2026-09-10T12:34:56.123Z"}""".encodeUtf8())
            val item = TimelineBuilder.build(listOf(message)).items.single()
            assertEquals(source, Parts.copyText(message), "the original Markdown, whitespace included")
            assertTrue(item.copyable)
            assertEquals(Instant.parse("2026-09-10T12:34:56.123Z"), item.createdAt)
        }
        val mixed = UiMessage(
            id = "x", role = "assistant",
            parts = listOf(
                text("First **paragraph**.\n"), MessagePart(type = "file", filename = "screenshot.png", text = "Attachment metadata"),
                MessagePart(type = "tool-exec", input_preview = "echo preview", output_preview = "Tool output preview"),
                part("reasoning", "Private reasoning is separate from the response"), text("Last `paragraph`.  "),
            ),
        )
        assertEquals("First **paragraph**.\n\n\nLast `paragraph`.  ", Parts.copyText(mixed))
        val toolOnly = UiMessage(id = "t", role = "assistant", parts = listOf(MessagePart(type = "tool", output_preview = "A preview is not the full tool result")))
        assertFalse(Parts.isCopyable(toolOnly))
        assertFalse(TimelineBuilder.build(listOf(toolOnly)).items.single().copyable)

        val first = UiMessage(id = "first", role = "assistant", parts = listOf(tool("1")), metadata_json = """{"createdAt":"2026-09-10T12:00:00Z"}""".encodeUtf8())
        val last = UiMessage(id = "last", role = "assistant", parts = listOf(tool("2")), metadata_json = """{"createdAt":"2026-09-10T13:45:00Z"}""".encodeUtf8())
        assertEquals(Instant.parse("2026-09-10T13:45:00Z"), TimelineBuilder.build(listOf(first, last)).items.single().createdAt, "a row shows its last message's time")
        for (invalid in listOf("", "not JSON", """{"createdAt":"invalid"}""")) {
            assertNull(TimelineBuilder.build(listOf(first, last.copy(metadata_json = invalid.encodeUtf8()))).items.single().createdAt, "never an earlier message's time: $invalid")
        }
        assertEquals("First\n\nLast", Parts.copyText(listOf(UiMessage(parts = listOf(text("First"))), UiMessage(parts = listOf(text("Last"))))))
    }

    @Test
    fun theCacheRereadsOnlyChangedMessages() {
        val cache = TimelineCache()
        val user = UiMessage(id = "u", role = "user", parts = listOf(text("hi")))
        val reply = UiMessage(id = "a", role = "assistant", parts = listOf(text("Hel")))
        val first = TimelineBuilder.build(listOf(user, reply), cache = cache)
        assertEquals(TimelineBuilder.build(listOf(user, reply)), first)
        val streamed = reply.copy(parts = listOf(text("Hello"), tool("t")))
        val second = TimelineBuilder.build(listOf(user, streamed), cache = cache)
        assertEquals(TimelineBuilder.build(listOf(user, streamed)), second)
        assertSame(assertIs<TimelineItem.Message>(first.items[0]).groups, assertIs<TimelineItem.Message>(second.items[0]).groups, "an unchanged message is not read again")
        val options = TimelineOptions(showReasoning = true, failedMessageId = "a")
        assertEquals(TimelineBuilder.build(listOf(user, streamed), options = options), TimelineBuilder.build(listOf(user, streamed), options = options, cache = cache), "changed options read again")
        assertEquals(TimelineBuilder.build(listOf(streamed)), TimelineBuilder.build(listOf(streamed), cache = cache))
    }
}
