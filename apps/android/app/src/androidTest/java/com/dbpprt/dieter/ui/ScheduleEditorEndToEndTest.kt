package com.dbpprt.dieter.ui

import android.Manifest
import android.widget.TimePicker
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
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
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
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
    val rules: RuleChain = RuleChain.outerRule(permissionRule).around(composeRule)

    @Test
    fun createsRunningScheduleWithTemplatesThroughTheVisibleEditor() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val token = arguments.getString("isolatedGatewayToken").orEmpty()
        assumeTrue("Pass isolatedGatewayToken for the isolated gateway", token.isNotBlank())
        val port = arguments.getString("isolatedGatewayPort")?.toIntOrNull() ?: 14243
        val endpoint = DieterEndpoint(
            id = "android_schedule_e2e",
            label = "Isolated schedule gateway",
            host = "127.0.0.1",
            port = port,
        )
        val application = composeRule.activity.application as DieterApplication
        val manager = application.container.connectionManager
        application.container.repository.setAccessToken(endpoint, token)
        manager.updateEndpoints(listOf(endpoint), selectedGatewayId = endpoint.id)
        manager.connect()
        manager.onAppForegrounded()
        val connected = runBlocking {
            kotlinx.coroutines.withTimeoutOrNull(30_000) {
                manager.state.first { state ->
                    state.phase == ConnectionPhase.CONNECTED && state.projects.isNotEmpty() && state.boards.isNotEmpty()
                }
            }
        }
        assertNotNull("Connection failed: ${manager.state.value.phase} · ${manager.state.value.error}", connected)
        requireNotNull(connected)
        val project = connected.projects.first { candidate -> connected.boards.any { it.projectId == candidate.id } }
        manager.onAppForegrounded(project.id)

        composeRule.waitForIdle()

        composeRule.waitUntil(20_000) {
            composeRule.onAllNodesWithText("Schedules").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithText("Schedules")[0].performClick()
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodesWithTag("new-schedule").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("new-schedule")[0].performClick()
        composeRule.onNodeWithTag("schedule-name").assertIsDisplayed()

        val fixtureName = "Android schedule E2E ${UUID.randomUUID().toString().take(8)}"
        composeRule.onNodeWithTag("schedule-name").performTextInput(fixtureName)
        pressBack()
        composeRule.onNodeWithTag("schedule-time-picker").performScrollTo().performClick()
        onView(isAssignableFrom(TimePicker::class.java)).check(matches(isDisplayed()))
        pressBack()
        composeRule.onNodeWithTag("schedule-prompt").performScrollTo().performTextInput(
            "Review {{project}} / {{board}} for {{date}} at {{scheduled_at}} from {{schedule}}.",
        )
        pressBack()
        composeRule.onNodeWithTag("schedule-placement-running").performScrollTo().performClick()
        composeRule.onNodeWithText("The daemon creates the card and starts its agent turn when admission allows.")
            .performScrollTo().assertIsDisplayed()
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

        composeRule.onNodeWithText("Save").performClick()
        composeRule.waitUntil(15_000) { composeRule.onAllNodesWithText(fixtureName).fetchSemanticsNodes().isNotEmpty() }

        val persisted = runBlocking {
            withTimeout(10_000) {
                application.container.repository.schedules(project.id).schedulesList.first { it.name == fixtureName }
            }
        }
        assertEquals("run", persisted.action)
        assertEquals("Scheduled work · {{date}}", persisted.titleTemplate)
        assertTrue(persisted.promptTemplate.contains("{{project}}"))
        assertTrue(persisted.promptTemplate.contains("{{scheduled_at}}"))
        runBlocking { application.container.repository.deleteSchedule(persisted.id) }
    }
}
