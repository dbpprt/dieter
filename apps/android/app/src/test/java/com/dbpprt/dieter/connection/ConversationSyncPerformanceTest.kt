package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.GlobalDelta
import com.dbpprt.dieter.v1.GlobalSnapshot
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.State
import org.junit.Assert.*
import org.junit.Test

class ConversationSyncPerformanceTest {
    private fun conversation(id: String, sequence: Long) = ConversationSnapshot.newBuilder()
        .setDetail(CardDetail.newBuilder().setCard(Card.newBuilder().setId(id)))
        .setConversation(Conversation.newBuilder().setCardId(id).setLastSeq(sequence))
        .build()

    @Test
    fun transcriptDeltaPreservesProtobufDirectoryAndStillAppliesTombstones() {
        val directory = State.newBuilder().addProjects(Project.newBuilder().setId("project"))
            .addAllChats((1..1_000).map { Card.newBuilder().setId("chat-$it").build() }).build()
        var snapshot = GlobalSnapshot.newBuilder().setState(directory).build()
        repeat(1_000) { sequence ->
            snapshot = applyGlobalDelta(snapshot, GlobalDelta.newBuilder()
                .addConversations(conversation("streaming", sequence.toLong())).build())
            assertSame(directory, snapshot.state)
        }
        assertEquals(999L, snapshot.conversationsList.single().conversation.lastSeq)
        val removed = applyGlobalDelta(snapshot, GlobalDelta.newBuilder()
            .addRemovedChatIds("chat-500").addRemovedConversationIds("streaming").build())
        assertEquals(999, removed.state.chatsCount)
        assertFalse(removed.state.chatsList.any { it.id == "chat-500" })
        assertEquals(0, removed.conversationsCount)
    }

    @Test
    fun transcriptReplayPreservesWorkspaceObjectsAndRejectsOlderTails() {
        val original = DieterConnectionState(
            desiredConnected = true, backgroundSyncMode = BackgroundSyncMode.LIVE,
            activeGatewayId = "gateway", configuredConnections = emptyList(), endpointConnections = emptyList(),
            projects = listOf(Project.newBuilder().setId("project").build()),
            chats = (1..1_000).map { Card.newBuilder().setId("chat-$it").build() },
            selectedState = State.newBuilder().setProject(Project.newBuilder().setId("project")).build(),
            activeConversations = mapOf("selected" to conversation("selected", 2_000)),
        )
        var state = original
        repeat(1_000) { index ->
            val snapshot = GlobalSnapshot.newBuilder()
                .addConversations(conversation("streaming", index.toLong()))
                .addConversations(conversation("selected", 1))
                .build()
            state = state.applyingConversationSync(snapshot, setOf("streaming"), index.toLong(), 24)
        }
        assertSame(original.projects, state.projects)
        assertSame(original.chats, state.chats)
        assertSame(original.selectedState, state.selectedState)
        assertEquals(999L, state.activeConversations.getValue("streaming").conversation.lastSeq)
        assertEquals(2_000L, state.activeConversations.getValue("selected").conversation.lastSeq)
        assertEquals(999L, state.conversationRefreshedAtMillis["streaming"])
    }

    @Test
    fun coverageRemovalRetainsCacheUntilBoundedEviction() {
        val state = DieterConnectionState(
            desiredConnected = true, backgroundSyncMode = BackgroundSyncMode.LIVE,
            activeGatewayId = "gateway", configuredConnections = emptyList(), endpointConnections = emptyList(),
            activeConversations = (1..24).associate { "chat-$it" to conversation("chat-$it", 1) },
            conversationRefreshedAtMillis = mapOf("chat-1" to 1L),
        )
        val incoming = GlobalSnapshot.newBuilder().addConversations(conversation("new", 2)).build()
        val next = state.applyingConversationSync(incoming, setOf("new"), 2, 24)
        assertEquals(24, next.activeConversations.size)
        assertFalse(next.activeConversations.containsKey("chat-1"))
        assertFalse(next.conversationRefreshedAtMillis.containsKey("chat-1"))
        assertEquals(setOf("new"), next.liveSyncedConversationIds)
        assertTrue(next.activeConversations.containsKey("chat-24"))
    }

    @Test
    fun metadataAndTombstonesRequireWorkspaceMerge() {
        assertFalse(GlobalDelta.newBuilder().addConversations(conversation("chat", 1)).build().changesWorkspace())
        assertFalse(GlobalDelta.newBuilder().addRemovedConversationIds("chat").build().changesWorkspace())
        assertTrue(GlobalDelta.newBuilder().addRemovedCardIds("card").build().changesWorkspace())
        assertTrue(GlobalDelta.newBuilder().addChats(Card.getDefaultInstance()).build().changesWorkspace())
    }
}
