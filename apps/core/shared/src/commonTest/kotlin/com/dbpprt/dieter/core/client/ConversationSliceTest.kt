package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardDetail
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.MessageDelivery
import com.dbpprt.dieter.client.v1.TimelineStepKind
import com.dbpprt.dieter.client.v1.ToolCallStatus
import com.dbpprt.dieter.core.conversation.ConversationView
import com.dbpprt.dieter.core.outbox.OutboxView
import com.dbpprt.dieter.core.presentation.ConversationPresenter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

class ConversationSliceTest {
    private val card = Card(
        id = "c", scope = "board", lane = "running", runtime = "running", provider = "codex",
        initial_prompt = "Ship it", initial_prompt_sent_at = "2026-09-30T10:00:00Z",
    )

    private fun view(conversation: Conversation) = ConversationView(
        cardId = "c", daemonId = "d", presented = ConversationSnapshot(detail = CardDetail(card = card), conversation = conversation), loading = false,
    )

    @Test
    fun theTimelineTravelsAsThinKeyedRows() {
        val user = UiMessage(
            id = "u", role = "user", parts = listOf(MessagePart(type = "text", text = "go")),
            metadata_json = """{"createdAt":"2026-09-30T10:00:00Z"}""".encodeUtf8(),
        )
        val reply = UiMessage(
            id = "a", role = "assistant",
            parts = listOf(
                MessagePart(type = "text", text = "First"), MessagePart(type = "text", text = "Second"),
                MessagePart(type = "dynamic-tool", tool_call_id = "t", tool_name = "read_file", state = "output-available"),
            ),
        )
        val work = UiMessage(id = "w", role = "assistant", parts = listOf(MessagePart(type = "dynamic-tool", tool_call_id = "x", tool_name = "bash", state = "input-available")))
        val conversation = Conversation(
            status = "running", messages = listOf(user, reply, work),
            task_plans = listOf(TaskPlan(id = "p", message_id = "a"), TaskPlan(id = "gone", message_id = "elsewhere")),
        )
        val view = view(conversation)
        val outbox = OutboxView(pendingMessageIds = setOf("u"), acceptedIds = setOf("u"))
        val slice = conversationSlice(view, ConversationPresenter.present(view, outbox, null))

        assertEquals(listOf("message:u", "message:a", "tools:w"), slice.timeline.map { it.id })
        assertEquals(listOf("gone"), slice.unattached_plan_ids)
        val first = slice.timeline[0]
        assertTrue(first.user)
        assertEquals(MessageDelivery.MESSAGE_DELIVERY_ACCEPTED, first.delivery)
        assertEquals("Accepted by daemon", first.delivery_label)
        assertTrue(first.unconfirmed)
        assertTrue(first.copyable)
        assertEquals(Instant.parse("2026-09-30T10:00:00Z").toEpochMilliseconds(), first.created_at_millis)

        val prose = slice.timeline[1]
        assertEquals(MessageDelivery.MESSAGE_DELIVERY_UNSPECIFIED, prose.delivery)
        assertEquals("", prose.delivery_label, "only user messages have a receipt")
        assertFalse(prose.unconfirmed)
        assertEquals(0L, prose.created_at_millis, "no time in the metadata")
        assertEquals(listOf("p"), prose.plan_ids)
        assertEquals(listOf(false, true), prose.groups.map { it.activity })
        val text = prose.groups[0].steps.single()
        assertEquals(TimelineStepKind.TIMELINE_STEP_KIND_TEXT, text.kind)
        assertEquals(0, text.part_index)
        assertEquals("First\n\nSecond", text.text, "coalesced prose travels as text")
        val read = prose.groups[1]
        assertEquals("1 read", read.summary)
        assertEquals("a:part:2", read.id)
        val readStep = read.steps.single()
        assertEquals(ToolCallStatus.TOOL_CALL_STATUS_COMPLETED, readStep.tool_status)
        assertEquals("read file", readStep.tool_title)
        assertEquals("completed", readStep.tool_status_label)
        assertFalse(readStep.tool_attention)
        assertEquals("", text.tool_status_label, "prose has no tool status")
        assertEquals(2, readStep.part_index)
        assertEquals("", readStep.text, "a single part's text is not repeated")
        assertTrue(readStep.routine)

        val activity = slice.timeline[2]
        assertTrue(activity.activity)
        assertEquals("1 command", activity.summary)
        assertEquals(listOf("w"), activity.message_ids)
        assertEquals(listOf("w:part:0"), activity.groups.map { it.id })
        assertEquals(ToolCallStatus.TOOL_CALL_STATUS_RUNNING, activity.groups.single().steps.single().tool_status)
        assertEquals("running", activity.groups.single().steps.single().tool_status_label)
        assertFalse(activity.copyable)
        assertTrue(slice.state!!.working)
    }

    @Test
    fun theBannerAndTheTimelineAgreeOnTheFailedMessage() {
        val failed = UiMessage(id = "a", role = "assistant", parts = listOf(MessagePart(type = "text", state = "error", text = "Turn failed — codex exited 1")))
        val earlier = UiMessage(id = "b", role = "assistant", parts = listOf(MessagePart(type = "text", state = "error", text = "Turn failed — timeout")))
        val user = UiMessage(id = "u", role = "user", parts = listOf(MessagePart(type = "text", text = "go")))
        val view = view(Conversation(status = "failed", messages = listOf(user, earlier, user.copy(id = "u2"), failed)))
        val slice = conversationSlice(view, ConversationPresenter.present(view, OutboxView(), null))
        assertEquals("a", slice.turn_failure?.failed_message_id)
        assertEquals("codex exited 1", slice.turn_failure?.summary)
        assertEquals(listOf("message:u", "message:b", "message:u2"), slice.timeline.map { it.id }, "the banner's message leaves its diagnostic to the banner")
        assertEquals(TimelineStepKind.TIMELINE_STEP_KIND_ATTENTION, slice.timeline[1].groups.single().steps.single().kind, "an earlier failure stays readable")
    }
}
