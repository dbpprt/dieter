package com.dbpprt.dieter.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.QueuedMessage
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class QueuedMessageBlockTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun queuedMessageLooksLikePendingUserContentAndCanInterrupt() {
        var interrupts = 0
        val queued = QueuedMessage.newBuilder()
            .setId("queued-test")
            .addParts(MessagePart.newBuilder().setType("text").setText("Queued emulator follow-up"))
            .build()

        composeRule.setContent {
            DieterTheme {
                QueuedMessageBlock(
                    queued = queued,
                    showInterrupt = true,
                    interrupting = false,
                    onInterrupt = { interrupts += 1 },
                )
            }
        }

        composeRule.onNodeWithTag("queued-message-queued-test").assertIsDisplayed()
        composeRule.onNodeWithText("Queued emulator follow-up").assertIsDisplayed()
        composeRule.onNodeWithTag("interrupt-queued-message").assertIsDisplayed().performClick()
        assertEquals(1, interrupts)
    }
}
