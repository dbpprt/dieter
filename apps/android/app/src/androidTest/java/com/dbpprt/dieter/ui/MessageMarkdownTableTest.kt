package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
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
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.e2e.saveEvidence
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
        compose.onRoot().saveEvidence("markdown-table-before.png")

        compose.onNodeWithTag("markdown-table").performTouchInput { swipeLeft(durationMillis = 500) }
        compose.waitForIdle()

        compose.onNodeWithText("GPU temp / power").assertIsDisplayed()
        compose.onNodeWithText("84°C / 57.4 W").assertIsDisplayed()
        compose.onRoot().saveEvidence("markdown-table-after.png")
    }
}
