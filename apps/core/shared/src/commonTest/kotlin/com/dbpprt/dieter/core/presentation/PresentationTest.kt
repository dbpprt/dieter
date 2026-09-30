package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.PendingTool
import com.dbpprt.dieter.api.v1.ProviderStatus
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.TaskPlanItem
import com.dbpprt.dieter.api.v1.TaskPlanPhase
import com.dbpprt.dieter.api.v1.TokenUsage
import com.dbpprt.dieter.api.v1.UiMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

class PresentationTest {
    private fun tool(name: String, input: String = "", state: String = "input-available", id: String = name, output: Boolean = false) =
        MessagePart(type = "tool-$name", tool_name = name, tool_call_id = id, state = state, input_json = input.encodeUtf8(), has_output = output)

    private fun text(value: String, state: String = "") = MessagePart(type = "text", text = value, state = state)
    private fun assistant(id: String, vararg parts: MessagePart) = UiMessage(id = id, role = "assistant", parts = parts.toList())
    private fun user(id: String, value: String = "hi") = UiMessage(id = id, role = "user", parts = listOf(text(value)))
    private fun live(vararg messages: UiMessage, pending: List<PendingTool> = emptyList(), plans: List<TaskPlan> = emptyList(), status: String = "running", provider: ProviderStatus? = null, reasoning: Boolean = false) =
        LiveActivities.resolve(messages.toList(), pending, plans, reasoning, status, "running", provider).english()

    @Test
    fun liveLabelsFollowActualToolReasoningAndWritingTransitions() {
        assertEquals("Reading App.kt", live(user("u"), assistant("a", tool("read", """{"path":"src/App.kt"}"""))))
        assertEquals("Running just android test", live(user("u"), assistant("a", tool("bash", """{"command":"just android test"}"""))))
        assertEquals("Writing response…", live(user("u"), assistant("a", tool("bash", "{}", state = "output-available", output = true), text("Done", state = "streaming"))))
        assertEquals("Thinking…", live(user("u")))
        assertEquals("Waiting for approval: bash", live(user("u"), assistant("a", tool("bash", "{}", state = "approval-requested"))))
        assertEquals("Stopping…", live(user("u"), assistant("a", tool("bash", "{}")), status = "cancelling"))
        assertEquals("Reading App.kt · +1 tool", live(user("u"), assistant("a", tool("grep", """{"pattern":"x"}""", id = "1"), tool("read", """{"file_path":"/repo/App.kt"}""", id = "2"))))
        val plan = TaskPlan(message_id = "a", state = "active", phases = listOf(TaskPlanPhase(tasks = listOf(TaskPlanItem(content = "Verify", active_form = "Verifying Android behavior", status = "in_progress")))))
        assertEquals("Verifying Android behavior", live(user("u"), assistant("a", text("")), plans = listOf(plan)))
        assertEquals("Thinking…", live(user("u2"), assistant("a2"), plans = listOf(plan)), "a plan from an earlier turn does not describe this one")
        assertEquals("Reconnecting to provider (2/5)…", live(user("u"), provider = ProviderStatus(state = "reconnecting", attempt = 2, max_attempts = 5)))
        assertEquals("Starting agent…", LiveActivities.resolve(listOf(user("u")), conversationStatus = "starting").english())
        assertEquals("Stale", LiveActivities.reasoningSummary("thinking\n**Stale**\nmore").orEmpty())
    }

    @Test
    fun staleToolsDoNotCrossTheLatestUserTurnAndCompletedToolsStayDone() {
        assertEquals("Thinking…", live(assistant("old", tool("bash", """{"command":"old"}""")), user("u")))
        val done = tool("bash", """{"command":"ls"}""", state = "output-available", id = "t1", output = true)
        assertEquals("Thinking…", live(user("u"), assistant("a", done), pending = listOf(PendingTool(tool_call_id = "t1", tool_name = "bash"))))
    }

