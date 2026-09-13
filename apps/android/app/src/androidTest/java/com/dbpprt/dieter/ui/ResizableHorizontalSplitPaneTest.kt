package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ResizableHorizontalSplitPaneTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun dividerDragResizesBothPanes() {
        var committedFraction: Float? = null
        composeRule.setContent {
            DieterTheme {
                Surface(
                    modifier = Modifier.width(800.dp).height(500.dp),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    ResizableHorizontalSplitPane(
                        dividerTag = "test-pane-divider",
                        minimumLeadingWidth = 80.dp,
                        minimumTrailingWidth = 120.dp,
                        onLeadingFractionCommitted = { committedFraction = it },
                        leading = { Box(it.fillMaxSize().testTag("leading-pane")) },
                        trailing = { Box(it.fillMaxSize().testTag("trailing-pane")) },
                    )
                }
            }
        }

        composeRule.onNodeWithTag("test-pane-divider")
            .assertContentDescriptionEquals("Resize list and detail panes")
        val leadingBefore = composeRule.onNodeWithTag("leading-pane").fetchSemanticsNode().boundsInRoot.width
        val trailingBefore = composeRule.onNodeWithTag("trailing-pane").fetchSemanticsNode().boundsInRoot.width

        composeRule.onNodeWithTag("test-pane-divider").performTouchInput {
            down(center)
            moveBy(Offset(180f, 0f), delayMillis = 500)
            up()
        }
        composeRule.waitForIdle()

        val leadingAfter = composeRule.onNodeWithTag("leading-pane").fetchSemanticsNode().boundsInRoot.width
        val trailingAfter = composeRule.onNodeWithTag("trailing-pane").fetchSemanticsNode().boundsInRoot.width
        assertTrue("Dragging right should widen the leading pane", leadingAfter > leadingBefore)
        assertTrue("Dragging right should narrow the trailing pane", trailingAfter < trailingBefore)
        val firstCommittedFraction = requireNotNull(committedFraction)
        assertTrue("Finishing the drag should commit the wider split", firstCommittedFraction > 0.43f)

        composeRule.onNodeWithTag("test-pane-divider").performTouchInput {
            down(center)
            moveBy(Offset(-90f, 0f), delayMillis = 500)
            up()
        }
        composeRule.waitForIdle()

        val leadingAfterReverse = composeRule.onNodeWithTag("leading-pane").fetchSemanticsNode().boundsInRoot.width
        assertTrue("A later drag should continue from the resized position", leadingAfterReverse < leadingAfter)
        assertTrue("The later drag should not jump back to the initial position", leadingAfterReverse > leadingBefore)
        assertTrue(
            "Finishing the later drag should commit its new split",
            requireNotNull(committedFraction) < firstCommittedFraction,
        )
    }

    @Test
    fun committedWidthRestoresFromDevicePreferences() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val originalPreferences = AppPreferences(context)
        val originalFraction = originalPreferences.chatsPaneLeadingFraction.value
        originalPreferences.setChatsPaneLeadingFraction(0.35f)
        var activePreferences by mutableStateOf(AppPreferences(context))
        var generation by mutableIntStateOf(0)

        try {
            composeRule.setContent {
                key(generation) {
                    val persistedFraction by activePreferences.chatsPaneLeadingFraction.collectAsState()
                    DieterTheme {
                        Surface(
                            modifier = Modifier.width(800.dp).height(500.dp),
                            color = MaterialTheme.colorScheme.background,
                        ) {
                            ResizableHorizontalSplitPane(
                                dividerTag = "persisted-test-pane-divider",
                                initialLeadingFraction = persistedFraction,
                                minimumLeadingWidth = 80.dp,
                                minimumTrailingWidth = 120.dp,
                                onLeadingFractionCommitted = activePreferences::setChatsPaneLeadingFraction,
                                leading = { Box(it.fillMaxSize().testTag("persisted-leading-pane")) },
                                trailing = { Box(it.fillMaxSize().testTag("persisted-trailing-pane")) },
                            )
                        }
                    }
                }
            }

            composeRule.onNodeWithTag("persisted-test-pane-divider").performTouchInput {
                down(center)
                moveBy(Offset(120f, 0f), delayMillis = 500)
                up()
            }
            composeRule.waitForIdle()
            val resizedWidth = composeRule.onNodeWithTag("persisted-leading-pane")
                .fetchSemanticsNode().boundsInRoot.width
            val persistedFraction = activePreferences.chatsPaneLeadingFraction.value

            composeRule.runOnIdle {
                activePreferences = AppPreferences(context)
                generation += 1
            }
            composeRule.waitForIdle()

            val restoredWidth = composeRule.onNodeWithTag("persisted-leading-pane")
                .fetchSemanticsNode().boundsInRoot.width
            assertEquals(resizedWidth, restoredWidth, 1f)
            assertEquals(persistedFraction, activePreferences.chatsPaneLeadingFraction.value, 0.0001f)
        } finally {
            originalPreferences.setChatsPaneLeadingFraction(originalFraction)
        }
    }
}
