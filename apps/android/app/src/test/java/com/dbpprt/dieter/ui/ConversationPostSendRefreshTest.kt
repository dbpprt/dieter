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

    @Test
    fun `observed pending receipt starts recovery even when send callback was missed`() {
        val snapshot = snapshot(status = "idle", messageIds = listOf("msg_pending"))

        assertTrue(
            foregroundConversationRecoveryShouldStart(
                foreground = true,
                selectedCardId = "c_open",
                recoveryCardId = null,
                recoveryActive = false,
                snapshot = snapshot,
                pendingMessageIds = setOf("msg_pending"),
            ),
        )
    }

    @Test
    fun `observed running turn starts recovery without a pending receipt`() {
        assertTrue(
            foregroundConversationRecoveryShouldStart(
                foreground = true,
                selectedCardId = "c_open",
                recoveryCardId = null,
                recoveryActive = false,
                snapshot = snapshot(status = "running"),
                pendingMessageIds = emptySet(),
            ),
        )
    }

    @Test
    fun `active recovery for the selected card is not restarted`() {
        assertFalse(
            foregroundConversationRecoveryShouldStart(
                foreground = true,
                selectedCardId = "c_open",
                recoveryCardId = "c_open",
                recoveryActive = true,
                snapshot = snapshot(status = "running"),
                pendingMessageIds = emptySet(),
            ),
        )
    }

    @Test
    fun `background or closed conversations do not start recovery`() {
        val running = snapshot(status = "running")

        assertFalse(
            foregroundConversationRecoveryShouldStart(
                foreground = false,
                selectedCardId = "c_open",
                recoveryCardId = null,
                recoveryActive = false,
                snapshot = running,
                pendingMessageIds = emptySet(),
            ),
        )
        assertFalse(
            foregroundConversationRecoveryShouldStart(
                foreground = true,
                selectedCardId = null,
                recoveryCardId = null,
                recoveryActive = false,
                snapshot = running,
                pendingMessageIds = emptySet(),
            ),
        )
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
