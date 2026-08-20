package com.dbpprt.nauclio.connection

import com.dbpprt.nauclio.v1.Card
import com.dbpprt.nauclio.v1.Conversation
import com.dbpprt.nauclio.v1.ConversationSnapshot
import com.dbpprt.nauclio.v1.PendingTool
import com.dbpprt.nauclio.v1.Subagent
import com.dbpprt.nauclio.v1.TaskPlan
import com.dbpprt.nauclio.v1.TaskPlanItem
import com.dbpprt.nauclio.v1.TaskPlanPhase
import org.junit.Assert.assertEquals
import org.junit.Test

class ModelActivityPreviewTest {
    @Test
    fun previewCombinesMainPlanAndToolWithOnlyActiveSubagents() {
        val snapshot = snapshot(
            Conversation.newBuilder()
                .addTaskPlans(
                    TaskPlan.newBuilder().addPhases(
                        TaskPlanPhase.newBuilder().addTasks(
                            TaskPlanItem.newBuilder()
                                .setStatus("in_progress")
                                .setActiveForm("Designing the expanded preview"),
                        ),
                    ),
                )
                .addPendingTools(PendingTool.newBuilder().setToolName("exec_command"))
                .addSubagents(subagent("Researcher", "running", "Reviewing Android notification patterns"))
                .addSubagents(subagent("Finished", "completed", "Done"))
                .build(),
        )

        val rows = currentModelActivities(card(), snapshot)

        assertEquals(2, rows.size)
        assertEquals("Main model", rows[0].modelLabel)
        assertEquals("Designing the expanded preview · Running a command", rows[0].detail)
        assertEquals("Researcher", rows[1].modelLabel)
        assertEquals("Reviewing Android notification patterns", rows[1].detail)
    }

    @Test
    fun globalPreviewIsCappedAndReportsHiddenActivities() {
        val first = snapshot(
            Conversation.newBuilder()
                .addSubagents(subagent("One", "running", "Reading files"))
                .addSubagents(subagent("Two", "pending", "Preparing tests"))
                .build(),
        )
        val second = snapshot(Conversation.newBuilder().build())

        val preview = modelActivityPreview(
            activeCardsById = mapOf("one" to card("one"), "two" to card("two")),
            conversations = linkedMapOf("one" to first, "two" to second),
            maxRows = 3,
        )

        assertEquals(4, preview.totalCount)
        assertEquals(3, preview.rows.size)
        assertEquals(1, preview.overflowCount)
    }

    @Test
    fun activeCardStillGetsFallbackWhenConversationRefreshFails() {
        val preview = modelActivityPreview(
            activeCardsById = mapOf("one" to card("one")),
            conversations = emptyMap(),
        )

        assertEquals(1, preview.totalCount)
        assertEquals("Implement a polished preview", preview.rows.single().detail)
    }

    @Test
    fun notificationTextIsSingleLineAndBounded() {
        val snapshot = snapshot(
            Conversation.newBuilder()
                .addSubagents(subagent("Worker", "running", "A\n${"very ".repeat(30)}long activity"))
                .build(),
        )

        val detail = currentModelActivities(card(), snapshot)[1].detail

        assertEquals(false, detail.contains('\n'))
        assertEquals(96, detail.length)
        assertEquals('…', detail.last())
    }

    private fun card(id: String = "one"): Card = Card.newBuilder()
        .setId(id)
        .setTitle("Android notification")
        .setSummary("Implement a polished preview")
        .build()

    private fun snapshot(conversation: Conversation): ConversationSnapshot = ConversationSnapshot.newBuilder()
        .setConversation(conversation)
        .build()

    private fun subagent(name: String, status: String, activity: String): Subagent = Subagent.newBuilder()
        .setName(name)
        .setStatus(status)
        .setActivity(activity)
        .build()
}
