package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Subagent
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.UiMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationMessageVisibilityTest {
    @Test
    fun reasoningTracesAreHiddenByDefault() {
        assertFalse(DieterUiState().showReasoningTraces)
    }

    @Test
    fun emptyAssistantEnvelopeIsNotRenderable() {
        assertFalse(message().hasRenderableConversationContent())
        assertFalse(message(part("text", "   ")).hasRenderableConversationContent())
        assertFalse(message(part("reasoning", "")).hasRenderableConversationContent())
        assertFalse(message(part("step-start", "step")).hasRenderableConversationContent())
    }

    @Test
    fun visiblePartsAreRenderable() {
        assertTrue(message(part("text", "Answer")).hasRenderableConversationContent())
        assertTrue(message(part("reasoning", "Considering the request")).hasRenderableConversationContent())
        assertTrue(message(part("dynamic-tool")).hasRenderableConversationContent())
        assertTrue(message(part("tool-call")).hasRenderableConversationContent())
        assertTrue(
            message(
                MessagePart.newBuilder().setType("file").setFilename("screen.png").build(),
            ).hasRenderableConversationContent(),
        )
    }

    @Test
    fun reasoningOnlyMessagesRespectTheGlobalVisibilitySetting() {
        val reasoning = message(part("reasoning", "Considering the request"))
        assertFalse(reasoning.hasRenderableConversationContent(includeReasoning = false))
        assertTrue(reasoning.hasRenderableConversationContent(includeReasoning = true))
        assertTrue(
            message(part("reasoning", "Trace"), part("text", "Answer"))
                .hasRenderableConversationContent(includeReasoning = false),
        )
    }

    @Test
    fun hiddenReasoningCannotFallThroughToGenericTextPresentation() {
        val reasoning = part("reasoning", "Considering the request")

        assertEquals(
            ConversationPartPresentation.HIDDEN,
            reasoning.conversationPartPresentation(includeReasoning = false),
        )
        assertEquals(
            ConversationPartPresentation.REASONING,
            reasoning.conversationPartPresentation(includeReasoning = true),
        )
        assertEquals(
            ConversationPartPresentation.FALLBACK_TEXT,
            part("custom-diagnostic", "Visible extension content")
                .conversationPartPresentation(includeReasoning = false),
        )
    }

    @Test
    fun structuredAssistantActivityIsRenderableWithoutParts() {
        assertTrue(message().hasRenderableConversationContent(taskPlan = TaskPlan.newBuilder().setId("plan").build()))
        assertTrue(message().hasRenderableConversationContent(subagents = listOf(Subagent.newBuilder().setId("worker").build())))
    }

    private fun message(vararg parts: MessagePart): UiMessage = UiMessage.newBuilder()
        .setId("assistant-message")
        .setRole("assistant")
        .addAllParts(parts.toList())
        .build()

    private fun part(type: String, text: String = ""): MessagePart = MessagePart.newBuilder()
        .setType(type)
        .setText(text)
        .build()
}
