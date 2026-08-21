package com.dbpprt.nauclio.connection

import com.dbpprt.nauclio.v1.Card
import com.dbpprt.nauclio.v1.CardDetail
import com.dbpprt.nauclio.v1.Conversation
import com.dbpprt.nauclio.v1.ConversationSnapshot
import com.dbpprt.nauclio.v1.UiMessage
import org.junit.Assert.assertSame
import org.junit.Test

class ConversationFreshnessTest {
    @Test
    fun missingExistingAlwaysAcceptsIncoming() {
        val incoming = snapshot(lastSeq = 1)
        assertSame(incoming, freshestConversation(null, incoming))
    }

    @Test
    fun higherSequenceWinsRegardlessOfDirection() {
        val older = snapshot(lastSeq = 4)
        val newer = snapshot(lastSeq = 9)
        assertSame(newer, freshestConversation(older, newer))
        assertSame(newer, freshestConversation(newer, older))
    }

    @Test
    fun equalSequenceKeepsRicherPage() {
        val paged = snapshot(lastSeq = 6, messageCount = 40)
        val tail = snapshot(lastSeq = 6, messageCount = 8)
        assertSame(paged, freshestConversation(paged, tail))
        assertSame(paged, freshestConversation(tail, paged))
    }

    @Test
    fun equalSequenceAndPagePrefersIncoming() {
        val existing = snapshot(lastSeq = 6, messageCount = 8)
        val incoming = snapshot(lastSeq = 6, messageCount = 8)
        assertSame(incoming, freshestConversation(existing, incoming))
    }

    private fun snapshot(lastSeq: Long, messageCount: Int = 1): ConversationSnapshot {
        val conversation = Conversation.newBuilder()
            .setCardId("c_test")
            .setLastSeq(lastSeq)
            .addAllMessages(
                (0 until messageCount).map { index ->
                    UiMessage.newBuilder().setId("msg_$index").setRole("assistant").build()
                },
            )
            .build()
        return ConversationSnapshot.newBuilder()
            .setDetail(CardDetail.newBuilder().setCard(Card.newBuilder().setId("c_test")))
            .setConversation(conversation)
            .build()
    }
}
