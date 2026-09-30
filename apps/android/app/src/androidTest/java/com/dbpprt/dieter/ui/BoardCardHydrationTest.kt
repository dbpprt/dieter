package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.board.CardPolicy
import com.dbpprt.dieter.core.sync.DirectoryReducer
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.TokenUsage
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.time.Instant

class BoardCardHydrationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun ownerOnlyActionsWorkspaceAndTokensSurviveSparseReplicaUpdate() {
        val board = Board(id = "board", lanes = listOf(Lane(id = "todo", name = "Todo"), Lane(id = "running", name = "Running")))
        val sparse = Card(id = "card", owner_daemon_id = "owner", scope = "board", project_id = "project", board_id = "board", lane = "todo", title = "Remote task", provider = "codex", model = "gpt-5.6-sol")
        val owner = sparse.copy(initial_prompt = "Implement it", workspace_mode = "project", workspace = WorkspaceSummary(mode = "project", branch = "main"), token_usage = TokenUsage(reported_messages = 1, total_tokens = 125, partial = true))
        // The core's directory keeps the owner's details when a peer serves the sparse item.
        var card by mutableStateOf(DirectoryReducer.retainingOwnerDetails(sparse, owner, sourceDaemonId = "peer"))

        compose.setContent {
            DieterTheme {
                Surface {
                    WorkCard(
                        card = card,
                        board = board,
                        selected = false,
                        pending = false,
                        operation = null,
                        operationError = null,
                        activityNow = Instant.parse("2026-09-21T09:00:00Z"),
                        machineName = "mini-home",
                        onStart = if (CardPolicy.startLane(card, board) != null) ({}) else null,
                        onClick = {},
                    )
                }
            }
        }
        assertRichControls()

        compose.runOnIdle {
            val changedReplica = sparse.copy(title = "Remote task renamed")
            card = DirectoryReducer.retainingOwnerDetails(changedReplica, card, sourceDaemonId = "peer")
        }

        compose.onNodeWithText("Remote task renamed").assertIsDisplayed()
        assertRichControls()
        val outputDirectory = InstrumentationRegistry.getInstrumentation().targetContext
            .getExternalFilesDir("card-hydration")!!
        outputDirectory.mkdirs()
        File(outputDirectory, "after-sparse-update.png").outputStream().use { output ->
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output)
        }
    }

    private fun assertRichControls() {
        compose.onNodeWithTag("start-card-card", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithTag("workspace-badge-card", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("125 tokens · partial", useUnmergedTree = true).assertIsDisplayed()
    }
}
