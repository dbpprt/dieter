package com.dbpprt.dieter.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ProjectPickerSheetTest {
    @get:Rule
    val composeRule = createComposeRule()

    private val twoProjects = DieterUiState(
        projects = listOf(
            Project.newBuilder().setId("p1").setName("Dieter").setPath("/Users/me/Development/dieter").build(),
            Project.newBuilder().setId("p2").setName("Kannacli").setPath("/Users/me/Development/kannacli").build(),
        ),
        selectedProjectId = "p1",
    )

    @Test
    fun filesTargetListsProjectsAndReportsSelection() {
        var picked: String? = null
        composeRule.setContent {
            DieterTheme {
                ProjectPickerSheet(
                    state = twoProjects,
                    target = Destination.FILES,
                    onDismiss = {},
                    onSelect = { picked = it },
                )
            }
        }

        composeRule.onNodeWithText("Open files in").assertIsDisplayed()
        composeRule.onNodeWithTag("project-picker-p1").assertIsDisplayed()
        composeRule.onNodeWithTag("project-picker-p2").assertIsDisplayed()
        composeRule.onNodeWithText("Kannacli").assertIsDisplayed()

        composeRule.onNodeWithTag("project-picker-p2").performClick()
        composeRule.runOnIdle { assertEquals("p2", picked) }
    }

    @Test
    fun schedulesTargetUsesScheduleTitle() {
        composeRule.setContent {
            DieterTheme {
                ProjectPickerSheet(
                    state = twoProjects,
                    target = Destination.SCHEDULES,
                    onDismiss = {},
                    onSelect = {},
                )
            }
        }

        composeRule.onNodeWithText("Open schedules in").assertIsDisplayed()
    }
}
