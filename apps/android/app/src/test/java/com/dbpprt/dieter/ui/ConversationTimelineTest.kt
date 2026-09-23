package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Subagent
import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationTimelineTest {
    @Test fun shorterReplacementKeepsLatestSectionsVisible() {
        val oldStart = conversationMessageStart(680, null)
        assertEquals(0, conversationMessageStart(4, oldStart))
        val replacementStart = conversationMessageStart(20, oldStart)
        assertEquals(8, replacementStart)
        assertEquals(replacementStart, conversationMessageStart(21, replacementStart))
        assertEquals(0, conversationMessageStart(0, replacementStart))
    }

    @Test fun longTurnStartsAtTailAndKeepsItsBoundaryWhileStreaming() {
        val timeline = buildConversationTimeline((0 until 340).flatMap { listOf(text("Step $it"), tool("$it")) })
        assertEquals(680, timeline.size)
        var start = conversationMessageStart(timeline.size, null)
        assertEquals(INITIAL_MESSAGE_ITEMS, timeline.size - start)
        assertEquals(start, conversationMessageStart(timeline.size + 1, start))
        repeat((timeline.size + INITIAL_MESSAGE_ITEMS - 1) / INITIAL_MESSAGE_ITEMS) {
            start = conversationMessageStart(timeline.size, start - INITIAL_MESSAGE_ITEMS)
        }
        assertEquals("Step 0", (timeline[start] as ConversationTimelineItem.Part).part.text)
    }

    @Test
    fun splitsToolGroupsAroundVisibleModelText() {
        val timeline = buildConversationTimeline(
            listOf(
                text("First"),
                tool("a"),
                tool("b"),
                part("step-start"),
                text("Middle"),
                tool("c"),
                part("reasoning", "Hidden trace"),
                tool("d"),
                text("Last"),
            ),
        )

        assertEquals(listOf("part", "tools", "part", "tools", "part"), timeline.types())
        assertEquals(
            listOf(listOf("a", "b"), listOf("c", "d")),
            timeline.filterIsInstance<ConversationTimelineItem.Tools>()
                .map { group -> group.parts.map { it.toolCallId } },
        )
    }

    @Test
    fun visibleReasoningPreservesItsChronologicalBoundary() {
        val timeline = buildConversationTimeline(
            listOf(tool("a"), part("reasoning", "Inspecting"), tool("b")),
            showReasoning = true,
        )

        assertEquals(listOf("tools", "part", "tools"), timeline.types())
    }

    @Test
    fun placesDelegatedAgentsInSequenceAndOmitsProjectedPlanTools() {
        val subagents = listOf(
            Subagent.newBuilder().setId("child").setParentToolCallId("delegate").build(),
        )
        val timeline = buildConversationTimeline(
            parts = listOf(
                tool("a"),
                tool("delegate", "task"),
                text("After delegation"),
                tool("plan", "update_plan"),
                tool("b"),
            ),
            subagents = subagents,
            hasTaskPlan = true,
        )

        assertEquals(listOf("tools", "subagents", "part", "tools"), timeline.types())
        assertEquals(
            listOf("b"),
            timeline.filterIsInstance<ConversationTimelineItem.Tools>().last().parts.map { it.toolCallId },
        )
    }

    private fun List<ConversationTimelineItem>.types(): List<String> = map { item ->
        when (item) {
            is ConversationTimelineItem.Part -> "part"
            is ConversationTimelineItem.Tools -> "tools"
            ConversationTimelineItem.Subagents -> "subagents"
        }
    }

    private fun text(value: String): MessagePart = part("text", value)

    private fun tool(id: String, name: String = "bash"): MessagePart = MessagePart.newBuilder()
        .setType("dynamic-tool")
        .setToolCallId(id)
        .setToolName(name)
        .build()

    private fun part(type: String, text: String = ""): MessagePart = MessagePart.newBuilder()
        .setType(type)
        .setText(text)
        .build()
}