    @Test
    fun toolActivityLabelsMatchTheLegacyTables() {
        fun label(name: String, input: String, preview: String = "") = Tools.activity(name, input, preview).english()
        assertEquals("Running go test ./internal/harness", label("exec_command", """{"cmd":"go test ./internal/harness"}"""))
        assertEquals("Editing App.swift", label("apply_patch", """{"path":"Sources/App.swift"}"""))
        assertEquals("Searching SwiftUI status indicator", label("web_search", """{"query":"SwiftUI status indicator"}"""))
        assertEquals("Running go test ./...", label("shell", """{"argv":["go","test","./..."]}"""))
        assertEquals("Verify the runtime", label("bash", """{"description":"Verify the runtime","command":"x"}"""))
        assertEquals("Reading README.md", label("mcp__files__read_file", """{"path":"/repo/README.md"}"""))
        assertEquals("Using get issue…", label("mcp__github__get_issue", """{"id":1}"""))
        assertEquals("Waiting for command…", label("write_stdin", "{}"))
        assertEquals("Running command…", label("bash", "{not json"))
        assertEquals("Editing files…", label("apply_patch", "", "*** Begin Patch"))
        val long = label("bash", """{"command":"${"x".repeat(300)}"}""")
        assertEquals(120, long.length)
        assertTrue(long.endsWith("…"))
        assertEquals(ToolCategory.EDIT, Tools.category("str_replace_editor"))
        assertEquals(ToolCategory.COMMAND, Tools.category("mcp__shell__exec_command"))
        assertEquals(ToolCategory.READ, Tools.category("view_file"))
        assertEquals(ToolCategory.OTHER, Tools.category("get_issue"))
        assertEquals("", Tools.preview(tool("bash", state = "output-error").copy(output_preview = "boom")), "a failed tool previews nothing")
    }

    @Test
    fun activityGroupsAreStableAndApprovalsBreakThem() {
        val reasoning = MessagePart(type = "reasoning", text = "plan")
        val timeline = TimelineBuilder.build(
            listOf(
                user("u"),
                assistant("r1", reasoning, tool("apply_patch", id = "e")),
                assistant("r2", tool("bash", id = "c")),
                assistant("prose", text("Starting"), text("with a plan")),
            ),
            options = TimelineOptions(showReasoning = true),
        )
        assertEquals(listOf("message:u", "tools:r1", "message:prose"), timeline.items.map { it.id })
        val activity = assertIs<TimelineItem.Activity>(timeline.items[1])
        assertEquals("Reasoning · 1 edit · 1 command", activity.summary.english())
        val prose = assertIs<TimelineItem.Message>(timeline.items[2])
        assertEquals("Starting\n\nwith a plan", prose.steps.single().text)

        val grown = TimelineBuilder.build(listOf(user("u"), assistant("r1", reasoning), assistant("r2", tool("bash", id = "c")), assistant("r3", tool("read", id = "d"))), options = TimelineOptions(showReasoning = true))
        assertEquals("tools:r1", grown.items[1].id, "the group keeps its ID while tools stream in")

        val approval = TimelineBuilder.build(listOf(assistant("a", tool("bash", id = "1"), tool("bash", state = "approval-requested", id = "2"), tool("read", id = "3"))))
        val groups = assertIs<TimelineItem.Message>(approval.items.single()).groups
        assertEquals(listOf(true, false, true), groups.map { it.activity })
        assertEquals("1 command · 1 tool call", ActivitySummary(0, mapOf(ToolCategory.OTHER to 1, ToolCategory.COMMAND to 1)).english())
        assertEquals("14 edits · 7 commands", ActivitySummary(0, mapOf(ToolCategory.COMMAND to 7, ToolCategory.EDIT to 14)).english())
    }

    @Test
    fun visibilityHidesEmptyEnvelopesReasoningAndDiagnostics() {
        assertFalse(Parts.isVisible(MessagePart(type = "reasoning", text = "x"), showReasoning = false))
        assertTrue(Parts.isVisible(MessagePart(type = "reasoning", text = "x"), showReasoning = true))
        assertFalse(Parts.isVisible(MessagePart(type = "text", text = " "), false))
        assertFalse(Parts.isVisible(MessagePart(type = "step-start"), false))
        assertFalse(Parts.isVisible(MessagePart(type = "text", text = "boom", state = "error"), false), "diagnostics live in the failure banner")
        assertTrue(Parts.isVisible(MessagePart(type = "file", filename = "a.png"), false))
        assertTrue(Parts.isVisible(MessagePart(type = "custom", text = "fallback"), false))
        assertTrue(Parts.isVisible(MessagePart(type = "dynamic-tool", state = "approval-requested"), false))
        val empty = TimelineBuilder.build(listOf(assistant("a", text(""), MessagePart(type = "step-start"))))
        assertTrue(empty.items.isEmpty())
        val queued = TimelineBuilder.build(listOf(user("u1"), user("q")), queuedIds = setOf("q"))
        assertEquals(listOf("message:u1"), queued.items.map { it.id })
        assertEquals(listOf("message:position:0", "message:position:1"), TimelineBuilder.build(listOf(user(""), user(""))).items.map { it.id })
    }

