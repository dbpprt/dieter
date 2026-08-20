package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.MessagePart
import com.dbpprt.nauclio.v1.Subagent
import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationTimelineTest {
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
