package com.dbpprt.dieter.core.conversation

import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.UiMessage
import kotlin.test.Test
import kotlin.test.assertEquals

class ConversationViewTest {
    private fun message(id: String, role: String = "assistant") = UiMessage(id = id, role = role)

    @Test
    fun liveWindowReplacesHistoryCopiesWithoutReorderingHistory() {
        val history = TranscriptState(older = listOf(message("one"), message("two", "old"), message("")))
        val view = ConversationView(
            cardId = "c",
            transcript = history,
            presented = ConversationSnapshot(conversation = Conversation(messages = listOf(message("two", "fresh"), message("three")))),
        )
        assertEquals(listOf("one", "", "two", "three"), view.messages.map { it.id })
        assertEquals("fresh", view.messages.single { it.id == "two" }.role, "the live copy wins")
        assertEquals(listOf("one", "two", ""), ConversationView(cardId = "c", transcript = history).messages.map { it.id }, "history shows before the live window arrives")
    }
}
