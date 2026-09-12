package com.dbpprt.dieter.ui

import com.google.protobuf.ByteString
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.PendingTool
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.TaskPlanItem
import com.dbpprt.dieter.v1.TaskPlanPhase
import com.dbpprt.dieter.v1.UiMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConversationActivityPresentationTest {
    @Test
    fun followsActualToolReasoningAndWritingTransitions() {
        assertEquals("Reading App.kt", label(tool("Read", "/workspace/App.kt")))
        assertEquals("Running just android test", label(tool("exec_command", "{\"cmd\":\"just android test\"}")))
        assertEquals("Checking the results", label(text("**Checking the results**\n\nDetails")))
        assertEquals("Writing response…", label(text("Answer", type = "text")))
        assertEquals("Thinking…", label(tool("Read", "App.kt", state = "output-available")))
    }

    @Test
    fun staleActivityDoesNotCrossTheLatestUserTurn() {
        val old = message("old", parts = listOf(tool("bash", "old command")))
        assertEquals(
            "Thinking…",
            ConversationActivityPresentation.liveLabel(
                messages = listOf(old, message("next", role = "user")),
                pendingTools = emptyList(),
                plans = emptyList(),
            ),
        )
    }

    @Test
    fun approvalCancellationParallelToolsAndPlansUseNaturalLabels() {
        assertEquals(
            "Waiting for approval: bash",
            label(tool("bash", state = "approval-requested")),
        )
        assertEquals(
            "Stopping…",
            ConversationActivityPresentation.liveLabel(
                messages = emptyList(),
                pendingTools = emptyList(),
                plans = emptyList(),
                conversationStatus = "cancelling",
            ),
        )
        assertEquals(
            "Reading App.kt · +1 tool",
            label(tool("bash", "go test ./...", id = "one"), tool("Read", "App.kt", id = "two")),
        )

        val plan = TaskPlan.newBuilder()
            .setMessageId("assistant")
            .setState("active")
            .addPhases(
                TaskPlanPhase.newBuilder().addTasks(
                    TaskPlanItem.newBuilder().setStatus("in_progress").setActiveForm("Verifying Android behavior"),
                ),
            )
            .build()
        assertEquals(
            "Verifying Android behavior",
            ConversationActivityPresentation.liveLabel(
                messages = listOf(message("user", role = "user"), message("assistant")),
                pendingTools = emptyList(),
                plans = listOf(plan),
            ),
        )
    }

    @Test
    fun completedToolCannotBeRevivedByThePendingList() {
        val pending = PendingTool.newBuilder().setToolCallId("call").setToolName("bash")
            .setInputPreview("old command").build()
        assertEquals(
            "Thinking…",
            ConversationActivityPresentation.liveLabel(
                messages = listOf(message("assistant", parts = listOf(tool("bash", state = "output-available")))),
                pendingTools = listOf(pending),
                plans = emptyList(),
            ),
        )
    }

    @Test
    fun activityTimerUsesTheCurrentUserTimestampAndReadableElapsedTime() {
        val user = message("user", role = "user").toBuilder()
            .setMetadataJson(ByteString.copyFromUtf8("{\"createdAt\":\"2026-09-12T10:00:00Z\"}"))
            .build()
        val start = ConversationActivityPresentation.turnStartMillis(listOf(user), "2026-09-12T11:00:00Z")
        assertEquals(1_789_207_200_000L, start)
        assertEquals("1:05", elapsedActivityLabel(requireNotNull(start), start + 65_000L))
        assertEquals("1:01:01", elapsedActivityLabel(start, start + 3_661_000L))
        assertNull(ConversationActivityPresentation.turnStartMillis(emptyList(), "invalid"))
    }

    private fun label(vararg parts: MessagePart): String = ConversationActivityPresentation.liveLabel(
        messages = listOf(message("user", role = "user"), message("assistant", parts = parts.toList())),
        pendingTools = emptyList(),
        plans = emptyList(),
    )

    private fun message(id: String, role: String = "assistant", parts: List<MessagePart> = emptyList()): UiMessage =
        UiMessage.newBuilder().setId(id).setRole(role).addAllParts(parts).build()

    private fun tool(
        name: String,
        preview: String = "",
        state: String = "input-available",
        id: String = "call",
    ): MessagePart = MessagePart.newBuilder()
        .setType("dynamic-tool")
        .setToolName(name)
        .setToolCallId(id)
        .setState(state)
        .setInputPreview(preview)
        .build()

    private fun text(value: String, type: String = "reasoning", state: String = "streaming"): MessagePart =
        MessagePart.newBuilder().setType(type).setText(value).setState(state).build()
}
