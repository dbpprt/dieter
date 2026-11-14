package com.getdieter.core.client

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.CardDetail
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.ConversationSnapshot
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.UiMessage
import com.getdieter.client.v1.ChannelAuthorKind
import com.getdieter.client.v1.ChannelMessageKind
import com.getdieter.client.v1.TimelineStepKind
import com.getdieter.core.conversation.ConversationView
import com.getdieter.core.outbox.OutboxView
import com.getdieter.core.presentation.ConversationPresenter
import com.getdieter.core.presentation.Parts
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

/** Agent channel messages inside a conversation: steered peer notices and wake-started turns. */
class PeerNoticeSliceTest {
    private val card = Card(id = "c", scope = "board", lane = "running", runtime = "running")

    private fun slice(vararg messages: UiMessage) =
        ConversationView(
                cardId = "c",
                daemonId = "d",
                presented =
                    ConversationSnapshot(
                        detail = CardDetail(card = card),
                        conversation =
                            Conversation(status = "running", messages = messages.toList()),
                    ),
                loading = false,
            )
            .let { conversationSlice(it, ConversationPresenter.present(it, OutboxView(), null)) }

    private val notice =
        MessagePart(
            type = "data-peer-notice",
            text = "rules.ts is free now",
            data_json =
                """
                {"messageId":"m_7f41","projectId":"p1","channel":"pricing","kind":"done",
                 "threadId":"","author":{"kind":"agent","cardId":"c_9b10","title":"Fix checkout tests",
                 "harness":"codex","model":"gpt-5"},"direct":true,"files":["src/rules.ts"],
                 "createdAt":"2026-10-24T11:02:00Z"}
                """
                    .trimIndent()
                    .encodeUtf8(),
        )

    private fun tool(id: String) =
        MessagePart(
            type = "dynamic-tool",
            tool_call_id = id,
            tool_name = "bash",
            state = "output-available",
        )

    @Test
    fun aSteeredChannelMessageIsAPeerNoticeThatNeverFoldsIntoActivity() {
        // A message that is otherwise only routine work keeps its own row for the notice.
        val turn =
            UiMessage(id = "a", role = "assistant", parts = listOf(tool("t1"), notice, tool("t2")))
        val slice = slice(turn)
        val row = slice.timeline.single()
        assertEquals("message:a", row.id)
        assertFalse(row.activity)
        val steps = row.groups.flatMap { it.steps }
        val peer = steps.single { it.kind == TimelineStepKind.TIMELINE_STEP_KIND_PEER_NOTICE }
        assertFalse(peer.routine)
        assertEquals(1, peer.part_index)
        val payload = peer.peer_notice!!
        assertEquals("m_7f41", payload.message_id)
        assertEquals("p1", payload.project_id)
        assertEquals("pricing", payload.channel)
        assertEquals("Fix checkout tests", payload.author?.name)
        assertEquals("FC", payload.author?.initials)
        assertEquals(ChannelAuthorKind.CHANNEL_AUTHOR_KIND_AGENT, payload.author?.kind)
        assertEquals("codex", payload.author?.harness)
        assertEquals(ChannelMessageKind.CHANNEL_MESSAGE_KIND_DONE, payload.kind)
        assertEquals("DONE", payload.kind_label)
        assertEquals("rules.ts is free now", payload.body)
        assertEquals(listOf("src/rules.ts"), payload.files)
        assertTrue(payload.direct)
        assertEquals("Fix checkout tests to this agent in #pricing", payload.title)
        assertEquals("Open in #pricing", payload.open_label)
        assertEquals(
            Instant.parse("2026-10-24T11:02:00Z").toEpochMilliseconds(),
            payload.created_at_millis,
        )
        // Other agents' words are not this message's prose.
        assertFalse(Parts.isCopyable(notice))
        // Other steps carry no notice.
        assertTrue(
            steps
                .filter { it.kind != TimelineStepKind.TIMELINE_STEP_KIND_PEER_NOTICE }
                .all { it.peer_notice == null }
        )
    }

    @Test
    fun aNoticeWithoutAPayloadStillShowsItsText() {
        val bare = MessagePart(type = "data-peer-notice", text = "hello")
        val step =
            slice(UiMessage(id = "a", role = "assistant", parts = listOf(bare)))
                .timeline
                .single()
                .groups
                .single()
                .steps
                .single()
        assertEquals(TimelineStepKind.TIMELINE_STEP_KIND_PEER_NOTICE, step.kind)
        assertEquals("hello", step.peer_notice?.body)
        assertEquals("Agent in #channel", step.peer_notice?.title)
    }

    @Test
    fun aTurnAChannelWokeIsFromAgentChannelsNotTheUser() {
        val text =
            listOf(MessagePart(type = "text", text = "These agent channel messages woke you."))
        val wake = UiMessage(id = "msg_channel_1", role = "user", parts = text)
        val tagged =
            UiMessage(
                id = "u2",
                role = "user",
                parts = text,
                metadata_json =
                    """{"createdAt":"2026-10-24T11:00:00Z","origin":"channel"}""".encodeUtf8(),
            )
        val human = UiMessage(id = "u3", role = "user", parts = text)
        val rows = slice(wake, tagged, human).timeline
        assertEquals(listOf(true, true, false), rows.map { it.channel_wake })
        assertEquals(
            listOf("From agent channels", "From agent channels", ""),
            rows.map { it.origin_label },
        )
    }
}
