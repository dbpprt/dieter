package com.dbpprt.dieter.spike

import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Rule
import org.junit.Test

class ComposeSpikeTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun sharedTaskJourney() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val arguments = InstrumentationRegistry.getArguments()
        val intent =
            Intent(context, SpikeActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("fixture_url", arguments.getString("fixture_url"))
                putExtra("fixture_token", arguments.getString("fixture_token"))
            }
        ActivityScenario.launch<SpikeActivity>(intent).use { scenario ->
            waitForText("Design the mobile workspace")
            capture("android-inbox")
            compose.onNodeWithTag("nav-projects").performClick()
            waitForText("Isolated E2E")
            if (compose.onAllNodesWithText("Main").fetchSemanticsNodes().isEmpty()) {
                compose.onNodeWithText("Isolated E2E").performClick()
            }
            waitForText("Main")
            capture("android-projects")
            compose.onNodeWithText("Main").performClick()
            waitForText("Running  3")
            capture("android-board")
            compose
                .onNode(hasScrollToIndexAction())
                .performScrollToNode(hasText("Design the mobile workspace"))
            compose.onNodeWithText("Design the mobile workspace").performClick()
            waitForText("Your board stays within reach", substring = true)
            capture("android-task")
            compose.onNodeWithText("Subagents 1").performClick()
            waitForText("Layout scout")
            compose.onNodeWithText("Layout scout").performClick()
            capture("android-subagents")
            compose.onNodeWithText("Conversation", substring = false).performClick()
            compose.onNodeWithContentDescription("Back to board").performClick()
            compose.onNodeWithContentDescription("New task").performClick()
            compose.onNodeWithText("Task title").performTextInput("A shared mobile conversation")
            compose
                .onNodeWithText("What should we do?")
                .performTextInput("Explain how this task stays in one durable conversation.")
            scenario.recreate()
            waitForText("A shared mobile conversation")
            compose
                .onNodeWithText("Explain how this task stays in one durable conversation.")
                .assertExists()
            capture("android-new-task")
            compose.onNodeWithText("Start working").performScrollTo().performClick()
            waitForText("Mock harness received:", substring = true)
            capture("android-conversation")
            compose
                .onNodeWithText("Keep the conversation going…")
                .performTextInput("Keep the same task and add the next step.")
            scenario.recreate()
            waitForText("Keep the same task and add the next step.")
            compose.onNodeWithContentDescription("Send message").performClick()
            waitForText("Mock harness received: Keep the same task", substring = true)
            compose.waitUntil(60000) {
                compose
                    .onAllNodesWithText("Review", useUnmergedTree = true)
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            compose.onNodeWithText("Review").performClick()
            compose.onNodeWithContentDescription("Back to board").performClick()
            compose.onNodeWithText("Review  2").performClick()
            waitForText("A shared mobile conversation")
            capture("android-review")
            compose.onNodeWithTag("nav-chats").performClick()
            waitForText("Mobile release checklist")
            capture("android-chats")
            compose.onNodeWithTag("nav-tools").performClick()
            waitForText("Machines")
            capture("android-tools")
            compose.onNodeWithText("Machines").performClick()
            waitForDescription("Reconnect")
            capture("android-machines")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Files").performClick()
            waitForText("README.md")
            capture("android-files")
            compose.onNodeWithText("README.md").performClick()
            waitForText("# Mobile workspace", substring = true)
            compose.onNodeWithContentDescription("Preview Markdown").performClick()
            waitForText("One durable conversation", substring = true)
            capture("android-file-preview")
            compose.onNodeWithContentDescription("Back to files").performClick()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Schedules").performClick()
            waitForText("Daily workspace review")
            capture("android-schedules")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Settings").performClick()
            waitForText("Appearance")
            compose.onNodeWithText("System").performClick()
            compose.onNodeWithText("Dark").performClick()
            capture("android-settings-dark")
            compose.onNodeWithTag("nav-projects").performClick()
            waitForText("Main")
            compose.onNodeWithText("Main").performClick()
            waitForText("Running  3")
            capture("android-board-dark")
        }
    }

    private fun waitForText(text: String, substring: Boolean = false) {
        try {
            compose.waitUntil(60000) {
                compose
                    .onAllNodesWithText(text, substring = substring)
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
        } catch (failure: Throwable) {
            capture("android-failure")
            compose.onRoot().printToLog("ComposeSpikeFailure")
            throw failure
        }
    }

    private fun waitForDescription(value: String) {
        compose.waitUntil(60000) {
            compose.onAllNodesWithContentDescription(value).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        // Semantics can be committed before SurfaceFlinger presents the frame.
        // Keep full native captures (including keyboard/system bars) and let the
        // rendered buffer catch up to the verified Compose state.
        android.os.SystemClock.sleep(350)
        val directory =
            File(instrumentation.targetContext.getExternalFilesDir(null), "compose-screenshots")
                .apply { mkdirs() }
        File(directory, "$name.png").outputStream().use {
            instrumentation.uiAutomation
                .takeScreenshot()
                .compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
