package com.dbpprt.dieter.data

import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.ConversationUpdate
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Subagent
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.UiMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class ConversationReducerTest {
    @Test
    fun snapshotStartsStream() {
        val snapshot = snapshot(message("one", "first"))

        val result = ConversationReducer.apply(
            null,
            ConversationUpdate.newBuilder().setSnapshot(snapshot).build(),
        )

        assertSame(snapshot, result)
    }

    @Test
    fun deltaReplacesRemovesAndAppendsInOrder() {
        val base = snapshot(
            message("one", "old"),
            message("remove", "gone"),
        )
        val current = base.toBuilder()
            .setConversation(
                base.conversation.toBuilder().addDraftAttachments(
                    MessagePart.newBuilder().setType("file").setFilename("draft.txt"),
                ),
            )
            .build()
        val update = ConversationUpdate.newBuilder()
            .addChangedMessages(message("one", "new"))
            .addChangedMessages(message("two", "second"))
            .addRemovedMessageIds("remove")
            .setStatus("running")
            .addSubagents(Subagent.newBuilder().setId("worker-one").setStatus("running"))
            .addTaskPlans(TaskPlan.newBuilder().setId("plan-one").setRevision(2))
            .setLastSeq(8)
            .build()

        val result = ConversationReducer.apply(current, update)

        assertEquals(listOf("one", "two"), result.conversation.messagesList.map { it.id })
        assertEquals("new", result.conversation.messagesList[0].partsList[0].text)
        assertEquals("running", result.conversation.status)
        assertEquals("worker-one", result.conversation.subagentsList.single().id)
        assertEquals("plan-one", result.conversation.taskPlansList.single().id)
        assertEquals(2, result.conversation.taskPlansList.single().revision)
        assertEquals(8, result.conversation.lastSeq)
        assertEquals(0, result.conversation.draftAttachmentsCount)
    }

    @Test
    fun deltaBeforeSnapshotIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            ConversationReducer.apply(null, ConversationUpdate.getDefaultInstance())
        }
    }

    @Test
    fun defaultEndpointIsTheAuthenticatedGateway() {
        assertEquals("127.0.0.1:4242", DIETER_LOCAL_ENDPOINT)
        assertEquals(listOf("https://gateway.getdieter.com:443"), DIETER_ENDPOINTS.map { it.address })
        assertEquals(true, DIETER_ENDPOINTS.single().secure)
        assertEquals(3, DIETER_INPUT_PROTOCOL_VERSION)
    }

    @Test
    fun publicGatewayMoveKeepsMachineSelectionAndSeparatesCredentialOrigins() {
        val old = DieterEndpoint("selected", "Machine", "board.dbpprt.com", 443, true, daemonId = "daemon")
        val moved = old.currentPublicGateway
        assertEquals(old.id, moved.id)
        assertEquals(old.daemonId, moved.daemonId)
        assertEquals("https://gateway.getdieter.com:443", moved.credentialId)
        assertEquals("https://board.dbpprt.com:443", old.credentialId)
        for (custom in listOf(old.copy(port = 8443), old.copy(secure = false), old.copy(host = "private.example"))) {
            assertEquals(custom, custom.currentPublicGateway)
        }
    }

    private fun snapshot(vararg messages: UiMessage): ConversationSnapshot = ConversationSnapshot.newBuilder()
        .setDetail(CardDetail.getDefaultInstance())
        .setConversation(Conversation.newBuilder().addAllMessages(messages.toList()))
        .build()

    private fun message(id: String, text: String): UiMessage = UiMessage.newBuilder()
        .setId(id)
        .setRole("assistant")
        .addParts(MessagePart.newBuilder().setType("text").setText(text))
        .build()
}
