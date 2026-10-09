package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.e2e.Evidence
import com.dbpprt.dieter.e2e.saveEvidence
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.*
import com.dbpprt.dieter.api.v1.Card
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.time.Instant

class BoardMachineDesignTest {
    @get:Rule val compose = createComposeRule()
    private val board = Board(id = "board", name = "Main", lanes = listOf(Lane(id = "todo", name = "Todo"), Lane(id = "running", name = "Running")), labels = listOf(Label(id = "label", name = "Android", color = "#5DBFA0")))
    private val state = DieterUiState(
        connectionPhase = ConnectionPhase.CONNECTED,
        selectedProjectId = "project", selectedBoardId = "board", boards = listOf(board),
        projects = listOf(Project(id = "project", name = "Dieter", checkouts = listOf(Checkout(id = "mac", project_id = "project", daemon_id = "mac", name = "Main checkout"), Checkout(id = "linux", project_id = "project", daemon_id = "linux", name = "Development"), Checkout(id = "offline", project_id = "project", daemon_id = "offline", name = "Archive")))),
        endpointConnections = listOf(
            MachineRow("mac", "MacBook Pro", "", daemonId = "mac"),
            MachineRow("linux", "garuda", "", daemonId = "linux"),
            MachineRow("offline", "Studio", "", daemonId = "offline", online = false),
        ),
        harnessesEndpointId = "mac",
        harnesses = listOf(Harness(id = "codex", name = "Codex", default_model = "sol", models = listOf(HarnessModel(id = "sol", name = "Sol")))),
    )

    @Test fun quickTaskRequiresDestinationAndMatchingModels() {
        var current by mutableStateOf(state)
        var draft by mutableStateOf(
            TaskDrafts.initialize(
                TaskDrafts.prompt(CaptureDraft(id = "quick", project_id = "project", board_id = "board"), "Make the board easier to scan"),
                HarnessSelection("codex", "sol", ""), WorkspaceMode.PROJECT, "todo", state.harnesses,
            ),
        )
        var created = ""
        compose.setContent {
            DieterTheme {
                QuickTaskPopover(current, draft, { draft = TaskDrafts.prompt(draft, it) }, {}, {}, { created = draft.task.prompt },
                    onSelectCheckout = { current = current.copy(creationCheckoutId = it) })
            }
        }
        compose.onNodeWithTag("quick-task-create").assertIsNotEnabled()
        compose.onNodeWithTag("creation-destination").performClick()
        compose.onNodeWithTag("creation-checkout-offline").assertIsNotEnabled()
        compose.onNodeWithTag("creation-checkout-linux").performClick()
        compose.onNodeWithTag("quick-task-create").assertIsNotEnabled()
        compose.runOnIdle { current = current.copy(harnessesEndpointId = "linux") }
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

    @Test fun projectListAndRunOnUseCheckoutMachinesAcrossReplicaChanges() {
        val project = Project(id = "project", name = "nmt-aigency", checkouts = listOf(Checkout(id = "office", project_id = "project", daemon_id = "office", name = "nmt-aigency"), Checkout(id = "laptop", project_id = "project", daemon_id = "laptop", name = "nmt-aigency")))
        var current by mutableStateOf(state.copy(
            projects = listOf(project), creationCheckoutId = "office", harnessesEndpointId = "office",
            projectHosts = mapOf(project.id to "home"),
            endpointConnections = listOf(
                MachineRow("home", "mini-home", "", daemonId = "home"),
                MachineRow("office", "mini-office", "", daemonId = "office"),
                MachineRow("laptop", "mbp-office", "", daemonId = "laptop", online = false),
            ),
        ))
        var dark by mutableStateOf(true)
        compose.setContent {
            DieterTheme(darkTheme = dark) {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.safeDrawingPadding().widthIn(max = 420.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text("Projects", style = MaterialTheme.typography.headlineMedium)
                        CompactProjectRow(project, false, {}, current.projectCheckoutLabel(project), listOf(board), emptyList(),
                            false, false, false, false, {}, {}, {}, {})
                        Text("New card", style = MaterialTheme.typography.headlineMedium)
                        CreationDestinationPicker(current, {})
                    }
                }
            }
        }
        compose.onNodeWithText("1 board · mini-office · mbp-office (offline)").assertIsDisplayed()
        compose.onNodeWithText("mini-office").assertIsDisplayed()
        compose.onNodeWithText("mini-home", substring = true).assertDoesNotExist()
        capture("project-checkouts-dark.png")
        compose.runOnIdle {
            current = current.copy(projectHosts = mapOf(project.id to "office"))
            dark = false
        }
        compose.onNodeWithText("1 board · mini-office · mbp-office (offline)").assertIsDisplayed()
        compose.onNodeWithText("mini-office").assertIsDisplayed()
        capture("project-checkouts-light.png")
    }

    @Test fun compactCardsAndDestinationInDarkAndLightThemes() {
        var dark by mutableStateOf(true)
        val cards = listOf(
            Card(id = "one", board_id = "board", owner_daemon_id = "linux", title = "Make the board easier to scan", summary = "Compact cards, clear destinations, less noise", provider = "codex", model = "gpt-5.6-sol", lane = "running", workspace_mode = "project", workspace_branch = "main", label_ids = listOf("label"), updated_at = "2026-09-21T08:00:00Z", token_usage = TokenUsage(reported_messages = 2, total_tokens = 18400)),
            Card(id = "two", board_id = "board", scope = "board", owner_daemon_id = "mac", title = "Polish machine selection", initial_prompt = "Let people pick where a card runs.", provider = "codex", model = "gpt-5.6-sol", lane = "todo", workspace_mode = "worktree", workspace_branch = "feat/machine-picker"),
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
                                machineName = state.machineLabel(card.owner_daemon_id), onStart = if (card.id == "two") ({}) else null, onClick = {})
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

    private fun capture(name: String) = compose.onRoot().saveEvidence(name, File(Evidence.directory, "board-design"))
}
