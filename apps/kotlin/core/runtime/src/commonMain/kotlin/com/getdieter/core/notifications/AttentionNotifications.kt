package com.getdieter.core.notifications

import com.getdieter.api.v1.Card
import com.getdieter.core.activity.Activity
import com.getdieter.core.activity.ActivityKind

data class PushDevice(val token: String, val publicKey: okio.ByteString, val sandbox: Boolean)

/** The phone's system notification surface. Decisions stay in the shared core. */
interface AttentionNotificationSink {
    fun post(cardId: String, title: String, text: String)

    /** Reconcile delivered alerts too, including ones left by a previous app process. */
    fun reconcile(cardIds: List<String>, badge: Int)

    fun reset()

    fun visible(cardId: String?) {}

    fun device(accountKey: String): PushDevice? = null

    fun registered(available: Boolean) {}
}

/** Unread replies and questions, using exactly the Inbox's Needs you rules. */
class AttentionNotifications(private val sink: AttentionNotificationSink) {
    private var previous: Map<String, String> = emptyMap()

    fun reset() {
        previous = emptyMap()
        sink.reset()
    }

    /** A replay updates badges and receipts but never announces a backlog. */
    fun frame(
        cards: List<Card>,
        visibleId: String? = null,
        replaying: (Card) -> Boolean = { false },
    ) {
        val attention = cards.filter { !it.archived && Activity.classify(it)?.needsYou == true }
        val next = attention.associate { it.id to fingerprint(it) }
        sink.visible(visibleId)
        sink.reconcile(attention.filterNot { it.id == visibleId }.map { it.id }, attention.size)
        for (card in attention) {
            val before = previous[card.id]
            if (replaying(card) || card.id == visibleId || before == next[card.id]) continue
            sink.post(
                card.id,
                if (Activity.classify(card) == ActivityKind.ANSWER) "Task needs you"
                else "New reply",
                Activity.title(card),
            )
        }
        previous = next
    }

    private fun fingerprint(card: Card): String =
        when (Activity.classify(card)) {
            ActivityKind.ANSWER -> "question:${card.runtime_updated_at}:${card.response_seq}"
            else -> "reply:${card.response_seq}"
        }
}
