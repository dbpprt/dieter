package com.dbpprt.dieter.ui

import android.Manifest
import android.widget.TimePicker
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.Espresso.pressBack
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.api.v1.ListSchedulesRequest
import com.dbpprt.dieter.api.v1.ScheduleRef
import com.dbpprt.dieter.e2e.IsolatedCore
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Real Activity → isolated gateway → daemon coverage. */
@RunWith(AndroidJUnit4::class)
class ScheduleEditorEndToEndTest {
    private val permissionRule = GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS)
    private val composeRule = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test
    fun createsRunningScheduleWithTemplatesThroughTheVisibleEditor() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val application = composeRule.activity.application as DieterApplication
        val container = application.container
        val connected = IsolatedCore.connect(container)
        val daemonId = IsolatedCore.daemonId(container)
        IsolatedCore.harnesses(container, daemonId)
        val boards = connected.boards.values.flatten()
        val project = connected.projects.first { candidate -> boards.any { it.project_id == candidate.id } }
        composeRule.runOnIdle { ViewModelProvider(composeRule.activity)[DieterViewModel::class.java].selectProject(project.id) }

        composeRule.waitForIdle()

        composeRule.onNodeWithTag("nav-tools").performClick()
        composeRule.waitUntil(20_000) {
            composeRule.onAllNodesWithTag("tool-schedules").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("tool-schedules").performClick()
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodesWithTag("new-schedule").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("new-schedule")[0].performClick()
        composeRule.onNodeWithTag("schedule-name").assertIsDisplayed()

        val fixtureName = "Android schedule E2E ${UUID.randomUUID().toString().take(8)}"
        composeRule.onNodeWithTag("schedule-name").performTextInput(fixtureName)
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        composeRule.onNodeWithTag("schedule-time-picker").performScrollTo().performClick()
        onView(isAssignableFrom(TimePicker::class.java)).inRoot(androidx.test.espresso.matcher.RootMatchers.isDialog()).check(matches(isDisplayed()))
        pressBack()
        composeRule.onNodeWithTag("schedule-prompt").performScrollTo().performTextInput(
            "Review {{project}} / {{board}} for {{date}} at {{scheduled_at}} from {{schedule}}.",
        )
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        // Choose the actual board; a display fallback is not a saved selection.
        val boardName = boards.first { it.project_id == project.id }.name
        composeRule.onNodeWithText(boardName).performScrollTo().performClick()
        composeRule.onAllNodesWithText(boardName).onLast().performClick()
        composeRule.onNodeWithTag("schedule-placement-running").performScrollTo().performClick()
        composeRule.onNodeWithText("The daemon creates the card and starts its agent turn when admission allows.")
            .performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("workspace-mode-worktree").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("workspace-mode-project").performScrollTo().performClick()
        composeRule.onAllNodesWithText("{{date}}")[0].performScrollTo().assertIsDisplayed()

        val context = instrumentation.targetContext
        val screenshotDirectory = arguments.getString("additionalTestOutputDir")
            ?.takeIf(String::isNotBlank)
            ?.let(::File)
            ?: requireNotNull(context.getExternalFilesDir(null))
        screenshotDirectory.mkdirs()
        val screenshot = File(screenshotDirectory, "schedule-editor-e2e.png")
        screenshot.outputStream().use { output ->
            instrumentation.uiAutomation.takeScreenshot().compress(
                android.graphics.Bitmap.CompressFormat.PNG,
                100,
                output,
            )
        }

        composeRule.onNodeWithText("Save").assertIsEnabled().performClick()
        composeRule.waitUntil(15_000) { composeRule.onAllNodesWithTag("schedule-name").fetchSemanticsNodes().isEmpty() }
        composeRule.onNodeWithText(fixtureName).assertIsDisplayed()

        val persisted = runBlocking {
            withTimeout(10_000) {
                container.core.onMachine(daemonId) { it.ListSchedules().execute(ListSchedulesRequest(project_id = project.id)) }
                    .schedules.first { it.name == fixtureName }
            }
        }
        try {
            assertEquals("run", persisted.action)
            assertEquals("project", persisted.workspace_mode)
            assertEquals("Scheduled work · {{date}}", persisted.title_template)
            assertTrue(persisted.prompt_template.contains("{{project}}"))
            assertTrue(persisted.prompt_template.contains("{{scheduled_at}}"))
        } finally {
            runBlocking { container.core.onMachine(daemonId) { it.DeleteSchedule().execute(ScheduleRef(schedule_id = persisted.id)) } }
            IsolatedCore.disconnect(container)
        }
    }
}
