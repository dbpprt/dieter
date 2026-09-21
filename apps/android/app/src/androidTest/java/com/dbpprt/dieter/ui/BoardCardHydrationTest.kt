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
import com.dbpprt.dieter.connection.OwnerCardDirectory
import com.dbpprt.dieter.connection.sharedItems
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Lane
import com.dbpprt.dieter.v1.TokenUsage
import com.dbpprt.dieter.v1.WorkspaceSummary
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.time.Instant

class BoardCardHydrationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun ownerOnlyActionsWorkspaceAndTokensSurviveSparseReplicaUpdate() {
        val board = Board.newBuilder().setId("board")
            .addLanes(Lane.newBuilder().setId("todo").setName("Todo"))
            .addLanes(Lane.newBuilder().setId("running").setName("Running"))
            .build()
        val sparse = Card.newBuilder().setId("card").setOwnerDaemonId("owner")
            .setScope("board").setProjectId("project").setBoardId("board").setLane("todo")
            .setTitle("Remote task").setProvider("codex").setModel("gpt-5.6-sol").build()
        val owner = sparse.toBuilder().setInitialPrompt("Implement it")
            .setWorkspaceMode("project")
            .setWorkspace(WorkspaceSummary.newBuilder().setMode("project").setBranch("main"))
            .setTokenUsage(TokenUsage.newBuilder().setReportedMessages(1).setTotalTokens(125).setPartial(true))
            .build()
        val directory = OwnerCardDirectory().apply { replace("owner", listOf(owner)) }
        var card by mutableStateOf(sharedItems(listOf(sparse), directory.snapshot()).single())

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
                        onStart = if (card.startLane(board) != null) ({}) else null,
                        onClick = {},
                    )
                }
            }
        }
        assertRichControls()

        compose.runOnIdle {
            val changedReplica = sparse.toBuilder().setTitle("Remote task renamed").build()
            card = sharedItems(listOf(card, changedReplica), directory.snapshot()).single()
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
