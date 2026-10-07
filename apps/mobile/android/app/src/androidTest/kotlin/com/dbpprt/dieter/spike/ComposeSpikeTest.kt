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
        ActivityScenario.launch<SpikeActivity>(intent).use {
            waitForText("Running  3")
            capture("android-board")
            compose
                .onNode(hasScrollToIndexAction())
                .performScrollToNode(hasText("Design the mobile workspace"))
            compose.onNodeWithText("Design the mobile workspace").performClick()
            waitForText("Your board stays within reach", substring = true)
            capture("android-task")
            compose.onNodeWithContentDescription("Back to board").performClick()
            compose.onNodeWithContentDescription("New task").performClick()
            compose.onNodeWithText("Task title").performTextInput("A shared mobile conversation")
            compose
                .onNodeWithText("What should we do?")
                .performTextInput("Explain how this task stays in one durable conversation.")
            capture("android-new-task")
            compose.onNodeWithText("Start working").performScrollTo().performClick()
            waitForText("Mock harness received:", substring = true)
            capture("android-conversation")
            compose
                .onNodeWithText("Keep the conversation going…")
                .performTextInput("Keep the same task and add the next step.")
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
            compose.onNodeWithText("Machines").performClick()
            waitForText("Your machines")
            capture("android-machines")
        }
    }

    private fun waitForText(text: String, substring: Boolean = false) {
        compose.waitUntil(60000) {
            compose
                .onAllNodesWithText(text, substring = substring)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
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
