package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.ui.theme.DieterTheme
import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class WorkspaceFreshnessIndicatorTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun reconnectingCachedWorkspaceIsExplicitAndScreenshotable() {
        composeRule.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                        ConnectionStatusIndicator(
                            phase = ConnectionPhase.RECONNECTING,
                            lastConnectedAtMillis = System.currentTimeMillis() - 120_000L,
                            showingCachedData = true,
                            modifier = Modifier.fillMaxWidth().padding(12.dp),
                        )
                    }
                }
            }
        }

        composeRule.onNodeWithTag("workspace-connection-status").assertIsDisplayed()
        composeRule.onNodeWithText("Reconnecting to Dieter").assertIsDisplayed()
        composeRule.onNodeWithText("Cached data stays visible while the connection recovers.").assertIsDisplayed()
        composeRule.onNodeWithText("Updated 2m ago").assertIsDisplayed()

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val screenshot = File(requireNotNull(context.getExternalFilesDir(null)), "workspace-freshness-indicator.png")
        val pendingScreenshot = File(screenshot.parentFile, "workspace-freshness-indicator.pending")
        pendingScreenshot.outputStream().use { output ->
            assertTrue(composeRule.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output))
        }
        screenshot.delete()
        assertTrue(pendingScreenshot.renameTo(screenshot))
    }

    @Test
    fun firstSyncIsVisibleInsteadOfAnEmptyBoard() {
        composeRule.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    InitialWorkspaceSyncState(ConnectionPhase.SYNCING)
                }
            }
        }

        composeRule.onNodeWithTag("workspace-initial-sync").assertIsDisplayed()
        composeRule.onNodeWithText("Syncing your workspace").assertIsDisplayed()
        composeRule.onNodeWithText(
            "Projects, boards, and conversations will appear together as soon as they arrive.",
        ).assertIsDisplayed()
    }

    @Test
    fun disconnectedTerminalHeaderClearsTheFloatingConnectionStatus() {
        composeRule.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.fillMaxSize()) {
                        TerminalHeader(
                            terminalCount = 0,
                            connected = false,
                            loading = false,
                            onRefresh = {},
                            onCreate = {},
                            modifier = Modifier.statusBarsPadding().padding(
                                top = terminalConnectionStatusInset(ConnectionPhase.AUTH_REQUIRED),
                            ),
                        )
                        ConnectionStatusIndicator(
                            phase = ConnectionPhase.AUTH_REQUIRED,
                            lastConnectedAtMillis = null,
                            showingCachedData = false,
                            modifier = Modifier.align(Alignment.TopEnd).statusBarsPadding()
                                .padding(top = 6.dp, end = 10.dp),
                        )
                    }
                }
            }
        }

        val statusBottom = composeRule.onNodeWithTag("workspace-connection-status")
            .fetchSemanticsNode().boundsInRoot.bottom
        val headerTop = composeRule.onNodeWithText("Terminals")
            .fetchSemanticsNode().boundsInRoot.top
        assertTrue("Connection status overlaps the terminal header", headerTop >= statusBottom)
    }
}
