package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.presentation.TimelineBuilder
import com.dbpprt.dieter.core.presentation.TimelineItem
import com.dbpprt.dieter.e2e.TestCore
import com.dbpprt.dieter.e2e.saveEvidence
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.UiMessage
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** Native rendering with disposable app identity; no operator conversation is opened. */
class LongConversationMessageTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private lateinit var core: TestCore
    private lateinit var model: DieterViewModel

    @Before fun setup() {
        assumeTrue("Use the isolated screen fixture app", (context.packageName.endsWith(".e2e")))
        core = TestCore(navigationAccount = "component-fixture")
        compose.runOnUiThread {
            model = core.viewModel()
            lifecycle.put("long-message", model)
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        core.close()
        core.delete()
    }

    @Test fun largeTurnShowsLatestAndRevealsEarlierProseWithNativeInput() {
        val message = UiMessage(id = "long", role = "assistant", parts = (0 until 340).flatMap { index -> listOf(
                MessagePart(type = "text", text = "Step $index"),
                MessagePart(type = "dynamic-tool", tool_name = "exec", tool_call_id = "tool-$index", state = "output-available"),
            ) }.toList())
        var presentedMessage by mutableStateOf(message)
        compose.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
                        MessageParts(TimelineBuilder.build(listOf(presentedMessage)).items.filterIsInstance<TimelineItem.Message>().single(), model)
                    }
                }
            }
        }
        compose.onNodeWithText("Step 0").assertDoesNotExist()
        compose.onNodeWithText("Step 339").performScrollTo().assertIsDisplayed()
        compose.onRoot().saveEvidence("long-message-tail.png")
        compose.onAllNodesWithContentDescription("Expand tool activity")[5].performScrollTo().performClick()
        compose.onNodeWithContentDescription("Collapse tool activity").assertExists()
        compose.onNodeWithTag("message-earlier-long").performScrollTo().performClick()
        compose.onNodeWithText("Step 328").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("Collapse tool activity").assertExists()
        compose.onNodeWithText("Step 0").assertDoesNotExist()
        compose.onRoot().saveEvidence("long-message-earlier.png")
        compose.runOnUiThread {
            presentedMessage = message.copy(parts = listOf(MessagePart(type = "text", text = "Refreshed shorter message")))
        }
        compose.onNodeWithText("Refreshed shorter message").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("message-earlier-long").assertDoesNotExist()
    }
}
