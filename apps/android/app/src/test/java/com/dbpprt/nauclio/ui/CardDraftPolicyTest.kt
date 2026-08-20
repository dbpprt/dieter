package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Card
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CardDraftPolicyTest {
    @Test
    fun exposesAnUnsentBoardTaskAsDraftContent() {
        val card = card(prompt = "  Verify the native flow  ")

        assertEquals("Verify the native flow", card.unsentTaskText())
        assertTrue(card.canEditInitialTask())
    }

    @Test
    fun hidesTasksThatWereSentOrBelongToStandaloneChats() {
        assertNull(card(sentAt = "2026-08-17T08:00:00Z").unsentTaskText())
        assertNull(card(scope = "chat").unsentTaskText())
        assertNull(card(prompt = " ").unsentTaskText())
        assertFalse(card(sentAt = "2026-08-17T08:00:00Z").canEditInitialTask())
    }

    private fun card(
        scope: String = "board",
        prompt: String = "Verify Android",
        sentAt: String = "",
    ): Card = Card.newBuilder()
        .setScope(scope)
        .setInitialPrompt(prompt)
        .setInitialPromptSentAt(sentAt)
        .build()
}
