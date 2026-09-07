package com.dbpprt.dieter.connection

import com.dbpprt.dieter.data.AndroidOutboxEntry
import com.dbpprt.dieter.data.OutboxKind
import com.dbpprt.dieter.data.OutboxState
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Lane
import com.dbpprt.dieter.v1.QueuedMessage
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.StartCardRequest
import com.dbpprt.dieter.v1.UiMessage
import com.google.protobuf.ByteString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import io.grpc.Status

class ConversationOutboxPolicyTest {
    @Test
    fun pendingEntriesRetargetFromGatewayFallbackToKnownProjectMachine() {
        val message = outboxEntry(OutboxKind.SEND_MESSAGE, byteArrayOf(), "message", null).copy(
            endpointId = "gateway",
            request = SendMessageRequest.newBuilder().setCardId("card-one").build().toByteArray(),
        )
        val retargeted = retargetOutboxEndpoints(
            listOf(message),
            cardProjects = mapOf("card-one" to "project-one"),
            projectEndpoints = mapOf("project-one" to "gateway#machine-one"),
        )

        assertEquals("gateway#machine-one", retargeted.single().endpointId)
    }

    @Test
    fun `permanent failure does not block later create`() {
        val failed = outboxEntry(OutboxKind.SEND_MESSAGE, byteArrayOf(), "msg_failed", null)
            .copy(state = OutboxState.FAILED)
        val ready = outboxEntry(OutboxKind.CREATE_CHAT, byteArrayOf(), "local_chat", null)

        assertEquals(ready, nextOutboxEntry(listOf(failed, ready), "endpoint", nowMillis = 100))
    }

    @Test
    fun `backed off head does not block ready entry`() {
        val delayed = outboxEntry(OutboxKind.SEND_MESSAGE, byteArrayOf(), "msg_delayed", null)
            .copy(state = OutboxState.RETRYING, nextAttemptAtMillis = 200)
        val ready = outboxEntry(OutboxKind.CREATE_CHAT, byteArrayOf(), "local_chat", null)

        assertEquals(ready, nextOutboxEntry(listOf(delayed, ready), "endpoint", nowMillis = 100))
    }

    @Test
    fun `online endpoint with pending work is selected after the current queue drains`() {
        val current = outboxEntry(OutboxKind.SEND_MESSAGE, byteArrayOf(), "done", "server")
        val offline = outboxEntry(OutboxKind.SEND_MESSAGE, byteArrayOf(), "offline", null)
            .copy(endpointId = "offline-endpoint")
        val online = outboxEntry(OutboxKind.START_CARD, byteArrayOf(), "card", null)
            .copy(endpointId = "online-endpoint")

        assertEquals(
            "online-endpoint",
            nextOutboxEndpoint(
                listOf(current, offline, online),
                currentEndpointId = "endpoint",
                onlineEndpointIds = setOf("online-endpoint"),
                nowMillis = 100,
            ),
        )
    }

    @Test
    fun `machine summary groups only undelivered work by owning endpoint`() {
        val message = outboxEntry(OutboxKind.SEND_MESSAGE, byteArrayOf(), "message", null)
            .copy(endpointId = "offline", state = OutboxState.RETRYING)
        val change = outboxEntry(OutboxKind.CREATE_CHAT, byteArrayOf(), "chat", null)
            .copy(endpointId = "offline")
        val accepted = outboxEntry(OutboxKind.CREATE_CARD, byteArrayOf(), "card", "server")
            .copy(endpointId = "offline")

        val summary = machineOutboxSummaries(listOf(message, change, accepted)).getValue("offline")

        assertEquals(1, summary.messageCount)
        assertEquals(1, summary.changeCount)
        assertTrue(summary.retrying)
        assertEquals("2 items queued — delivers when it reconnects.", summary.deliveryLabel)
    }

