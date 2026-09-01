package com.dbpprt.dieter.connection

import com.dbpprt.dieter.settings.DieterNotificationSettings
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.PendingTool
import com.dbpprt.dieter.v1.UiMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class NotificationRenderPolicyTest {
    @Test
    fun transcriptTokensAndHeartbeatTimesDoNotRepostConnectionNotification() {
        val first = state(snapshot("Partial answer"), lastConnectedAtMs = 1_000)
        val second = state(snapshot("A much longer streaming answer"), lastConnectedAtMs = 50_000)

        assertEquals(fingerprint(first), fingerprint(second))
    }

    @Test
    fun visibleAgentActivityAndPaletteChangesDoRepostNotification() {
        val idleActivity = state(snapshot("Answer"))
        val toolActivity = state(
            snapshot(
                "Answer",
                PendingTool.newBuilder().setToolName("exec_command").build(),
            ),
        )

        assertNotEquals(fingerprint(idleActivity), fingerprint(toolActivity))
        assertNotEquals(fingerprint(idleActivity), connectionNotificationFingerprint(
            idleActivity,
            DieterNotificationSettings(),
            "electric-blue",
        ))
    }

    private fun fingerprint(state: DieterConnectionState): Int = connectionNotificationFingerprint(
        state,
        DieterNotificationSettings(),
        "monochrome",
    )

    private fun state(snapshot: ConversationSnapshot, lastConnectedAtMs: Long = 0): DieterConnectionState {
        val card = snapshot.detail.card
        return DieterConnectionState(
            desiredConnected = true,
            backgroundSyncEnabled = true,
            phase = ConnectionPhase.CONNECTED,
            activeGatewayId = "gateway",
            configuredConnections = emptyList(),
            endpointConnections = emptyList(),
            lastConnectedAtMs = lastConnectedAtMs,
            chats = listOf(card),
            activeConversations = mapOf(card.id to snapshot),
        )
    }

    private fun snapshot(text: String, pendingTool: PendingTool? = null): ConversationSnapshot {
        val card = Card.newBuilder()
            .setId("chat-one")
            .setTitle("Android review")
            .setSummary("Working on the app")
            .setScope("chat")
            .setRuntime("running")
            .setRuntimeUpdatedAt("2026-09-01T12:00:00Z")
            .build()
        val conversation = Conversation.newBuilder()
            .setCardId(card.id)
            .addMessages(
                UiMessage.newBuilder()
                    .setId("assistant")
                    .setRole("assistant")
                    .addParts(MessagePart.newBuilder().setType("text").setText(text)),
            )
            .also { builder -> pendingTool?.let(builder::addPendingTools) }
            .build()
        return ConversationSnapshot.newBuilder()
            .setDetail(CardDetail.newBuilder().setCard(card))
            .setConversation(conversation)
            .build()
    }
}
