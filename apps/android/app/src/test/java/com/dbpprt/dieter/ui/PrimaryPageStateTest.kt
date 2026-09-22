package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.ConversationSnapshot
import org.junit.Assert.*
import org.junit.Test

class PrimaryPageStateTest {
    @Test fun repeatedTabSelectionRetainsPageIdentity() {
        val cache = PrimaryPageState(Destination.CHATS)
        val original = DieterUiState(destination = Destination.CHATS)
        val page = cache.project(original)
        repeat(1_000) { index ->
            val selected = listOf(Destination.ACTIVITY, Destination.BOARD, Destination.CHATS)[index % 3]
            assertSame(page, cache.project(original.copy(destination = selected)))
        }
    }

    @Test fun remoteContentAndDetailSelectionStillInvalidateThePage() {
        val cache = PrimaryPageState(Destination.CHATS)
        val original = DieterUiState(destination = Destination.BOARD)
        val page = cache.project(original)
        val chat = Card.newBuilder().setId("chat").setTitle("New remote title").build()
        val changed = original.copy(chats = listOf(chat), selectedCardId = chat.id)
        val updated = cache.project(changed)
        assertNotSame(page, updated)
        assertEquals(Destination.CHATS, updated.destination)
        assertEquals(chat, updated.chats.single())
        assertEquals(chat.id, updated.selectedCardId)
        assertSame(updated, cache.project(changed.copy(destination = Destination.ACTIVITY)))
        val transcript = ConversationSnapshot.newBuilder()
            .setConversation(Conversation.newBuilder().setLastSeq(2)).build()
        val streamed = cache.project(changed.copy(conversation = transcript))
        assertNotSame(updated, streamed)
        assertEquals(2L, streamed.conversation?.conversation?.lastSeq)
        assertNotSame(streamed, cache.project(changed.copy(selectedCardId = null)))
    }
}
