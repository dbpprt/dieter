package com.dbpprt.dieter.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ScreenNavigationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun glassDockOpensScreensWithoutASelectedProject() {
        var selected = Destination.CHATS
        compose.setContent {
            var destination by remember { mutableStateOf(Destination.CHATS) }
            DieterTheme {
                GlassNavigationDock(
                    state = DieterUiState(destination = destination),
                    onNavigate = { selected = it; destination = it },
                    onSettings = {},
                )
            }
        }
        compose.onNodeWithContentDescription("Screens").assertIsDisplayed().performClick()
        compose.onNodeWithText("Screens").assertIsDisplayed()
        compose.runOnIdle { assertEquals(Destination.SCREENS, selected) }
    }
}