    @Test
    fun planToolsAreHiddenWhenThePlanIsShown() {
        val plan = TaskPlan(id = "p", message_id = "a")
        val timeline = TimelineBuilder.build(listOf(assistant("a", tool("todowrite", id = "1"), text("Done"))), plans = listOf(plan, TaskPlan(id = "other", message_id = "gone")))
        val item = assertIs<TimelineItem.Message>(timeline.items.single())
        assertEquals(listOf(StepKind.TEXT), item.steps.map { it.kind })
        assertEquals(listOf("other"), timeline.unattachedPlans.map { it.id })
    }

    @Test
    fun usageIsComputedOnce() {
        val metadata = """{"usage":{"totalTokens":150},"contextWindowTokens":1000,"modelId":"sol"}""".encodeUtf8()
        val usage = ContextUsage.latest(listOf(UiMessage(id = "a", metadata_json = metadata), UiMessage(id = "b")))!!
        assertEquals(15, usage.percent)
        assertEquals("sol", usage.modelId)
        assertEquals(1000, ContextUsage.latest(listOf(UiMessage(metadata_json = """{"usage":{"inputTokens":10,"outputTokens":5}}""".encodeUtf8())), fallbackWindow = 1000)!!.windowTokens)
        assertNull(ContextUsage.latest(listOf(UiMessage(metadata_json = """{"usage":{"totalTokens":5}}""".encodeUtf8()))))
        assertTrue(ContextUsage(900, 1000, null).nearLimit)

        val agent = SubagentPresentation(Subagent(tokens = 1_289_000, context_tokens = 128_953, context_window = 1_000_000), Instant.parse("2026-01-01T00:00:00Z"))
        assertEquals(listOf("1.3M processed", "129k / 1.0M context (13%)"), agent.usageMetrics)
        assertEquals(emptyList(), SubagentPresentation(Subagent(), Instant.DISTANT_PAST).usageMetrics)
        assertEquals("Read the remaining routes", SubagentPresentation(Subagent(name = "Agent (agent 2)", assignment = "Read the remaining routes"), Instant.DISTANT_PAST).title)
        assertEquals("agent 2", SubagentPresentation(Subagent(name = "Agent (agent 2)"), Instant.DISTANT_PAST).agentLabel)

        assertEquals("Tokens unavailable", TokenUsagePresentation(TokenUsage()).label())
        assertEquals("125 tokens · partial", TokenUsagePresentation(TokenUsage(total_tokens = 125, reported_messages = 1, partial = true)).label())
        assertEquals("1.2K tokens", TokenUsagePresentation(TokenUsage(total_tokens = 1_234, reported_messages = 2)).label())

        assertEquals("Token usage was not reported by the provider.", TokenCounts.detail(TokenUsage(missing_messages = 1, partial = true)))
        val partial = TokenUsage(reported_messages = 1, input_tokens = 100, output_tokens = 25, total_tokens = 125, partial = true)
        assertTrue(TokenCounts.detail(partial).startsWith("125 total tokens · 100 input · 25 output. Partial provider data"))
        assertFalse(TokenCounts.detail(partial.copy(partial = false)).contains("Partial"))
    }

