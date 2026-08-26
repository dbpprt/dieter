package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.QueuedMessage
import com.dbpprt.dieter.v1.UiMessage
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationPostSendRefreshTest {
    @Test
    fun `missing snapshot keeps the recovery fetch alive`() {
        assertTrue(conversationNeedsPostSendRefresh(null, emptySet()))
    }

    @Test
    fun `stale receipt keeps refreshing even when conversation looks idle`() {
        val snapshot = snapshot(status = "idle", messageIds = listOf("msg_pending"))

        assertTrue(conversationNeedsPostSendRefresh(snapshot, setOf("msg_pending")))
    }

    @Test
    fun `queued receipt keeps refreshing until promoted into the transcript`() {
        val snapshot = snapshot(status = "running", queuedIds = listOf("msg_queued"))

        assertTrue(conversationNeedsPostSendRefresh(snapshot, setOf("msg_queued")))
    }

    @Test
    fun `synced running turn keeps refreshing for the agent answer`() {
        assertTrue(conversationNeedsPostSendRefresh(snapshot(status = "running"), emptySet()))
    }

    @Test
    fun `synced idle transcript stops recovery fetches`() {
        assertFalse(conversationNeedsPostSendRefresh(snapshot(status = "idle", messageIds = listOf("msg_sent")), emptySet()))
    }

    @Test
    fun `pending messages from another conversation do not keep this one polling`() {
        val snapshot = snapshot(status = "idle", messageIds = listOf("msg_sent"))

        assertFalse(conversationNeedsPostSendRefresh(snapshot, setOf("msg_in_another_chat")))
    }

    private fun snapshot(
        status: String,
        messageIds: List<String> = emptyList(),
        queuedIds: List<String> = emptyList(),
    ): ConversationSnapshot = ConversationSnapshot.newBuilder()
        .setConversation(
            Conversation.newBuilder()
                .setStatus(status)
                .addAllMessages(messageIds.map { UiMessage.newBuilder().setId(it).build() })
                .addAllQueue(queuedIds.map { QueuedMessage.newBuilder().setId(it).build() }),
        )
        .build()
}
