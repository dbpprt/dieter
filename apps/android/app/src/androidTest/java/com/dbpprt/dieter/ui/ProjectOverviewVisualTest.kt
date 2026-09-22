package com.dbpprt.dieter.ui

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.NavigationFolder
import com.dbpprt.dieter.settings.NavigationFolderPreferences
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import java.io.File
import java.lang.reflect.Proxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** Renders the Projects composition against isolated, screenshot-friendly data. */
class ProjectOverviewVisualTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private val managerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var model: DieterViewModel

    @Before fun setup() {
        assumeTrue("Use the isolated screen fixture app", context.packageName.endsWith(".screenfixture"))
        context.getSharedPreferences("dieter_shared_kv", Context.MODE_PRIVATE).edit().clear()
            .putString("activeAccount", "project-overview-fixture").commit()
        var endpoints = DIETER_ENDPOINTS
        val repository = Proxy.newProxyInstance(
            DieterRepository::class.java.classLoader,
            arrayOf(DieterRepository::class.java),
        ) { _, method, args ->
            when (method.name) {
                "getEndpoints" -> endpoints
                "getActiveEndpoint" -> endpoints.first()
                "replaceEndpoints" -> {
                    @Suppress("UNCHECKED_CAST")
                    val replacement = args!![0] as List<DieterEndpoint>
                    endpoints = replacement
                    Unit
                }
                "close", "reconnect" -> Unit
                else -> error("Unexpected repository call in layout-only test: ${method.name}")
            }
        } as DieterRepository
        compose.runOnUiThread {
            model = DieterViewModel(DieterConnectionManager(context, repository, managerScope), AppPreferences(context))
            lifecycle.put("project-overview", model)
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        managerScope.cancel()
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

        visualState.projectFolders.folders.forEach { folder ->
            model.navigationFolders.update(com.dbpprt.dieter.settings.NavigationFolderScope.PROJECTS) { current ->
                if (current.folders.any { it.id == folder.id }) current
                else NavigationFolderPreferences.from(current.folders + folder)
            }
        }
        compose.onNodeWithTag("spaces-overview").assertIsDisplayed()
        compose.onNodeWithTag("nav-board").assertIsDisplayed()
        compose.onNodeWithText("PINNED").assertIsDisplayed()
        compose.onNodeWithText("Clients").assertIsDisplayed()
        compose.onNodeWithTag("space-project-kannacli").assertIsDisplayed()

        val file = File(context.getExternalFilesDir(null), "projects-redesign.png")
        file.outputStream().use { output ->
            assertTrue(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output))
        }
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
        projectFolders = NavigationFolderPreferences.from(
            listOf(
                NavigationFolder("clients", "Clients", listOf("kannacli", "nmt", "omelette")),
                NavigationFolder("infra-folder", "Infra", listOf("infra"), isExpanded = false),
                NavigationFolder("experiments-folder", "Experiments", listOf("experiments"), isExpanded = false),
            ),
        ),
        spaceBoards = boards,
        spaceCards = cards,
        selectedProjectId = "dieter",
        projectReplicas = projects.associate { project ->
            project.id to ProjectReplica("fixture", "fixture", if (project.id == "atlas") "mbp-home" else "mini-home", project.id != "experiments")
        },
    )

    private fun project(id: String, name: String) = Project.newBuilder()
        .setId(id)
        .setName(name)
        .setPath("/home/demo/Development/$name")
        .build()

    private fun board(id: String, projectID: String, name: String) = Board.newBuilder()
        .setId(id)
        .setProjectId(projectID)
        .setName(name)
        .build()

    private fun card(id: String, projectID: String, boardID: String, lane: String, runtime: String = "idle") = Card.newBuilder()
        .setId(id)
        .setProjectId(projectID)
        .setBoardId(boardID)
        .setLane(lane)
        .setRuntime(runtime)
        .build()
}