    @Test
    fun `dependent send retargets to created server conversation`() {
        val request = SendMessageRequest.newBuilder().setCardId("local_chat").build()
        val entry = outboxEntry(OutboxKind.SEND_MESSAGE, request.toByteArray(), "msg_local", null)

        val retargeted = retargetOutboxDependencies(listOf(entry), "local_chat", "c_server").single()

        assertEquals("c_server", SendMessageRequest.parseFrom(retargeted.request).cardId)
    }

    @Test
    fun `local id is never server fetchable and grpc error stays useful`() {
        val error = Status.NOT_FOUND.withDescription("card missing").asRuntimeException()

        assertFalse(isServerConversationId("local_chat"))
        assertTrue(isServerConversationId("c_server"))
        assertTrue(outboxFailureIsPermanent(error))
        assertEquals("gRPC NOT_FOUND: card missing", readableRpcError(error))
    }

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
    fun `retained failed send stays before newer running turns`() {
        val failed = sendEntry(serverId = null).copy(
            state = OutboxState.FAILED,
            createdAtMillis = 1_000,
        )
        val staleTail = userMessage("msg_local", "Still there?")
        val running = userMessage("msg_running", "Newer command", createdAtMillis = 2_000)
        val answer = userMessage("msg_answer", "Newer answer", role = "assistant", createdAtMillis = 3_000)

        val overlaid = overlayOptimisticMessages(
            snapshot(messages = listOf(running, answer, staleTail)),
            listOf(failed),
        )

        assertEquals(
            listOf("msg_local", "msg_running", "msg_answer"),
            overlaid.conversation.messagesList.map(UiMessage::getId),
        )
        assertFalse(overlaid.conversation.messagesList.first().metadataJson.isEmpty)
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

    @Test
    fun `queued start moves the existing card optimistically and waits for durable marker`() {
        val request = StartCardRequest.newBuilder()
            .setCardId("card")
            .setClientId("client")
            .setCommandId("start-command")
            .build()
        val entry = outboxEntry(OutboxKind.START_CARD, request.toByteArray(), "card", null)
        val board = Board.newBuilder()
            .setId("board")
            .addLanes(Lane.newBuilder().setId("todo").setName("Todo"))
            .addLanes(Lane.newBuilder().setId("active").setName("Running"))
            .build()
        val card = Card.newBuilder().setId("card").setBoardId("board").setLane("todo").build()

        val optimistic = overlayPendingCardStarts(listOf(card), listOf(board), listOf(entry)).single()

        assertEquals("active", optimistic.lane)
        assertEquals("starting", optimistic.runtime)
        assertFalse(outboxEntryIsSynced(entry.copy(serverId = "card"), setOf("card"), emptyList()))
        assertTrue(
            outboxEntryIsSynced(
                entry.copy(serverId = "card"),
                setOf("card"),
                emptyList(),
                startedCardIds = setOf("card"),
            ),
        )
    }

    @Test
    fun `failed start is not overlaid until explicitly retried`() {
        val entry = outboxEntry(OutboxKind.START_CARD, byteArrayOf(), "card", null)
            .copy(state = OutboxState.FAILED)
        val board = Board.newBuilder()
            .setId("board")
            .addLanes(Lane.newBuilder().setId("running").setName("Running"))
            .build()
        val card = Card.newBuilder().setId("card").setBoardId("board").setLane("todo").build()

        assertEquals(card, overlayPendingCardStarts(listOf(card), listOf(board), listOf(entry)).single())
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

    private fun userMessage(
        id: String,
        text: String,
        role: String = "user",
        createdAtMillis: Long? = null,
    ): UiMessage =
        UiMessage.newBuilder()
            .setId(id)
            .setRole(role)
            .apply {
                createdAtMillis?.let {
                    metadataJson = ByteString.copyFromUtf8("{\"createdAt\":\"${java.time.Instant.ofEpochMilli(it)}\"}")
                }
            }
            .addParts(MessagePart.newBuilder().setType("text").setText(text))
            .build()
}
