package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class CardDetailTabsTest {
    @Test
    fun boardCardsShowConversationChangesAndSubagents() {
        assertEquals(
            listOf("Conversation", "Changes", "Subagents"),
            detailSectionsFor().map(DetailSection::label),
        )
    }

    @Test
    fun standaloneChatsKeepSubagentsNextToConversation() {
        assertEquals(
            listOf("Conversation", "Changes", "Subagents"),
            detailSectionsFor().map(DetailSection::label),
        )
    }
}
