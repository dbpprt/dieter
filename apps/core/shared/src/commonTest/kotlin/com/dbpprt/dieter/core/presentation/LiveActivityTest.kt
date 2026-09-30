package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.PendingTool
import com.dbpprt.dieter.api.v1.ProviderStatus
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
}
