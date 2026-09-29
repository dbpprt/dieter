package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File

class ConversationDestinationPickerTest {
    @get:Rule val compose = createComposeRule()
    private val projects = listOf("dieter", "nmt-aigency", "box", "afa", "gx10s", "vps").map {
        Project.newBuilder().setId(it).setName(it).setPath("~/Development/$it").setBaseRemote("origin").setBaseBranch("main").build()
    }
    private val boards = listOf(
        Board.newBuilder().setId("main").setProjectId("dieter").setName("Main").setDescription("Everyday development and improvements").setWorkflow("review").setCreatedAt("2026-09-20T12:00:00Z").build(),
        Board.newBuilder().setId("release").setProjectId("dieter").setName("Main").setDescription("Release fixes and delivery").setWorkflow("direct").setCreatedAt("2026-09-22T12:00:00Z").build(),
        Board.newBuilder().setId("design").setProjectId("dieter").setName("Design").setDescription("Native app design and accessibility").setWorkflow("review").build(),
        Board.newBuilder().setId("retired").setProjectId("dieter").setName("Retired board").setRetired(true).build(),
        Board.newBuilder().setId("other").setProjectId("box").setName("Another project board").build(),
    )
    private val state = DieterUiState(connectionPhase = ConnectionPhase.CONNECTED, projects = projects, spaceBoards = boards,
        projectReplicas = mapOf("vps" to ProjectReplica("vps", "vps", "VPS", false)))

    @Test fun projectsSearchAndBoardsNavigateWithContext() {
        val draft = CardCreationDraft()
        var opened = ""
        compose.setContent {
            DieterTheme(darkTheme = true) {
                CaptureDestinationSheet(state, draft, emptyList(), {}, { draft.projectId = it }, { opened = it }, {}, {})
            }
        }
        android.util.Log.i("TestRunner", "Picker: projects rendered")
        compose.onNodeWithTag("capture-project-dieter").assertTextContains("3 boards")
        compose.onNodeWithTag("capture-destination-list").performScrollToNode(hasTestTag("capture-project-vps"))
        compose.onNodeWithTag("capture-project-vps").assertTextContains("0 boards · Offline")
        compose.onNodeWithTag("capture-destination-list").performScrollToIndex(0)
        capture("task-projects.png")
        compose.onNodeWithTag("capture-destination-search").performTextInput("no such project")
        compose.onNodeWithText("No matching projects").assertIsDisplayed()
        compose.onNodeWithTag("capture-project-dieter").assertDoesNotExist()
        compose.onNodeWithContentDescription("Clear search").performClick()
        compose.onNodeWithTag("capture-project-dieter").performClick()
        compose.onNodeWithText("Choose board").assertIsDisplayed()
        compose.onNodeWithTag("capture-destination-search").assertIsNotFocused()
        compose.onNodeWithTag("capture-board-retired").assertDoesNotExist()
        compose.onNodeWithTag("capture-board-other").assertDoesNotExist()
        compose.onNodeWithTag("capture-board-main").assertTextContains("Everyday development and improvements")
        capture("task-boards.png")
        compose.onNodeWithTag("capture-destination-search").performTextInput("delivery")
        compose.onNodeWithTag("capture-board-main").assertDoesNotExist()
        compose.onNodeWithTag("capture-board-release").performClick()
        compose.runOnIdle { assertEquals("release", opened) }
        compose.onNodeWithContentDescription("Back to projects").performClick()
        compose.onNodeWithTag("capture-project-dieter").assertIsSelected().assertIsDisplayed()
    }

    @Test fun largeTextKeepsSavedDraftsAndLockedDestinationsUsable() {
        val draft = CardCreationDraft().apply {
            projectId = "dieter"; boardId = "main"
            submittedRequest = CreateConversationRequest.newBuilder().setProjectId("dieter").setBoardId("main").build()
        }
        val saved = CardCreationDraft().apply { title = "Improve task creation"; projectId = "dieter" }
        var resumed: CardCreationDraft? = null
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                DieterTheme(darkTheme = false) {
                    CaptureDestinationSheet(state, draft, listOf(saved), {}, {}, {}, { resumed = it }, {})
                }
            }
        }
        android.util.Log.i("TestRunner", "Picker large text: content set; finding disabled project")
        compose.onNodeWithTag("capture-destination-list").performScrollToNode(hasTestTag("capture-project-box"))
        android.util.Log.i("TestRunner", "Picker large text: disabled project found; finding draft")
        compose.onNodeWithTag("capture-project-box").assertIsNotEnabled()
        compose.onNodeWithTag("capture-destination-list").performScrollToNode(hasText(saved.title))
        android.util.Log.i("TestRunner", "Picker large text: saved draft found")
        compose.onNodeWithText(saved.title).performClick()
        compose.runOnIdle { assertEquals(saved, resumed) }
        compose.onNodeWithTag("capture-destination-list").performScrollToNode(hasTestTag("capture-project-dieter"))
        android.util.Log.i("TestRunner", "Picker large text: project found")
        compose.onNodeWithTag("capture-project-dieter").performClick()
        android.util.Log.i("TestRunner", "Picker large text: boards opened")
        val titleLayouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText("Choose board").performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(titleLayouts) }
        assertEquals(2f, titleLayouts.single().layoutInput.density.fontScale, 0.001f)
        android.util.Log.i("TestRunner", "Picker large text: scale verified")
        compose.onNodeWithTag("capture-board-main").assertIsEnabled()
        compose.onNodeWithTag("capture-destination-list").performScrollToNode(hasTestTag("capture-board-release"))
        android.util.Log.i("TestRunner", "Picker large text: disabled board found")
        compose.onNodeWithTag("capture-board-release").assertIsNotEnabled().assertIsDisplayed()
        capture("task-boards-large-text.png")
        compose.onNodeWithContentDescription("Back to projects").assertIsDisplayed().performClick()
        compose.onNodeWithContentDescription("Close task picker").assertIsDisplayed()
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = File(InstrumentationRegistry.getArguments().getString("dieterScreenshotsDir")
            ?: requireNotNull(instrumentation.targetContext.getExternalFilesDir(null)).path).apply { mkdirs() }
        File(directory, name).outputStream().use {
            requireNotNull(instrumentation.uiAutomation.takeScreenshot()).compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
