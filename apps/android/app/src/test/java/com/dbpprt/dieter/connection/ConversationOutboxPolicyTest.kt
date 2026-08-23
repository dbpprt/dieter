package com.dbpprt.dieter.connection

import com.dbpprt.dieter.data.AndroidOutboxEntry
import com.dbpprt.dieter.data.OutboxKind
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.QueuedMessage
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.UiMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationOutboxPolicyTest {
    @Test
    fun `starting chat renders its first message while creation is pending`() {
        val request = CreateConversationRequest.newBuilder()
            .setPrompt("  Inspect this screenshot  ")
            .setDeferStart(false)
            .addAttachments(MessagePart.newBuilder().setType("file").setFilename("screen.png"))
            .build()

        val message = optimisticChatMessage(request, "local-initial")

        assertEquals("local-initial", message?.id)
        assertEquals("user", message?.role)
        assertEquals("Inspect this screenshot", message?.partsList?.get(0)?.text)
        assertEquals("screen.png", message?.partsList?.get(1)?.filename)
    }

    @Test
    fun `deferred conversation does not pretend its prompt was sent`() {
        val request = CreateConversationRequest.newBuilder()
            .setPrompt("Keep this as a draft")
            .setDeferStart(true)
            .build()

        assertNull(optimisticChatMessage(request, "local-initial"))
    }

    @Test
    fun `accepted chat replaces its temporary conversation id`() {
        assertEquals("c_server", resolveConversationId("local_chat", mapOf("local_chat" to "c_server")))
        assertEquals("c_existing", resolveConversationId("c_existing", emptyMap()))
        assertNull(resolveConversationId(null, mapOf("local_chat" to "c_server")))
    }

    @Test
    fun `lagging transcript keeps optimistic send visible`() {
        val entry = sendEntry(serverId = "msg_local")
        val lagging = snapshot()

        val overlaid = overlayOptimisticMessages(lagging, listOf(entry))

        assertEquals(listOf("msg_local"), overlaid.conversation.messagesList.map(UiMessage::getId))
        assertEquals("Still there?", overlaid.conversation.messagesList.single().partsList.single().text)
    }

    @Test
    fun `accepted send stays pending until transcript or queue reflects it`() {
        val entry = sendEntry(serverId = "msg_local")

        assertFalse(outboxEntryIsSynced(entry, setOf("c_chat"), listOf(snapshot())))
        assertTrue(
            outboxEntryIsSynced(
                entry,
                setOf("c_chat"),
                listOf(snapshot(messages = listOf(userMessage("msg_local", "Still there?")))),
            ),
        )
        assertTrue(
            outboxEntryIsSynced(
                entry,
                setOf("c_chat"),
                listOf(snapshot(queuedIds = listOf("msg_local"))),
            ),
        )
    }

    @Test
    fun `accepted new chat targets server id and keeps initial prompt until reflected`() {
        val request = CreateConversationRequest.newBuilder()
            .setProjectId("p_test")
            .setPrompt("First prompt")
            .build()
        val entry = outboxEntry(
            kind = OutboxKind.CREATE_CHAT,
            request = request.toByteArray(),
            optimisticId = "local_chat",
            serverId = "c_server",
        )

        assertEquals("c_server", optimisticConversationId(entry))
        val overlaid = overlayOptimisticMessages(snapshot(cardId = "c_server"), listOf(entry))
        assertEquals("local_chat_initial", overlaid.conversation.messagesList.single().id)
        assertFalse(outboxEntryIsSynced(entry, setOf("c_server"), listOf(snapshot(cardId = "c_server"))))
        assertTrue(
            outboxEntryIsSynced(
                entry,
                setOf("c_server"),
                listOf(snapshot(cardId = "c_server", messages = listOf(userMessage("msg_server", "First prompt")))),
            ),
        )
    }

    private fun sendEntry(serverId: String?): AndroidOutboxEntry {
        val request = SendMessageRequest.newBuilder()
            .setCardId("c_chat")
            .setMessageId("msg_local")
            .addParts(MessagePart.newBuilder().setType("text").setText("Still there?"))
            .build()
        return outboxEntry(OutboxKind.SEND_MESSAGE, request.toByteArray(), "msg_local", serverId)
    }

    private fun outboxEntry(
        kind: OutboxKind,
        request: ByteArray,
        optimisticId: String,
        serverId: String?,
    ): AndroidOutboxEntry = AndroidOutboxEntry(
        commandId = "command",
        clientId = "client",
        endpointId = "endpoint",
        kind = kind,
        request = request,
        optimisticId = optimisticId,
        serverId = serverId,
    )

    private fun snapshot(
        cardId: String = "c_chat",
        messages: List<UiMessage> = emptyList(),
        queuedIds: List<String> = emptyList(),
    ): ConversationSnapshot = ConversationSnapshot.newBuilder()
        .setDetail(CardDetail.newBuilder().setCard(Card.newBuilder().setId(cardId)))
        .setConversation(
            Conversation.newBuilder()
                .setCardId(cardId)
                .addAllMessages(messages)
                .addAllQueue(queuedIds.map { QueuedMessage.newBuilder().setId(it).build() }),
        )
        .build()

    private fun userMessage(id: String, text: String): UiMessage = UiMessage.newBuilder()
        .setId(id)
        .setRole("user")
        .addParts(MessagePart.newBuilder().setType("text").setText(text))
        .build()
}
