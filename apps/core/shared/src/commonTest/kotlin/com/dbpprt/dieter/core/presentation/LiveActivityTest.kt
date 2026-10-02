package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.PendingTool
import com.dbpprt.dieter.api.v1.ProviderStatus
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.TaskPlanItem
import com.dbpprt.dieter.api.v1.TaskPlanPhase
import com.dbpprt.dieter.api.v1.UiMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

class LiveActivityTest {
    private fun tool(name: String, preview: String = "", state: String = "input-available", id: String = "call") =
        MessagePart(type = "dynamic-tool", tool_name = name, tool_call_id = id, state = state, input_preview = preview)

    private fun user(id: String = "u", createdAt: String = "") = UiMessage(
        id = id, role = "user", parts = listOf(MessagePart(type = "text", text = "go")),
        metadata_json = (if (createdAt.isEmpty()) "" else """{"createdAt":"$createdAt"}""").encodeUtf8(),
    )

    private fun assistant(vararg parts: MessagePart) = UiMessage(id = "a", role = "assistant", parts = parts.toList())

    private fun live(vararg parts: MessagePart, reasoning: Boolean = false, runtime: String = "running", provider: ProviderStatus? = null, pending: List<PendingTool> = emptyList()) =
        LiveActivities.resolve(
            listOf(user(), assistant(*parts)), pendingTools = pending, showReasoning = reasoning,
            conversationStatus = "running", cardRuntime = runtime, providerStatus = provider,
        ).english()

    @Test
    fun previewsDescribeToolsWhoseArgumentsHaveNotStreamed() {
        assertEquals("Reading App.kt", live(tool("Read", "/workspace/App.kt")))
        assertEquals("Running just android test", live(tool("exec_command", """{"cmd":"just android test"}""")))
        assertEquals("Running go test ./...", live(tool("bash", "go test ./...")))
        assertEquals("Thinking…", live(tool("Read", "App.kt", state = "output-available")), "a finished tool no longer describes the turn")
        assertEquals("Reading App.kt · +2 tools", live(tool("bash", "go test", id = "1"), tool("bash", "go vet", id = "2"), tool("Read", "App.kt", id = "3")))
        assertEquals("Waiting for approval: create issue", live(tool("mcp__github__create_issue", state = "approval-requested")))
        val pending = PendingTool(tool_call_id = "p", tool_name = "bash", input_preview = "make build")
        assertEquals("Running make build", live(pending = listOf(pending)), "a pending tool not yet in the transcript describes the turn")
    }

    @Test
    fun streamedArgumentsPlansAndCancelsDescribeTheTurn() {
        val read = MessagePart(type = "tool-read", tool_call_id = "r", state = "input-available", input_json = """{"path":"src/App.kt"}""".encodeUtf8())
        assertEquals("Reading App.kt", live(read), "streamed arguments describe the tool")
        assertEquals("Reading App.kt · +1 tool", live(tool("grep", "x", id = "1"), read))
        assertEquals("Stopping…", LiveActivities.resolve(listOf(user(), assistant(read)), conversationStatus = "cancelling").english())
        val done = tool("bash", "ls", state = "output-available", id = "t1")
        assertEquals("Thinking…", live(done, pending = listOf(PendingTool(tool_call_id = "t1", tool_name = "bash"))), "a finished tool stays done while its pending copy lingers")

        val verifying = TaskPlanItem(content = "Verify", active_form = "Verifying Android behavior", status = "in_progress")
        val plan = TaskPlan(message_id = "a", state = "active", phases = listOf(TaskPlanPhase(tasks = listOf(verifying))))
        assertEquals("Verifying Android behavior", LiveActivities.resolve(listOf(user(), assistant()), plans = listOf(plan)).english())
        assertEquals("Thinking…", LiveActivities.resolve(listOf(user(), assistant(), user("u2")), plans = listOf(plan)).english(), "a plan from an earlier turn does not describe this one")
    }

