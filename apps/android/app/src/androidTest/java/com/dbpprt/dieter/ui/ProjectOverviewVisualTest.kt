package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.e2e.TestCore
import com.dbpprt.dieter.e2e.saveEvidence
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** Renders the Projects composition against isolated, screenshot-friendly data. */
class ProjectOverviewVisualTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private lateinit var core: TestCore
    private lateinit var model: DieterViewModel

    @Before fun setup() {
        assumeTrue("Use the isolated screen fixture app", (context.packageName.endsWith(".e2e")))
        core = TestCore(navigationAccount = "component-fixture")
        compose.runOnUiThread {
            model = core.viewModel()
            lifecycle.put("project-overview", model)
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        core.close()
        core.delete()
    }

    @Test fun projectHubMatchesTheReferenceHierarchy() {
        compose.setContent {
            val live by model.state.collectAsState()
            DieterTheme(darkTheme = true) {
                Surface(Modifier.fillMaxSize()) {
                    Scaffold(
                        bottomBar = { DieterBottomBar(Destination.BOARD, {}, {}) },
                    ) { padding ->
                        SpacesOverview(
                            visualState.copy(projectFolders = live.projectFolders),
                            model,
                            Modifier.fillMaxSize().padding(padding),
                        )
                    }
                }
            }
        }

        compose.onNodeWithTag("spaces-overview").assertIsDisplayed()
        compose.onNodeWithTag("nav-board").assertIsDisplayed()
        compose.onNodeWithText("PINNED").assertIsDisplayed()
        compose.onNodeWithText("Clients").assertIsDisplayed()
        compose.onNodeWithTag("space-project-kannacli").assertIsDisplayed()
        compose.onRoot().saveEvidence("projects-redesign.png")
    }

    private val projects = listOf(
        project("dieter", "dieter"),
        project("between", "between-relays"),
        project("kannacli", "kannacli"),
        project("nmt", "nmt-aiagency"),
        project("omelette", "omelette"),
        project("infra", "infra-console"),
        project("experiments", "experiments"),
        project("atlas", "atlas-legacy"),
    )
    private val boards = listOf(
        board("dieter-main", "dieter", "Main"),
        board("dieter-qa", "dieter", "Release QA"),
        board("between-main", "between", "Main"),
        board("kanna-main", "kannacli", "Product"),
        board("nmt-main", "nmt", "Main"),
        board("omelette-main", "omelette", "Main"),
        board("infra-main", "infra", "Operations"),
        board("experiments-main", "experiments", "Lab"),
        board("atlas-main", "atlas", "Main"),
    )
    private val cards = listOf(
        card("dieter-review", "dieter", "dieter-main", "review"),
        card("dieter-running", "dieter", "dieter-qa", "running", "running"),
        card("between-review", "between", "between-main", "review"),
        card("kanna-review", "kannacli", "kanna-main", "review"),
        card("infra-running", "infra", "infra-main", "running", "running"),
    )
    private val visualState = DieterUiState(
        connectionPhase = ConnectionPhase.CONNECTED,
        lastConnectedAtMillis = System.currentTimeMillis() - 120_000L,
        loading = false,
        projects = projects,
        pinnedProjectOrder = listOf("dieter", "between"),
        projectFolders = listOf(
            NavigationFolder("clients", "Clients", listOf("kannacli", "nmt", "omelette")),
            NavigationFolder("infra-folder", "Infra", listOf("infra"), expanded = false),
            NavigationFolder("experiments-folder", "Experiments", listOf("experiments"), expanded = false),
        ),
        spaceBoards = boards,
        spaceCards = cards,
        selectedProjectId = "dieter",
        projectReplicas = projects.associate { project ->
            project.id to when (project.id) {
                "atlas" -> "mbp-home"
                "experiments" -> "mini-lab"
                else -> "mini-home"
            }
        },
        endpointConnections = listOf(
            MachineRow("mbp-home", "mbp-home", "", daemonId = "mbp-home"),
            MachineRow("mini-home", "mini-home", "", daemonId = "mini-home"),
            MachineRow("mini-lab", "mini-lab", "", daemonId = "mini-lab", online = false),
        ),
    )

    private fun project(id: String, name: String) = Project(id = id, name = name, path = "/home/demo/Development/$name")

    private fun board(id: String, projectID: String, name: String) = Board(id = id, project_id = projectID, name = name)

    private fun card(id: String, projectID: String, boardID: String, lane: String, runtime: String = "idle") = Card(id = id, project_id = projectID, board_id = boardID, lane = lane, runtime = runtime)
}
