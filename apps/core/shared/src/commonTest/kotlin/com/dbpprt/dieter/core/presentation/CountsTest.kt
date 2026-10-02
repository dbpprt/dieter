package com.dbpprt.dieter.core.presentation

import kotlin.test.Test
import kotlin.test.assertEquals

class CountsTest {
    @Test
    fun countedNounsArePluralUnlessThereIsExactlyOne() {
        assertEquals("1 chat", Counts.of(1, "chat"))
        assertEquals("0 chats", Counts.of(0, "chat"))
        assertEquals("3 chats", Counts.of(3, "chat"))
        assertEquals("2 activities", Counts.of(2, "activity", "activities"))
        assertEquals("needs", Counts.word(1, "needs", "need"))
        assertEquals("need", Counts.word(4, "needs", "need"))
    }
}
