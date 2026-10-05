package com.dbpprt.dieter.ui

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.e2e.Evidence
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ConversationDestinationPickerTest {
    @get:Rule val compose = createComposeRule()
    private val projects = listOf("dieter", "nmt-aigency", "box", "afa", "gx10s", "vps").map {
        Project(id = it, name = it, path = "~/Development/$it", base_remote = "origin", base_branch = "main")
    }
    private val boards = listOf(
        Board(id = "main", project_id = "dieter", name = "Main", description = "Everyday development and improvements", workflow = "review", created_at = "2026-09-20T12:00:00Z"),
        Board(id = "release", project_id = "dieter", name = "Main", description = "Release fixes and delivery", workflow = "direct", created_at = "2026-09-22T12:00:00Z"),
        Board(id = "design", project_id = "dieter", name = "Design", description = "Native app design and accessibility", workflow = "review"),
        Board(id = "retired", project_id = "dieter", name = "Retired board", retired = true),
        Board(id = "other", project_id = "box", name = "Another project board"),
    )
    private val state = DieterUiState(connectionPhase = ConnectionPhase.CONNECTED, projects = projects, spaceBoards = boards,
        projectHosts = mapOf("vps" to "vps"))

    @Test fun projectsSearchAndBoardsNavigateWithContext() {
        var draft by mutableStateOf(CaptureDraft(id = "capture"))
        var opened = ""
        compose.setContent {
            DieterTheme(darkTheme = true) {
                CaptureDestinationSheet(state, draft, emptyList(), {}, { draft = TaskDrafts.project(draft, it) }, { opened = it }, {}, {})
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
        val draft = CaptureDraft(
            id = "submitted", project_id = "dieter", board_id = "main", submission_id = "submission", submitted = true,
            request = CreateConversationRequest(project_id = "dieter", board_id = "main"),
        )
        val saved = TaskDrafts.title(CaptureDraft(id = "saved", project_id = "dieter"), "Improve task creation")
        val savedTitle = saved.task.title
        var resumed: CaptureDraft? = null
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
        compose.onNodeWithTag("capture-destination-list").performScrollToNode(hasText(savedTitle))
        android.util.Log.i("TestRunner", "Picker large text: saved draft found")
        compose.onNodeWithText(savedTitle).performClick()
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
        Evidence.display(name)
    }
}
