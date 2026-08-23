package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class CardDetailTabsTest {
    @Test
    fun boardCardsShowSubagentsAfterCommentsLikeMac() {
        assertEquals(
            listOf("Conversation", "Comments", "Subagents"),
            detailSectionsFor(standalone = false).map(DetailSection::label),
        )
    }

    @Test
    fun standaloneChatsKeepSubagentsNextToConversation() {
        assertEquals(
            listOf("Conversation", "Subagents", "Comments"),
            detailSectionsFor(standalone = true).map(DetailSection::label),
        )
    }
}
