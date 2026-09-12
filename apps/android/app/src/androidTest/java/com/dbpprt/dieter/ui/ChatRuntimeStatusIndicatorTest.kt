package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Card
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ChatRuntimeStatusIndicatorTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun activeChatPulsesWhileInactiveChatStaysStill() {
        val runningTitle = "Security review for foldable Android layouts"
        composeRule.mainClock.autoAdvance = false
        composeRule.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Column(
                        Modifier.padding(28.dp),
                        verticalArrangement = Arrangement.spacedBy(18.dp),
                    ) {
                        Text("Chat activity", style = MaterialTheme.typography.titleLarge)
                        StatusFixture(
                            card = card("running", runningTitle, running = true, pinned = true),
                        )
                        StatusFixture(
                            card = card("inactive", "Release notes", running = false),
                        )
                    }
                }
            }
        }

        composeRule.onNodeWithTag("chat-runtime-running").assertIsDisplayed()
            .assertContentDescriptionEquals("Chat is running")
            .assertTextEquals("Running")
        composeRule.onNodeWithTag("chat-runtime-inactive").assertIsDisplayed()
            .assertContentDescriptionEquals("Chat is not running")
            .assertTextEquals("Not running")
        composeRule.onNodeWithTag("chat-title-running").assertIsDisplayed().assertTextEquals(runningTitle)
        composeRule.onNodeWithTag("chat-project-running").assertIsDisplayed().assertTextEquals("Dieter")
        composeRule.onNodeWithTag("chat-project-inactive").assertIsDisplayed().assertTextEquals("Dieter")

        val activeBefore = composeRule.onNodeWithTag("chat-runtime-running").captureToImage().asAndroidBitmap()
        val inactiveBefore = composeRule.onNodeWithTag("chat-runtime-inactive").captureToImage().asAndroidBitmap()
        capture("chat-runtime-status-before.png")

        composeRule.mainClock.advanceTimeBy(575)
        composeRule.waitForIdle()

        val activeAfter = composeRule.onNodeWithTag("chat-runtime-running").captureToImage().asAndroidBitmap()
        val inactiveAfter = composeRule.onNodeWithTag("chat-runtime-inactive").captureToImage().asAndroidBitmap()
        capture("chat-runtime-status-after.png")

        assertFalse("The active status should visibly animate", activeBefore.sameAs(activeAfter))
        assertTrue("The inactive status should remain visually still", inactiveBefore.sameAs(inactiveAfter))
    }

    @Composable
    private fun StatusFixture(card: Card) {
        val running = card.runtime == "running"
        Surface(
            shape = MaterialTheme.shapes.large,
            tonalElevation = 2.dp,
            modifier = Modifier.width(320.dp),
        ) {
            Row(
                Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ChatRowContent(chat = card, running = running, projectLabel = "Dieter")
            }
        }
    }

    private fun card(id: String, title: String, running: Boolean, pinned: Boolean = false): Card =
        Card.newBuilder()
            .setId(id)
            .setTitle(title)
            .setRuntime(if (running) "running" else "idle")
            .setPinned(pinned)
            .setLastActivityAt("2026-09-05T20:40:00Z")
            .build()

    private fun capture(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val screenshot = File(requireNotNull(context.getExternalFilesDir(null)), name)
        val pendingScreenshot = File(screenshot.parentFile, "$name.pending")
        pendingScreenshot.outputStream().use { output ->
            assertTrue(
                composeRule.onRoot().captureToImage().asAndroidBitmap()
                    .compress(Bitmap.CompressFormat.PNG, 100, output),
            )
        }
        screenshot.delete()
        assertTrue(pendingScreenshot.renameTo(screenshot))
    }
}