    @Test
    fun toolActivityLabelsDescribeEachToolFamily() {
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
    fun reasoningSummariesShowOnlyWhenReasoningIsVisible() {
        val reasoning = MessagePart(type = "reasoning", text = "**Checking the results**\n\nDetails", state = "streaming")
        assertEquals("Checking the results", live(reasoning, reasoning = true))
        assertEquals("Thinking…", live(reasoning))
        assertEquals("Inspecting files", LiveActivities.reasoningSummary("Some notes\n## Inspecting files ##\nmore"))
        assertEquals("Short single line", LiveActivities.reasoningSummary("  Short single line "))
        assertNull(LiveActivities.reasoningSummary("line one\nline two"))
    }

    @Test
    fun retryingProviderStreamDescribesTheTurnUntilItRecovers() {
        val reconnecting = ProviderStatus(state = "reconnecting", attempt = 2, max_attempts = 5)
        val running = tool("bash", "go test ./...")
        assertEquals("Reconnecting to provider (2/5)…", live(running, provider = reconnecting), "a retrying stream wins over the running tool")
        assertEquals("Reconnecting to provider (waiting for network)…", live(running, provider = ProviderStatus(state = "waiting-for-network")))
        assertEquals("Reconnecting to provider…", ProviderStatuses.label(reconnecting.copy(attempt = 0)))
        assertEquals("Reconnecting to provider…", ProviderStatuses.label(reconnecting.copy(max_attempts = 0)))
        assertEquals("Stopping…", live(running, runtime = "cancelling", provider = reconnecting), "a cancel wins over a retrying stream")
        assertEquals("Running go test ./...", live(running, provider = ProviderStatus(state = "future")), "unknown states fall through")
        assertNull(ProviderStatuses.label(ProviderStatus(state = "future")))
        assertNull(ProviderStatuses.label(null))
        assertEquals("Thinking…", LiveActivity.Provider(ProviderStatus(state = "future")).english())
        assertFalse(ProviderStatuses.active(null))
        assertFalse(ProviderStatuses.active(ProviderStatus()))
        assertTrue(ProviderStatuses.active(reconnecting))
    }

    @Test
    fun turnTimerStartsAtTheLatestUserMessageAndReadsAsAClock() {
        val start = Instant.parse("2026-09-12T10:00:00Z")
        val messages = listOf(user("old", "2026-09-12T09:00:00Z"), assistant(), user("u", "2026-09-12T10:00:00Z"))
        assertEquals(start, LiveActivities.turnStart(messages, "2026-09-12T11:00:00Z"))
        assertEquals(Instant.parse("2026-09-12T11:00:00Z"), LiveActivities.turnStart(listOf(user()), "2026-09-12T11:00:00Z"), "without a message time the runtime's is used")
        assertNull(LiveActivities.turnStart(emptyList(), "invalid"))
        assertEquals("1:05", Durations.clock(start, start + 65.seconds))
        assertEquals("1:01:01", Durations.clock(start, start + 3_661.seconds))
        assertEquals("0:42", Durations.clock(42.seconds))
        assertEquals("12:05", Durations.clock(12.minutes + 5.seconds))
        assertEquals("0:00", Durations.clock(start, start - 5.seconds), "clock skew never shows negative time")
    }

    @Test
    fun pendingToolsCountUntilTheTranscriptFinishesThem() {
        val done = PendingTool(id = "p1", tool_call_id = "done", tool_name = "bash")
        val next = PendingTool(id = "p2", tool_call_id = "next", tool_name = "read_file")
        val unnamed = PendingTool(id = "p3", tool_name = "bash")
        val messages = listOf(user(), assistant(tool("bash", state = "output-available", id = "done"), tool("read_file", id = "next")))
        assertEquals(listOf("p2", "p3"), LiveActivities.unfinishedPendingTools(messages, listOf(done, next, unnamed)).map { it.id }, "a running call in the transcript still counts")
        assertEquals(listOf("p1"), LiveActivities.unfinishedPendingTools(listOf(assistant(tool("bash", state = "output-available", id = "done")), user()), listOf(done)).map { it.id }, "an earlier turn's call does not finish this one's")
        assertTrue(LiveActivities.unfinishedPendingTools(messages, emptyList()).isEmpty())
    }
}
