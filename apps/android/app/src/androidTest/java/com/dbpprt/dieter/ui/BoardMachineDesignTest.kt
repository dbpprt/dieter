package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.*
import com.dbpprt.dieter.v1.Card
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.time.Instant

class BoardMachineDesignTest {
    @get:Rule val compose = createComposeRule()
    private val board = Board.newBuilder().setId("board").setName("Main")
        .addLanes(Lane.newBuilder().setId("todo").setName("Todo"))
        .addLabels(Label.newBuilder().setId("label").setName("Android").setColor("#5DBFA0"))
        .build()
    private val state = DieterUiState(
        connectionPhase = ConnectionPhase.CONNECTED,
        selectedProjectId = "project", selectedBoardId = "board", boards = listOf(board),
        projects = listOf(Project.newBuilder().setId("project").setName("Dieter")
            .addCheckouts(Checkout.newBuilder().setId("mac").setProjectId("project").setDaemonId("mac").setName("Main checkout"))
            .addCheckouts(Checkout.newBuilder().setId("linux").setProjectId("project").setDaemonId("linux").setName("Development"))
            .addCheckouts(Checkout.newBuilder().setId("offline").setProjectId("project").setDaemonId("offline").setName("Archive"))
            .build()),
        endpointConnections = listOf(
            EndpointConnection("endpoint-mac", "MacBook Pro", "", daemonId = "mac"),
            EndpointConnection("endpoint-linux", "garuda", "", daemonId = "linux"),
            EndpointConnection("endpoint-offline", "Studio", "", daemonId = "offline", online = false),
        ),
        harnessesEndpointId = "endpoint-mac",
        harnesses = listOf(Harness.newBuilder().setId("codex").setName("Codex").setDefaultModel("sol")
            .addModels(HarnessModel.newBuilder().setId("sol").setName("Sol")).build()),
    )

    @Test fun quickTaskRequiresDestinationAndMatchingModels() {
        var current by mutableStateOf(state)
        var created = ""
        compose.setContent {
            DieterTheme {
                QuickTaskPopover(current,
                    ResolvedConversationCreationPreferences("codex", "sol", "", ConversationWorkspaceMode.PROJECT),
                    "Make the board easier to scan", {}, {}, {}, { created = it },
                    onSelectCheckout = { current = current.copy(creationCheckoutId = it) })
            }
        }
        compose.onNodeWithTag("quick-task-create").assertIsNotEnabled()
        compose.onNodeWithTag("creation-destination").performClick()
        compose.onNodeWithTag("creation-checkout-offline").assertIsNotEnabled()
        compose.onNodeWithTag("creation-checkout-linux").performClick()
        compose.onNodeWithTag("quick-task-create").assertIsNotEnabled()
        compose.runOnIdle { current = current.copy(harnessesEndpointId = "endpoint-linux") }
        compose.onNodeWithTag("quick-task-create").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals("Make the board easier to scan", created) }
    }

    @Test fun machineFilterDistinguishesUnassignedFromAllMachines() {
        var selected by mutableStateOf<String?>(null)
        compose.setContent { DieterTheme { BoardMachineFilter(state, listOf("", "mac", "linux"), selected) { selected = it } } }
        compose.onNodeWithTag("board-machine-filter").performClick()
        compose.onNodeWithTag("board-machine-").performClick()
        compose.runOnIdle { assertEquals("", selected) }
        compose.onNodeWithText("Unassigned").assertIsDisplayed()
        compose.onNodeWithTag("board-machine-filter").performClick()
        compose.onNodeWithTag("board-machine-all").performClick()
        compose.runOnIdle { assertEquals(null, selected) }
    }

    @Test fun compactCardsAndDestinationInDarkAndLightThemes() {
        var dark by mutableStateOf(true)
        val cards = listOf(
            Card.newBuilder().setId("one").setBoardId("board").setOwnerDaemonId("linux")
                .setTitle("Make the board easier to scan").setSummary("Compact cards, clear destinations, less noise")
                .setProvider("codex").setModel("gpt-5.6-sol").setLane("running")
                .setWorkspaceMode("project").setWorkspaceBranch("main").addLabelIds("label")
                .setUpdatedAt("2026-09-21T08:00:00Z")
                .setTokenUsage(TokenUsage.newBuilder().setReportedMessages(2).setTotalTokens(18400)).build(),
            Card.newBuilder().setId("two").setBoardId("board").setOwnerDaemonId("mac")
                .setTitle("Polish machine selection").setProvider("codex").setModel("gpt-5.6-sol")
                .setLane("todo").setWorkspaceMode("worktree").setWorkspaceBranch("feat/machine-picker").build(),
        )
        compose.setContent {
            DieterTheme(darkTheme = dark) {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.safeDrawingPadding().widthIn(max = 420.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("Main", style = MaterialTheme.typography.headlineMedium)
                        Text("Dieter · 2 cards", style = MaterialTheme.typography.bodySmall)
                        BoardLabelFilters(state.copy(cards = cards), "", dragState = remember { BoardLabelDragState() }, onSelect = {}, onDrop = { _, _ -> })
                        cards.forEach { card ->
                            WorkCard(card, board, selected = card.id == "one", pending = false,
                                operation = null, operationError = null, activityNow = Instant.parse("2026-09-21T08:02:00Z"),
                                machineName = state.machineLabel(card.ownerDaemonId), onStart = if (card.id == "two") ({}) else null, onClick = {})
                        }
                        Spacer(Modifier.height(12.dp))
                        Text("New card", style = MaterialTheme.typography.titleLarge)
                        CreationDestinationPicker(state.copy(creationCheckoutId = "mac"), {})
                    }
                }
            }
        }
        compose.onNodeWithTag("machine-badge-one", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithContentDescription("Machine garuda", useUnmergedTree = true).assertExists()
        capture("board-dark.png")
        compose.runOnIdle { dark = false }
        capture("board-light.png")
    }

    private fun capture(name: String) {
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("board-design")!!
        directory.mkdirs()
        File(directory, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
