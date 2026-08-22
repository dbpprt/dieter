package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Conversation
import com.dbpprt.nauclio.v1.ConversationSnapshot
import com.dbpprt.nauclio.v1.UiMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationUiCacheTest {
    @Test
    fun boundsCachedHistoryAndKeepsPagingContinuous() {
        val cache = ConversationUiCache(maxConversations = 2, maxMessagesPerConversation = 4)
        cache.put(
            "card",
            cached(live = listOf(message("4"), message("5")), older = listOf(message("1"), message("2"), message("3")), start = 0),
        )

        val result = requireNotNull(cache["card"])
        assertEquals(listOf("2", "3"), result.olderMessages.map { it.id })
        assertEquals(1, result.historyStart)
        assertTrue(result.historyHasMore)
    }

    @Test
    fun evictsLeastRecentlyUsedConversation() {
        val cache = ConversationUiCache(maxConversations = 2)
        cache.put("one", cached())
        cache.put("two", cached())
        cache["one"]
        cache.put("three", cached())

        assertNull(cache["two"])
        requireNotNull(cache["one"])
        requireNotNull(cache["three"])
    }

    @Test
    fun liveTailWinsWhenItOverlapsLoadedHistory() {
        val state = NauclioUiState(
            conversation = ConversationSnapshot.newBuilder()
                .setConversation(
                    Conversation.newBuilder()
                        .addMessages(message("2").toBuilder().setRole("live")),
                )
                .build(),
            olderMessages = listOf(message("1"), message("2").toBuilder().setRole("stale").build()),
        )

        assertEquals(listOf("1", "2"), state.conversationMessages.map { it.id })
        assertEquals("live", state.conversationMessages.last().role)
    }

    private fun cached(
        live: List<UiMessage> = emptyList(),
        older: List<UiMessage> = emptyList(),
        start: Int = 0,
    ) = CachedConversationUi(
        snapshot = ConversationSnapshot.newBuilder()
            .setConversation(Conversation.newBuilder().addAllMessages(live))
            .build(),
        olderMessages = older,
        historyStart = start,
        historyTotal = live.size + older.size,
        historyHasMore = false,
    )

    private fun message(id: String): UiMessage = UiMessage.newBuilder().setId(id).build()
}
