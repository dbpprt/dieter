package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Lane
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class QuickTaskAndTerminalCreationTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun quickTaskDraftSurvivesClosingAndReopeningSheet() {
        val draft = CardCreationDraft()
        var story by draft::prompt
        var open by draft::quickTaskOpen
        open = true
        var options by mutableStateOf(false)
        val project = Project.newBuilder().setId("p1").setName("Dieter").setPath("/Users/me/Development/dieter").build()
        val board = Board.newBuilder()
            .setId("b1")
            .setProjectId(project.id)
            .setName("Main")
            .addLanes(Lane.newBuilder().setId("todo").setName("Todo"))
            .build()
        val state = DieterUiState(
            projects = listOf(project),
            selectedProjectId = project.id,
            boards = listOf(board),
            selectedBoardId = board.id,
        )

        compose.setContent {
            DieterTheme {
                Box(Modifier.fillMaxSize()) {
                    Button(onClick = { open = true }) { Text("Open quick task") }
                    if (options) {
                        NewCardBody(
                            state = state, title = draft.title, onTitleChange = { draft.title = it },
                            prompt = draft.prompt, onPromptChange = { draft.prompt = it },
                            provider = draft.provider, onProviderChange = {}, harness = null,
                            model = draft.model, onModelChange = {}, effort = draft.effort, onEffortChange = {},
                            providerOptions = draft.providerOptions, onProviderOptionChange = { _, _ -> },
                            harnesses = emptyList(), lane = draft.lane, onLaneChange = { draft.lane = it },
                            labelIds = draft.labelIds, workspaceMode = draft.workspaceMode,
                            onWorkspaceModeChange = { draft.workspaceMode = it }, attachments = draft.attachments,
                            onAttach = {}, onRemoveAttachment = { draft.attachments.removeAt(it) },
                        )
                    }
                    if (open) {
                        QuickTaskPopover(
                            state = state,
                            defaults = ResolvedConversationCreationPreferences(
                                provider = "",
                                model = "",
                                effort = "",
                                workspaceMode = ConversationWorkspaceMode.PROJECT,
                            ),
                            story = story,
                            onStoryChange = { story = it },
                            onDismiss = { open = false },
                            onOpenFull = { draft.openOptions(); options = true },
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
        compose.runOnIdle { assertEquals(ConversationWorkspaceMode.PROJECT, draft.workspaceMode) }

    }

    @Test
    fun terminalPickerShowsMachineForDuplicateProjectNames() {
        val laptopProject = Project.newBuilder().setId("p1").setName("Dieter").setPath("/Users/me/Development/dieter").build()
        val studioProject = Project.newBuilder().setId("p2").setName("Dieter").setPath("/Users/me/Development/dieter").build()
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
