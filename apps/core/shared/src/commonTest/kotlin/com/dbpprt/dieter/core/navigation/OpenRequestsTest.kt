package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.connection.ConnectionPhase
import kotlin.test.Test
import kotlin.test.assertEquals

class OpenRequestsTest {
    private val chat = Card(id = "chat", scope = "chat")
    private val filedChat = Card(id = "filed", scope = "chat", board_id = "b1")
    private val card = Card(id = "card", scope = "board", board_id = "b1")

    @Test
    fun chatsOpenAmongTheChatsAndCardsOnTheirBoardUnlessTheInboxAsked() {
        val cards = listOf(chat, filedChat, card)
        assertEquals(OpenTarget.Conversation(chat, Destination.CHATS), OpenRequests.resolve("chat", cards, inInbox = false, loading = false, ConnectionPhase.CONNECTED, catchingUp = false))
        // A chat filed on a board is a card.
        assertEquals(OpenTarget.Conversation(filedChat, Destination.BOARD), OpenRequests.resolve("filed", cards, inInbox = false, loading = false, ConnectionPhase.CONNECTED, catchingUp = false))
        assertEquals(OpenTarget.Conversation(card, Destination.ACTIVITY), OpenRequests.resolve("card", cards, inInbox = true, loading = false, ConnectionPhase.CONNECTED, catchingUp = false))
    }

    @Test
    fun aMissingConversationWaitsForTheWorkspaceThenFallsBackToTheInbox() {
        val archived = card.copy(archived = true)
        assertEquals(OpenTarget.Wait, OpenRequests.resolve("card", emptyList(), inInbox = false, loading = true, ConnectionPhase.CONNECTED, catchingUp = false))
        assertEquals(OpenTarget.Wait, OpenRequests.resolve("card", emptyList(), inInbox = true, loading = false, ConnectionPhase.CONNECTED, catchingUp = true), "a machine catching up may still list it")
        assertEquals(OpenTarget.Wait, OpenRequests.resolve("card", emptyList(), inInbox = true, loading = false, ConnectionPhase.RECONNECTING, catchingUp = false))
        assertEquals(OpenTarget.Inbox, OpenRequests.resolve("card", listOf(archived), inInbox = false, loading = false, ConnectionPhase.CONNECTED, catchingUp = false))
        assertEquals(OpenTarget.Inbox, OpenRequests.resolve("card", emptyList(), inInbox = false, loading = false, ConnectionPhase.DISCONNECTED, catchingUp = false))
        assertEquals(OpenTarget.Inbox, OpenRequests.resolve("", emptyList(), inInbox = true, loading = true, ConnectionPhase.CONNECTING, catchingUp = false))
    }
}
