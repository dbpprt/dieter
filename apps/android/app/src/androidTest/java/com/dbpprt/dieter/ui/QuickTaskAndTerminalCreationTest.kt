package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTextInput
import com.dbpprt.dieter.core.composition.TaskDraftEditor
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.ui.ProjectReplica
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class QuickTaskAndTerminalCreationTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun quickTaskDraftSurvivesClosingAndReopeningSheet() {
        val editor = TaskDraftEditor(CaptureDraft(id = "quick", project_id = "p1", board_id = "b1"))
        var open by mutableStateOf(true)
        var options by mutableStateOf(false)
        val project = Project(id = "p1", name = "Dieter", path = "/Users/me/Development/dieter")
        val board = Board(id = "b1", project_id = project.id, name = "Main", lanes = listOf(Lane(id = "todo", name = "Todo")))
        val state = DieterUiState(
            projects = listOf(project),
            selectedProjectId = project.id,
            boards = listOf(board),
            selectedBoardId = board.id,
        )

        compose.setContent {
            val draft by editor.state.collectAsState()
            DieterTheme {
                Box(Modifier.fillMaxSize()) {
                    Button(onClick = { open = true }) { Text("Open quick task") }
                    if (options) {
                        NewCardBody(
                            state = state,
                            draft = draft,
                            onTitleChange = { value -> editor.edit { TaskDrafts.title(it, value) } },
                            onPromptChange = { value -> editor.edit { TaskDrafts.prompt(it, value) } },
                            controls = AgentControls(TaskDrafts.selection(draft), emptyList(), locked = false),
                            onSelectionChange = { selection -> editor.edit { TaskDrafts.choose(it, selection) } },
                            onLaneChange = { lane -> editor.edit { TaskDrafts.lane(it, lane) } },
                            onToggleLabel = { label -> editor.edit { TaskDrafts.toggleLabel(it, label) } },
                            onWorkspaceModeChange = { mode -> editor.edit { TaskDrafts.workspaceMode(it, mode) } },
                            attachmentContent = {},
                        )
                    }
                    if (open) {
                        QuickTaskPopover(
                            state = state,
                            draft = draft,
                            onStoryChange = { value -> editor.edit { TaskDrafts.prompt(it, value) } },
                            onDismiss = { open = false },
                            onOpenFull = { open = false; options = true },
                            onCreate = {},
                        )
                    }
                }
            }
        }

        compose.onNodeWithTag("quick-task-story").performTextInput("Keep this unfinished task")
        compose.onNodeWithContentDescription("Close quick task").performClick()
        compose.onNodeWithText("Open quick task").performClick()
        compose.onNodeWithTag("quick-task-story")
            .assertIsDisplayed()
            .assertTextContains("Keep this unfinished task")
        compose.onNodeWithText("More options").performClick()
        compose.onNodeWithTag("conversation-prompt").assertTextContains("Keep this unfinished task")
        compose.onNodeWithTag("conversation-title").performTextReplacement("Keep this unfinished task edited")
        compose.onNodeWithTag("workspace-mode-project").performScrollTo().performClick()
        compose.runOnIdle { options = false; open = true }
        compose.onNodeWithTag("quick-task-story").assertTextContains("Keep this unfinished task")
        compose.onNodeWithText("More options").performClick()
        compose.onNodeWithTag("conversation-title").assertTextContains("Keep this unfinished task edited")
        compose.runOnIdle { assertEquals(WorkspaceMode.PROJECT, TaskDrafts.workspaceMode(editor.state.value)) }
    }

    @Test
    fun terminalPickerShowsMachineForDuplicateProjectNames() {
        val laptopProject = Project(id = "p1", name = "Dieter", path = "/Users/me/Development/dieter")
        val studioProject = Project(id = "p2", name = "Dieter", path = "/Users/me/Development/dieter")
        val hosts = mapOf(
            "p1" to ProjectReplica("endpoint-1", "daemon-1", "Laptop", online = true),
            "p2" to ProjectReplica("endpoint-2", "daemon-2", "Studio", online = true),
        )
        var selectedProjectId by mutableStateOf("p1")

        compose.setContent {
            DieterTheme {
                Surface {
                    TerminalProjectPicker(
                        projects = listOf(laptopProject, studioProject),
                        projectReplicas = hosts,
                        selectedProjectId = selectedProjectId,
                        onProjectChange = { selectedProjectId = it },
                    )
                }
            }
        }

        compose.onNodeWithText("Laptop · ~/Development/dieter").assertIsDisplayed()
        compose.onNodeWithTag("terminal-project-picker").performClick()
        compose.onNodeWithText("Studio · ~/Development/dieter").assertIsDisplayed()
        compose.onNodeWithTag("terminal-project-p2").performClick()
        compose.runOnIdle { assertEquals("p2", selectedProjectId) }
        compose.onNodeWithText("Studio · ~/Development/dieter").assertIsDisplayed()
    }
}
