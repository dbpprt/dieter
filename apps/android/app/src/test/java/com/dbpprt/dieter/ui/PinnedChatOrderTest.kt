package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import org.junit.Assert.assertEquals
import org.junit.Test

class PinnedChatOrderTest {
    @Test
    fun `saved order is applied and new pins use their fixed position`() {
        val chats = listOf(
            chat("new-pin", 4_096),
            chat("beta", 2_048),
            chat("alpha", 1_024),
        )

        val ordered = orderedPinnedChats(chats, listOf("beta", "missing", "alpha"))

        assertEquals(listOf("beta", "alpha", "new-pin"), ordered.map { it.id })
    }

    @Test
    fun `input order is preserved while the initial fixed order is being saved`() {
        val chats = listOf(chat("latest-activity", 3_072), chat("first-pin", 1_024), chat("middle", 2_048))

        assertEquals(
            listOf("latest-activity", "first-pin", "middle"),
            orderedPinnedChats(chats, emptyList()).map { it.id },
        )
    }

    @Test
    fun `dropping on a later chat moves after the target`() {
        assertEquals(
            listOf("beta", "gamma", "alpha", "delta"),
            movePinnedChatToTarget(listOf("alpha", "beta", "gamma", "delta"), "alpha", "gamma"),
        )
    }

    @Test
    fun `dropping on an earlier chat moves before the target`() {
        assertEquals(
            listOf("alpha", "delta", "beta", "gamma"),
            movePinnedChatToTarget(listOf("alpha", "beta", "gamma", "delta"), "delta", "beta"),
        )
    }

    @Test
    fun `invalid drops do not alter order`() {
        val current = listOf("alpha", "beta")

        assertEquals(current, movePinnedChatToTarget(current, "alpha", "alpha"))
        assertEquals(current, movePinnedChatToTarget(current, "missing", "beta"))
        assertEquals(current, movePinnedChatToTarget(current, "alpha", "missing"))
    }

    private fun chat(id: String, position: Long): Card = Card.newBuilder()
        .setId(id)
        .setPosition(position)
        .setPinned(true)
        .build()
}
