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

    @Test fun remoteDirectoryUpdatesStillInvalidateInactivePages() {
        val cache = PrimaryPageState(Destination.CHATS)
        val original = DieterUiState(destination = Destination.BOARD)
        val page = cache.project(original)
        val chat = Card.newBuilder().setId("chat").setTitle("New remote title").build()
        val changed = original.copy(chats = listOf(chat), selectedCardId = chat.id)
        val updated = cache.project(changed)
        assertNotSame(page, updated)
        assertEquals(Destination.CHATS, updated.destination)
        assertEquals(chat, updated.chats.single())
        assertNull(updated.selectedCardId)
        assertSame(updated, cache.project(changed.copy(destination = Destination.ACTIVITY)))
    }

    @Test fun onlyTheSelectedPageReceivesTheConversationAndItsStream() {
        val caches = listOf(Destination.ACTIVITY, Destination.BOARD, Destination.CHATS).associateWith(::PrimaryPageState)
        val original = DieterUiState(destination = Destination.CHATS, selectedCardId = "chat")
        val initial = caches.mapValues { it.value.project(original) }
        assertEquals(1, initial.values.count { it.selectedCardId == "chat" })
        val transcript = ConversationSnapshot.newBuilder()
            .setConversation(Conversation.newBuilder().setLastSeq(2)).build()
        val changed = original.copy(conversation = transcript, conversationRefreshing = true,
            historyTotal = 400, historyHasMore = true, conversationScrollRequest = 3, detailTab = 1)
        for ((destination, cache) in caches) {
            val streamed = cache.project(changed)
            if (destination == Destination.CHATS) {
                assertNotSame(initial[destination], streamed)
                assertSame(changed, streamed)
            } else {
                assertSame(initial[destination], streamed)
                assertNull(streamed.conversation)
            }
        }
        // Navigating and opening a card on a different page must expose fresh
        // detail there and remove it from the former destination.
        val moved = changed.copy(destination = Destination.BOARD, selectedCardId = "board-card")
        val pages = caches.mapValues { it.value.project(moved) }
        assertSame(moved, pages[Destination.BOARD])
        assertNull(pages[Destination.CHATS]?.selectedCardId)
        assertEquals(1, pages.values.count { it.conversation != null })
    }
}
