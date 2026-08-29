package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class CardDetailTabsTest {
    @Test
    fun boardCardsShowSubagentsAfterCommentsLikeMac() {
        assertEquals(
            listOf("Conversation", "Changes", "Comments", "Subagents"),
            detailSectionsFor(standalone = false).map(DetailSection::label),
        )
    }

    @Test
    fun standaloneChatsKeepSubagentsNextToConversation() {
        assertEquals(
            listOf("Conversation", "Changes", "Subagents", "Comments"),
            detailSectionsFor(standalone = true).map(DetailSection::label),
        )
    }
}
