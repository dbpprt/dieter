package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.e2e.saveEvidence
import com.dbpprt.dieter.ui.theme.DieterTheme
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
        composeRule.onRoot().saveEvidence("workspace-freshness-indicator.png")
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
    fun disconnectedTerminalHeaderFollowsTheConnectionStatusTopBar() {
        composeRule.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Column(Modifier.fillMaxSize()) {
                        ConnectionStatusTopBar(
                            phase = ConnectionPhase.AUTH_REQUIRED,
                            lastConnectedAtMillis = null,
                            showingCachedData = false,
                        )
                        TerminalHeader(
                            terminalCount = 0,
                            connected = false,
                            loading = false,
                            onRefresh = {},
                            onCreate = {},
                        )
                    }
                }
            }
        }

        val statusBottom = composeRule.onNodeWithTag("workspace-connection-status")
            .fetchSemanticsNode().boundsInRoot.bottom
        val headerTop = composeRule.onNodeWithTag("terminal-header")
            .fetchSemanticsNode().boundsInRoot.top
        assertTrue("Connection status overlaps the terminal header", headerTop >= statusBottom)
        composeRule.onRoot().saveEvidence("connection-status-terminal-layout.png")
    }
}
