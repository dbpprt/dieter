package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.connection.ConnectionPhase

/** Where a request to open a conversation from outside the app (a notification, a widget row) lands. */
sealed interface OpenTarget {
    /** Keep the request: the conversation may still arrive with the cached or first live projection. */
    data object Wait : OpenTarget

    data class Conversation(val card: Card, val destination: Destination) : OpenTarget

    /** The conversation is gone (archived or deleted): the inbox shows what remains. */
    data object Inbox : OpenTarget
}

object OpenRequests {
    /** Where a conversation opens by itself: a chat among the chats, a card on its board. */
    fun destination(card: Card): Destination = if (Cards.isChat(card)) Destination.CHATS else Destination.BOARD

    /**
     * Resolves a request for [cardId] against the [cards] shown now. [inInbox]
     * opens it beside the inbox (a widget row), otherwise where it belongs. A
     * missing conversation waits while the workspace is still [loading] or the
     * connection is on its way; after that the request falls back to the inbox.
     */
    fun resolve(cardId: String, cards: List<Card>, inInbox: Boolean, loading: Boolean, phase: ConnectionPhase): OpenTarget {
        val card = cards.firstOrNull { it.id == cardId && !it.archived }
        return when {
            card != null -> OpenTarget.Conversation(card, if (inInbox) Destination.ACTIVITY else destination(card))
            cardId.isNotBlank() && (loading || phase in SETTLING) -> OpenTarget.Wait
            else -> OpenTarget.Inbox
        }
    }

    private val SETTLING = setOf(ConnectionPhase.CONNECTING, ConnectionPhase.SYNCING, ConnectionPhase.RECONNECTING)
}
