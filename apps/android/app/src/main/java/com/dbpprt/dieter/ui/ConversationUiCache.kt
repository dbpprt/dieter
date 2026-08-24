package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.UiMessage

internal data class CachedConversationUi(
    val snapshot: ConversationSnapshot,
    val olderMessages: List<UiMessage>,
    val historyStart: Int,
    val historyTotal: Int,
    val historyHasMore: Boolean,
    val refreshedAtMillis: Long?,
)

/** Small, process-local LRU for instant chat switching without retaining unbounded transcripts. */
internal class ConversationUiCache(
    private val maxConversations: Int = 8,
    private val maxMessagesPerConversation: Int = 120,
) {
    init {
        require(maxConversations > 0)
        require(maxMessagesPerConversation > 0)
    }

    private val entries = object : LinkedHashMap<String, CachedConversationUi>(maxConversations, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedConversationUi>?): Boolean =
            size > maxConversations
    }

    operator fun get(cardId: String): CachedConversationUi? = entries[cardId]

    fun put(cardId: String, value: CachedConversationUi) {
        val liveCount = value.snapshot.conversation.messagesCount
        val olderLimit = (maxMessagesPerConversation - liveCount).coerceAtLeast(0)
        val dropped = (value.olderMessages.size - olderLimit).coerceAtLeast(0)
        entries[cardId] = value.copy(
            olderMessages = value.olderMessages.drop(dropped),
            historyStart = value.historyStart + dropped,
            historyHasMore = value.historyHasMore || dropped > 0,
        )
    }
}