    @Test
    fun markdownBlocksAndTables() {
        val blocks = Markdown.parse("## Title\nparagraph line\n- one\n* two\n```kotlin\nval x = 1\n```\n| a | b | c | d |\n|---|---:|:---:|:---|\n| 1 | 2 | 3 | 4 |\nafter")
        assertEquals(MarkdownBlock.Heading(2, "Title"), blocks[0])
        assertEquals(MarkdownBlock.Paragraph("paragraph line"), blocks[1])
        assertEquals(listOf(MarkdownBlock.Bullet("one"), MarkdownBlock.Bullet("two")), blocks.subList(2, 4))
        assertEquals(MarkdownBlock.Code("val x = 1", "kotlin"), blocks[4])
        val table = assertIs<MarkdownBlock.Table>(blocks[5])
        assertEquals(listOf(TableAlignment.START, TableAlignment.END, TableAlignment.CENTER, TableAlignment.START), table.alignments)
        assertEquals(listOf(listOf("1", "2", "3", "4")), table.rows)
        assertEquals(MarkdownBlock.Paragraph("after"), blocks[6])
        assertEquals(listOf("name", "a|b", "`x|y`"), Markdown.cells("| name | a\\|b | `x|y` |"))
        assertEquals(listOf(MarkdownBlock.Code("open", "")), Markdown.parse("```\nopen"))
    }

    @Test
    fun contentLinksStayInsideTheWorkspace() {
        val root = "/work/repo"
        assertEquals(ContentLink.File("README.md", 4), ContentLinks.resolve("README.md:4", root))
        assertEquals(ContentLink.File("src/App.kt", 10, 20), ContentLinks.resolve("src/App.kt#L10-L20", root))
        assertEquals(ContentLink.File("docs/guide.md"), ContentLinks.resolve("guide.md", root, relativeTo = "docs/index.md"))
        assertEquals(ContentLink.File("a b.txt"), ContentLinks.resolve("file:///work/repo/a%20b.txt", root))
        assertEquals(ContentLink.Web("https://example.com/x"), ContentLinks.resolve("https://example.com/x", null))
        for ((url, error) in listOf(
            "../outside.txt" to LinkError.OUTSIDE_WORKSPACE, "/etc/passwd" to LinkError.OUTSIDE_WORKSPACE,
            "file://other/work/repo/a" to LinkError.UNSUPPORTED_FILE_HOST, "mailto:x@y" to LinkError.UNSUPPORTED_SCHEME,
            "a.txt:0" to LinkError.INVALID_LINE, "https://" to LinkError.INVALID_WEB_URL,
        )) {
            assertEquals(error, assertFailsWith<LinkException> { ContentLinks.resolve(url, root) }.error, url)
        }
        assertEquals(LinkError.INVALID_WORKSPACE, assertFailsWith<LinkException> { ContentLinks.resolve("a.txt", null) }.error)

        assertEquals("shots/a b.png", WorkspaceImages.path("<shots/a%20b.png>"))
        assertEquals("out/x.png", WorkspaceImages.path("/work/repo/out/x.png", root))
        assertNull(WorkspaceImages.path("../x.png"))
        assertNull(WorkspaceImages.path("notes.txt"))
        assertNull(WorkspaceImages.path("https://example.com/x.png"))

        assertEquals(listOf("http://localhost:3000/app", "http://127.0.0.1:8080"), DetectedLinks.find("Open localhost:3000/app. Or (127.0.0.1:8080).").map { it.url })
        assertTrue(DetectedLinks.find("src/main.go:12 and 999.1.1.1:80 and localhost:70000").isEmpty())
    }

    @Test
    fun deliveryStatesFollowTheOutbox() {
        assertEquals(DeliveryState.LOCAL, Delivery.state("m", setOf("m"), emptySet(), emptySet()))
        assertEquals(DeliveryState.ACCEPTED, Delivery.state("m", setOf("m"), setOf("m"), emptySet()))
        assertEquals(DeliveryState.SYNCED, Delivery.state("m", emptySet(), emptySet(), emptySet()))
        assertEquals(DeliveryState.FAILED, Delivery.state("m", setOf("m"), emptySet(), setOf("m")))
        assertEquals(DeliveryState.QUEUED, Delivery.state("m", setOf("m"), emptySet(), emptySet(), setOf("m")))
        assertEquals("First **paragraph**.\n\nLast `paragraph`.  ", Parts.copyText(assistant("a", text("First **paragraph**."), tool("bash"), MessagePart(type = "reasoning", text = "hidden"), text("Last `paragraph`.  "))))
    }
}
