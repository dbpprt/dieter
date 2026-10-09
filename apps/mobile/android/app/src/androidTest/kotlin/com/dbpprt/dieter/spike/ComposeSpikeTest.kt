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
            waitForText("Main")
            capture("android-projects")
            compose.onNodeWithText("Main").performClick()
            waitForTag("lane-1")
            waitForText("Design the mobile workspace")
            capture("android-board")
            compose.onNodeWithText("Design the mobile workspace").performClick()
            waitForText("Your board stays within reach", substring = true)
            capture("android-task")
            compose.onNodeWithTag("chrome-conversation-menu").performClick()
            compose.onNodeWithTag("menu-pane-subagents").performClick()
            waitForText("Layout scout")
            capture("android-subagents")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForText("Your board stays within reach", substring = true)
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("chrome-new-task")
            compose.onNodeWithTag("chrome-new-task").performClick()
            waitForTag("task-title")
            compose.onNodeWithTag("task-title").performTextInput("A shared mobile conversation")
            compose
                .onNodeWithTag("task-prompt")
                .performTextInput("Explain how this task stays in one durable conversation.")
            scenario.recreate()
            waitForText("A shared mobile conversation")
            compose
                .onNodeWithText("Explain how this task stays in one durable conversation.")
                .assertExists()
            capture("android-new-task")
            compose.onNodeWithTag("chrome-start-working").performClick()
            waitForText("Mock harness received:", substring = true)
            capture("android-conversation")
            compose
                .onNodeWithTag("message-input")
                .performTextInput("Keep the same task and add the next step.")
            scenario.recreate()
            waitForText("Keep the same task and add the next step.")
            compose.onNodeWithTag("send-message").performClick()
            waitForText("Mock harness received: Keep the same task", substring = true)
            waitForTag("move-review")
            compose.onNodeWithTag("move-review").performClick()
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("lane-2")
            compose.onNodeWithTag("lane-2").performClick()
            waitForText("A shared mobile conversation")
            capture("android-review")
            compose.onNodeWithTag("nav-chats").performClick()
            waitForText("Mobile release checklist")
            capture("android-chats")
            compose.onNodeWithTag("nav-tools").performClick()
            waitForTag("tool-machines")
            capture("android-tools")
            compose.onNodeWithTag("tool-machines").performClick()
            waitForText("Isolated E2E machine")
            capture("android-machines")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("tool-files")
            compose.onNodeWithTag("tool-files").performClick()
            waitForText("README.md")
            capture("android-files")
            compose.onNodeWithText("README.md").performClick()
            waitForText("One durable conversation", substring = true)
            capture("android-file-preview")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForText("README.md")
            compose.onNodeWithTag("chrome-back").performClick()
            waitForTag("tool-schedules")
            compose.onNodeWithTag("tool-schedules").performClick()
            waitForText("Daily workspace review")
            capture("android-schedules")
            compose.onNodeWithTag("chrome-back").performClick()
            compose.onNodeWithTag("tools-list").performScrollToNode(hasTestTag("tool-settings"))
            compose.onNodeWithTag("tool-settings").performClick()
            waitForTag("appearance-2")
            compose.onNodeWithTag("appearance-2").performClick()
            capture("android-settings-dark")
            compose.onNodeWithTag("nav-projects").performClick()
            waitForText("Main")
            compose.onNodeWithText("Main").performClick()
            waitForTag("lane-1")
            capture("android-board-dark")
        }
    }

    private fun waitForText(text: String, substring: Boolean = false) =
        waitFor("text $text") {
            compose
                .onAllNodesWithText(text, substring = substring)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }

    private fun waitForTag(tag: String) =
        waitFor("tag $tag") { compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }

    private fun waitFor(description: String, condition: () -> Boolean) {
        try {
            compose.waitUntil(60000) { condition() }
        } catch (failure: Throwable) {
            capture("android-failure")
            compose.onRoot().printToLog("ComposeSpikeFailure")
            throw AssertionError("Timed out waiting for $description", failure)
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
