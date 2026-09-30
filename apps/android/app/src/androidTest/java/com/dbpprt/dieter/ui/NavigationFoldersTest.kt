package com.dbpprt.dieter.ui

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.e2e.TestCore
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import java.io.File
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/**
 * Runs real screens over an isolated shared core with local fixture data; the
 * navigation namespace is bound to a fixture account so edits queue offline.
 * Never contacts an operator gateway or daemon.
 */
class NavigationFoldersTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private lateinit var core: TestCore
    private lateinit var model: DieterViewModel
    private val projects = listOf(Project(id = "p1", name = "Dieter", path = "/work/dieter"))
    private val chats = listOf(
        Card(id = "c1", title = "Plan navigation", project_id = "p1", scope = "chat", pinned = true),
        Card(id = "c2", title = "Review Android layouts", project_id = "p1", scope = "chat"),
    )

    @Before fun setup() {
        assumeTrue("Use the isolated E2E app", context.packageName.endsWith(".e2e"))
        core = TestCore(navigationAccount = "navigation-fixture")
        compose.runOnUiThread {
            model = core.viewModel()
            lifecycle.put("folders", model)
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        core.close()
        core.delete()
    }

    /** Reads the shared navigation as a restarted app would, from the same state directory. */
    private fun <T> afterRestart(read: suspend (com.dbpprt.dieter.core.navigation.NavigationLayout) -> T?): T {
        val reopened = core.reopen()
        try {
            return runBlocking {
                withTimeout(5_000) {
                    var result: T? = null
                    reopened.core.navigationLayout().first { layout -> read(layout).also { result = it } != null }
                    result!!
                }
            }
        } finally {
            reopened.close()
        }
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
        val id = folderID(FolderScope.CHATS)
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
        compose.onNodeWithTag("folder-$id").assertTextContains("Reviews")
        compose.onAllNodesWithText("Reviews").assertCountEquals(2) // Header and pinned shortcut context.
        val restored = afterRestart { layout -> layout.folders(FolderScope.CHATS).singleOrNull()?.takeIf { it.name == "Reviews" } }
        assertEquals(id, restored.id)
        assertEquals("Reviews", restored.name)
        assertEquals(listOf("c1"), restored.itemIds)
        assertTrue(restored.expanded)
        compose.runOnIdle { assertTrue(model.state.value.projectFolders.isEmpty()) }
        compose.onNodeWithTag("folder-options-$id").performClick()
        compose.onNodeWithText("Delete folder").performClick()
        compose.onNodeWithTag("delete-folder-confirm").performClick()
        compose.onAllNodesWithTag("chat-c1").assertCountEquals(1)
        compose.onNodeWithTag("chat-c2").assertIsDisplayed()
        compose.onNodeWithText("Reviews").assertDoesNotExist()
    }

    @Test fun chatHierarchySearchRevealsCollapsedGroupsWithoutChangingPreferences() {
        val otherProject = Project(id = "p2", name = "NewsOS")
        fun chat(id: String, title: String, project: String = "p1", pinned: Boolean = false, running: Boolean = false) =
            Card(id = id, title = title, project_id = project, scope = "chat", owner_daemon_id = "mini-office", pinned = pinned, runtime = if (running) "running" else "idle", last_activity_at = "2026-09-23T10:00:00Z")
        val fixtureChats = listOf(
            chat("pin", "Release checklist", pinned = true),
            chat("filed", "New Readerscore", "p2", running = true),
            chat("filed-idle", "Erdbeerland", "p2"),
            chat("project", "Refine Android navigation", running = true),
            chat("project-2", "Review connection recovery"),
            chat("project-3", "Write release notes"),
            chat("project-4", "Check keyboard shortcuts"),
        )
        compose.runOnIdle { model.createFolder(FolderScope.CHATS, "Newsroom") }
        val news = folderID(FolderScope.CHATS)
        compose.runOnIdle {
            model.moveToFolder(FolderScope.CHATS, "filed", news)
            model.moveToFolder(FolderScope.CHATS, "filed-idle", news)
        }
        compose.waitUntil(5_000) { model.state.value.chatFolders.single().itemIds == listOf("filed", "filed-idle") }
        var dark by mutableStateOf(true)
        var fontScale by mutableStateOf(1f)
        compose.setContent {
            val state by model.state.collectAsState()
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                DieterTheme(darkTheme = dark) {
                    Scaffold(bottomBar = { DieterBottomBar(Destination.CHATS, {}, {}) }) { padding ->
                        ChatsScreen(state.copy(projects = projects + otherProject, chats = fixtureChats,
                            navigationPendingCount = 0, navigationSyncError = null), model, false, padding)
                    }
                }
            }
        }
        compose.onNodeWithText("Pinned").assertIsDisplayed()
        compose.onNodeWithText("Folders").assertIsDisplayed()
        compose.onNodeWithTag("folder-$news").assertIsDisplayed()
        compose.onNodeWithTag("chat-runtime-filed", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Not running").assertDoesNotExist()
        capture("all-chats-dark.png")
        compose.runOnIdle { dark = false }
        capture("all-chats-light.png")
        compose.runOnIdle { dark = true; fontScale = 1.5f }
        capture("all-chats-large-text.png")
        compose.onNodeWithTag("chat-actions-pin").performClick()
        compose.onNodeWithText("Unpin").assertIsDisplayed()
        compose.onNodeWithText("Move to folder").assertIsDisplayed()
        androidx.test.espresso.Espresso.pressBack()
        compose.runOnIdle { fontScale = 1f }
        compose.onNodeWithTag("folder-$news").performClick()
        compose.onNodeWithTag("chats-list").performScrollToNode(hasTestTag("project-chat-toggle-p1"))
        compose.onNodeWithTag("project-chat-toggle-p1").performClick()
        compose.waitUntil { "p1" in model.state.value.collapsedChatProjectIds }
        capture("all-chats-collapsed.png")
        compose.onNode(hasSetTextAction()).performTextInput("Newsroom")
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        compose.onNodeWithTag("chat-filed").assertIsDisplayed()
        compose.onNodeWithTag("chat-filed-idle").assertIsDisplayed()
        capture("all-chats-folder-search.png")
        compose.onNode(hasSetTextAction()).performTextReplacement("Dieter")
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        compose.onNodeWithTag("chat-project").assertIsDisplayed()
        compose.onNodeWithTag("chats-list").performScrollToNode(hasTestTag("chat-project-4"))
        compose.onNodeWithTag("chat-project-4").assertIsDisplayed()
        compose.onNodeWithContentDescription("Clear search").performClick()
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        compose.onNodeWithTag("chat-project").assertDoesNotExist()
        compose.onNodeWithTag("chat-filed").assertDoesNotExist()
        compose.runOnIdle {
            assertTrue("p1" in model.state.value.collapsedChatProjectIds)
            assertFalse(model.state.value.chatFolders.single().expanded)
        }
        compose.onNode(hasSetTextAction()).performTextInput("nothing-matches-this")
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        compose.onNodeWithText("No matching chats").assertIsDisplayed()
        capture("all-chats-no-results.png")
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
        compose.onNodeWithTag("project-actions-p1").performClick()
        compose.onNodeWithTag("project-folder-p1").performClick()
        compose.onNodeWithText("New folder").performClick()
        compose.onNodeWithTag("folder-name").performTextInput("Work")
        compose.onNodeWithTag("save-folder").performClick()
        val id = folderID(FolderScope.PROJECTS)
        compose.onNodeWithTag("space-project-p1").assertIsDisplayed()
        capture("project-folders.png")
        compose.onNodeWithTag("folder-$id").performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithTag("space-project-p1").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("space-project-p1").assertDoesNotExist()
        compose.onNodeWithTag("folder-$id").performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithTag("project-actions-p1").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("project-actions-p1").performClick()
        compose.onNodeWithTag("project-folder-p1").performClick()
        compose.onNodeWithTag("move-no-folder").performClick()
        compose.onNodeWithText("No projects in this folder").assertIsDisplayed()
        compose.onNodeWithTag("space-project-p1").assertIsDisplayed()
        compose.onNodeWithTag("folder-options-$id").performClick()
        compose.onNodeWithText("Delete folder").performClick()
        compose.onNodeWithTag("delete-folder-confirm").performClick()
        compose.onNodeWithTag("space-project-p1").assertIsDisplayed()
        compose.runOnIdle { assertTrue(model.state.value.chatFolders.isEmpty()) }
    }

    @Test fun projectSyncStatusExplainsFailuresAndClearsAfterRecovery() {
        var state by mutableStateOf(DieterUiState(projects = projects,
            peerSyncWarnings = listOf("Shared updates between Desktop and Laptop are delayed."),
            navigationPendingCount = 1,
            navigationSyncError = "Sign in again to sync folders and order."))
        compose.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    SpacesOverview(state, model, Modifier.fillMaxSize())
                }
            }
        }
        compose.onNodeWithText("Shared updates between Desktop and Laptop are delayed.").assertIsDisplayed()
        compose.onNodeWithText("1 navigation edits pending sync. Sign in again to sync folders and order.").assertIsDisplayed()
        compose.onNodeWithText("Navigation sync unavailable").assertDoesNotExist()
        capture("project-sync-needs-attention.png")
        compose.runOnIdle { state = state.copy(peerSyncWarnings = emptyList(), navigationPendingCount = 0, navigationSyncError = null) }
        compose.onNodeWithText("Shared updates between Desktop and Laptop are delayed.").assertDoesNotExist()
        compose.onNodeWithText("Sign in again", substring = true).assertDoesNotExist()
        compose.onNodeWithTag("space-project-p1").assertIsDisplayed()
        capture("project-sync-recovered.png")
    }

    @Test fun projectPinsPersistInSharedNavigationAndCanBeRemovedFromThePinnedCard() {
        compose.setContent {
            val state by model.state.collectAsState()
            DieterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    SpacesOverview(state.copy(projects = projects), model, Modifier.fillMaxSize())
                }
            }
        }

        compose.onNodeWithTag("project-actions-p1").performClick()
        compose.onNodeWithTag("project-pin-p1").performClick()
        compose.onNodeWithText("PINNED").assertIsDisplayed()
        compose.onNodeWithTag("project-pinned-p1").assertIsDisplayed()
        assertEquals(listOf("p1"), afterRestart { layout -> layout.pinnedProjects(listOf("p1")).takeIf { it.isNotEmpty() } })

        compose.onNodeWithTag("project-unpin-p1").performClick()
        compose.onNodeWithTag("project-pinned-p1").assertDoesNotExist()
        compose.waitUntil(5_000) { model.state.value.pinnedProjectOrder.isEmpty() }
        assertTrue(afterRestart { layout -> layout.pinnedProjects(listOf("p1")).takeIf { it.isEmpty() } }.isEmpty())
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

    @Test fun folderPickerScrollsWithLargeTextAndManyFolders() {
        compose.runOnIdle { repeat(18) { model.createFolder(FolderScope.PROJECTS, "Project group ${it + 1}") } }
        compose.waitUntil(5_000) { model.state.value.projectFolders.size == 18 }
        val last = model.state.value.projectFolders.last().id
        var dismissed = false
        compose.setContent {
            val state by model.state.collectAsState()
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                DieterTheme {
                    MoveToNavigationFolderDialog("p1", FolderScope.PROJECTS, state.projectFolders, model, onDismiss = { dismissed = true })
                }
            }
        }
        compose.onNodeWithTag("move-folder-$last").performScrollTo().assertIsDisplayed().performClick()
        compose.waitUntil(5_000) { model.state.value.projectFolders.folderContaining("p1")?.id == last }
        compose.runOnIdle {
            assertTrue(dismissed)
            assertEquals(last, model.state.value.projectFolders.folderContaining("p1")?.id)
        }
    }

    private fun folderID(scope: FolderScope): String {
        compose.waitUntil { folders(scope).isNotEmpty() }
        return folders(scope).single().id
    }

    private fun folders(scope: FolderScope) = if (scope == FolderScope.CHATS) model.state.value.chatFolders else model.state.value.projectFolders

    private fun capture(name: String) {
        val file = File(context.getExternalFilesDir(null), name)
        file.outputStream().use { output ->
            assertTrue(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output))
        }
    }
}
