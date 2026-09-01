package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.UiMessage
import org.junit.Assert.assertEquals
import org.junit.Test

class MergedConversationMessagesTest {
    @Test
    fun liveTailReplacesHistoryDuplicatesWithoutReorderingHistory() {
        val older = listOf(message("one"), message("two", "old"), message(""))
        val live = listOf(message("two", "fresh"), message("three"))

        val merged = mergedConversationMessages(older, live)

        assertEquals(listOf("one", "", "two", "three"), merged.map(UiMessage::getId))
        assertEquals("fresh", merged.first { it.id == "two" }.role)
    }

    private fun message(id: String, role: String = "assistant"): UiMessage = UiMessage.newBuilder()
        .setId(id)
        .setRole(role)
        .build()
}
