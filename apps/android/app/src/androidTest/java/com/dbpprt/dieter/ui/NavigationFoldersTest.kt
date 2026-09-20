package com.dbpprt.dieter.ui

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.NavigationFolderScope
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Project
import java.io.File
import java.lang.reflect.Proxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** Runs real screens with local fixture data, never contacting an operator daemon. */
class NavigationFoldersTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private val managerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var model: DieterViewModel
    private val projects = listOf(Project.newBuilder().setId("p1").setName("Dieter").setPath("/work/dieter").build())
    private val chats = listOf(
        Card.newBuilder().setId("c1").setTitle("Plan navigation").setProjectId("p1").setScope("chat").setPinned(true).build(),
        Card.newBuilder().setId("c2").setTitle("Review Android layouts").setProjectId("p1").setScope("chat").build(),
    )

    @Before fun setup() {
        assumeTrue("Use -Pdieter.screenTestBuildType=screenFixture to preserve the signed-in app", context.packageName.endsWith(".screenfixture"))
        context.getSharedPreferences("dieter_shared_kv", Context.MODE_PRIVATE).edit().clear().putString("activeAccount", "navigation-fixture").commit()
        var endpoints = DIETER_ENDPOINTS
        val repository = Proxy.newProxyInstance(DieterRepository::class.java.classLoader, arrayOf(DieterRepository::class.java)) { _, method, args ->
            when (method.name) {
                "getEndpoints" -> endpoints
                "getActiveEndpoint" -> endpoints.first()
                "replaceEndpoints" -> { @Suppress("UNCHECKED_CAST") val replacement = args!![0] as List<DieterEndpoint>; endpoints = replacement; Unit }
                "close", "reconnect" -> Unit
                else -> error("Unexpected repository call in layout-only test: ${method.name}")
            }
        } as DieterRepository
        compose.runOnUiThread {
            model = DieterViewModel(DieterConnectionManager(context, repository, managerScope), AppPreferences(context))
            lifecycle.put("folders", model)
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        managerScope.cancel()
    }

    @Test fun chatFoldersKeepPinsSupportSearchAndSurviveRecreation() {
        compose.setContent {
            val state by model.state.collectAsState()
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    ChatsScreen(state.copy(projects = projects, chats = chats), model, false, PaddingValues())
                }
            }
        }
        compose.onNodeWithTag("new-chats-folder").performClick()
        compose.onNodeWithTag("folder-name").performTextInput("Work")
        compose.onNodeWithTag("save-folder").performClick()
        val id = folderID(NavigationFolderScope.CHATS)
        compose.onNodeWithTag("chat-c1").performTouchInput { longClick() }
        compose.onNodeWithTag("chat-folder-c1").performClick()
        compose.onNodeWithTag("move-folder-$id").performClick()
        compose.onAllNodesWithTag("chat-c1").assertCountEquals(2)
        compose.onNodeWithTag("folder-$id").performClick()
        compose.onAllNodesWithTag("chat-c1").assertCountEquals(1)
        compose.onNode(hasSetTextAction()).performTextInput("Plan navigation")
        compose.onAllNodesWithTag("chat-c1").assertCountEquals(2)
        compose.onNode(hasSetTextAction()).performTextClearance()
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        compose.onAllNodesWithTag("chat-c1").assertCountEquals(1)
        compose.onNodeWithTag("folder-$id").performClick()
        capture("chat-folders.png")
        compose.onNodeWithTag("folder-options-$id").performClick()
        compose.onNodeWithText("Rename folder").performClick()
        compose.onNodeWithTag("folder-name").performTextReplacement("Reviews")
        compose.onNodeWithTag("save-folder").performClick()
        compose.onNodeWithText("Reviews").assertIsDisplayed()
        compose.runOnIdle {
            val restored = AppPreferences(context).navigationFolders
                .layouts.value.getValue(NavigationFolderScope.CHATS).folders.single()
            assertEquals(id, restored.id)
            assertEquals("Reviews", restored.name)
            assertEquals(listOf("c1"), restored.itemIDs)
            assertTrue(restored.isExpanded)
            assertTrue(model.state.value.projectFolders.folders.isEmpty())
        }
        compose.onNodeWithTag("folder-options-$id").performClick()
        compose.onNodeWithText("Delete folder").performClick()
        compose.onNodeWithTag("delete-folder-confirm").performClick()
        compose.onAllNodesWithTag("chat-c1").assertCountEquals(1)
        compose.onNodeWithTag("chat-c2").assertIsDisplayed()
        compose.onNodeWithText("Reviews").assertDoesNotExist()
    }

    @Test fun projectFoldersMoveOutAndDeleteWithoutRemovingProjects() {
        compose.setContent {
            val state by model.state.collectAsState()
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    SpacesOverview(state.copy(projects = projects), model, Modifier.fillMaxSize())
                }
            }
        }
        compose.onNodeWithTag("project-folder-p1").performClick()
        compose.onNodeWithText("New folder").performClick()
        compose.onNodeWithTag("folder-name").performTextInput("Work")
        compose.onNodeWithTag("save-folder").performClick()
        val id = folderID(NavigationFolderScope.PROJECTS)
        compose.onNodeWithTag("space-project-p1").assertIsDisplayed()
        capture("project-folders.png")
        compose.onNodeWithTag("folder-$id").performClick()
        compose.onNodeWithTag("space-project-p1").assertDoesNotExist()
        compose.onNodeWithTag("folder-$id").performClick()
        compose.onNodeWithTag("project-folder-p1").performClick()
        compose.onNodeWithTag("move-no-folder").performClick()
        compose.onNodeWithText("No projects in this folder").assertIsDisplayed()
        compose.onNodeWithTag("space-project-p1").assertIsDisplayed()
        compose.onNodeWithTag("folder-options-$id").performClick()
        compose.onNodeWithText("Delete folder").performClick()
        compose.onNodeWithTag("delete-folder-confirm").performClick()
        compose.onNodeWithTag("space-project-p1").assertIsDisplayed()
        compose.runOnIdle { assertTrue(model.state.value.chatFolders.folders.isEmpty()) }
    }

    @Test fun boardlessProjectsExposeBoardCreationInsteadOfAnEmptyBoard() {
        compose.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    BoardList(
                        DieterUiState(
                            loading = false,
                            projects = projects,
                            selectedProjectId = projects.single().id,
                            boards = emptyList(),
                        ),
                        model,
                        Modifier.fillMaxSize(),
                    )
                }
            }
        }

        compose.onNodeWithTag("board-empty").assertIsDisplayed()
        compose.onNodeWithText("No boards yet").assertIsDisplayed()
        compose.onNodeWithTag("board-empty-create").assertIsDisplayed()
        compose.onNodeWithTag("new-card").assertDoesNotExist()
    }

    @Test fun sharedRecordsPreserveBothScopesAndCollapsedMembership() {
        val records = mapOf(
            "projects-folder.mac-id.name" to "\"Research\"",
            "projects-folder.mac-id.expanded" to "false",
            "projects-item.offline-project.position" to """{"parent":"mac-id","rank":"a"}""",
            "projects-item.p1.position" to """{"parent":"mac-id","rank":"b"}""",
        )
        val decoded = com.dbpprt.dieter.settings.SharedNavigation.folders(records, "projects")
        assertEquals(listOf("offline-project", "p1"), decoded.folders.single().itemIDs)
        assertFalse(decoded.folders.single().isExpanded)
        val store = model.navigationFolders
        store.update(NavigationFolderScope.PROJECTS) { decoded }
        store.create(NavigationFolderScope.CHATS, "Research", "c1")
        val restored = AppPreferences(context).navigationFolders
        assertEquals(decoded, restored.layouts.value.getValue(NavigationFolderScope.PROJECTS))
        assertEquals(listOf("c1"), restored.layouts.value.getValue(NavigationFolderScope.CHATS).folders.single().itemIDs)
    }

    @Test fun folderPickerScrollsWithLargeTextAndManyFolders() {
        val store = model.navigationFolders
        repeat(18) { store.create(NavigationFolderScope.PROJECTS, "Project group ${it + 1}") }
        val last = store.layouts.value.getValue(NavigationFolderScope.PROJECTS).folders.last().id
        var dismissed = false
        compose.setContent {
            val layouts by store.layouts.collectAsState()
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                DieterTheme {
                    MoveToNavigationFolderDialog("p1", NavigationFolderScope.PROJECTS,
                        layouts.getValue(NavigationFolderScope.PROJECTS), store, onDismiss = { dismissed = true })
                }
            }
        }
        compose.onNodeWithTag("move-folder-$last").performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertTrue(dismissed)
            assertEquals(last, store.layouts.value.getValue(NavigationFolderScope.PROJECTS).folderContaining("p1")?.id)
        }
    }

    private fun folderID(scope: NavigationFolderScope): String {
        compose.waitUntil { model.navigationFolders.layouts.value.getValue(scope).folders.isNotEmpty() }
        return model.navigationFolders.layouts.value.getValue(scope).folders.single().id
    }

    private fun capture(name: String) {
        val file = File(context.getExternalFilesDir(null), name)
        file.outputStream().use { output ->
            assertTrue(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output))
        }
    }
}
