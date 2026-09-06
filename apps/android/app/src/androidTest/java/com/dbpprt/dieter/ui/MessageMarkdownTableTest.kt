package com.dbpprt.dieter.ui

import android.os.ParcelFileDescriptor
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class MessageMarkdownTableTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun modelPipeTableRendersAndScrollsOnANarrowScreen() {
        compose.setContent {
            DieterTheme(darkTheme = true) {
                Surface(
                    Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    Column(Modifier.safeDrawingPadding().padding(16.dp)) {
                        MessageMarkdown(
                            """
                            Snapshot at 21:33 CEST:
                            | Node | CPU | GPU | Unified RAM | Swap | GPU temp / power |
                            |---|---:|---:|---:|---:|---:|
                            | `gx10-c674` | ~6% | 96% | 115.7 / 121.6 GiB (95.2%) | 7.1 / 16 GiB | 80°C / 53.6 W |
                            | `gx10-d6c4` | ~10% | 96% | 114.8 / 121.6 GiB (94.4%) | 4.9 / 16 GiB | 84°C / 57.4 W |
                            Available RAM: 5.9 GiB on the head and 6.9 GiB on the worker.
                            """.trimIndent(),
                            compact = false,
                        )
                    }
                }
            }
        }

        compose.onNodeWithText("Snapshot at 21:33 CEST:").assertIsDisplayed()
        compose.onNodeWithText("Node").assertIsDisplayed()
        compose.onNodeWithText("gx10-c674").assertIsDisplayed()
        assertTrue(compose.onAllNodesWithText("|---|---:|---:|---:|---:|---:|").fetchSemanticsNodes().isEmpty())
        compose.onNodeWithText("GPU temp / power").assertIsNotDisplayed()
        capture("markdown-table-before.png")

        compose.onNodeWithTag("markdown-table").performTouchInput { swipeLeft(durationMillis = 500) }
        compose.waitForIdle()

        compose.onNodeWithText("GPU temp / power").assertIsDisplayed()
        compose.onNodeWithText("84°C / 57.4 W").assertIsDisplayed()
        capture("markdown-table-after.png")
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val rendered = compose.onRoot().captureToImage().asAndroidBitmap()
        assertTrue(rendered.width > 0 && rendered.height > 0 && rendered.byteCount > 0)
        Thread.sleep(300)
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand("screencap -p /sdcard/Download/$name")
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            while (input.read() != -1) {}
        }
    }
}
