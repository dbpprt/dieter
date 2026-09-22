package com.dbpprt.dieter.ui

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.unit.Density
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ScreenNavigationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun toolsTakeKeyboardFocusAndKeepTabTraversalInsideTheSheet() {
        var open by mutableStateOf(false)
        lateinit var inputMode: InputModeManager
        compose.setContent {
            inputMode = LocalInputModeManager.current
            DieterTheme {
                if (open) DieterToolsSheet(Destination.BOARD, true, {}, {}, {})
                else DieterBottomBar(Destination.BOARD, {}, { open = true })
            }
        }
        compose.runOnIdle {
            // Clickable surfaces intentionally reject keyboard focus in touch
            // mode. Open as a keyboard user before checking modal traversal.
            assertTrue("Keyboard mode must be available with the bottom bar mounted",
                inputMode.requestInputMode(InputMode.Keyboard))
        }
        compose.onNodeWithTag("nav-tools").performClick()
        compose.onNodeWithTag("tool-machines").assertIsFocused()
        compose.onNodeWithTag("tools-content").performKeyInput { repeat(15) { pressKey(Key.Tab) } }
        compose.onNode(isFocused()).assert(hasAnyAncestor(hasTestTag("tools-content")))
    }

    @Test fun toolsDismissWhenDraggedToTheZeroHeightPeek() {
        var open by mutableStateOf(true)
        compose.setContent {
            DieterTheme {
                if (open) DieterToolsSheet(
                    selected = Destination.BOARD,
                    projectSurfacesEnabled = true,
                    onSelect = {},
                    onSettings = {},
                    onDismiss = { open = false },
                )
            }
        }
        compose.onNodeWithTag("tools-content").performTouchInput { swipeDown() }
        compose.onNodeWithTag("tools-sheet").assertDoesNotExist()
    }

    @Test fun bottomBarIncludesInboxProjectsChatsAndTools() {
        var selected: Destination? = null
        var toolsOpened = false
        compose.setContent {
            DieterTheme {
                DieterBottomBar(
                    selected = Destination.CHATS,
                    onSelect = { selected = it },
                    onTools = { toolsOpened = true },
                )
            }
        }
        compose.onNodeWithText("Inbox").assertIsDisplayed()
        compose.onNodeWithText("Projects").assertIsDisplayed()
        compose.onNodeWithTag("nav-activity").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(Destination.ACTIVITY, selected) }
        compose.onNodeWithTag("nav-chats").assertIsSelected()
        compose.onNodeWithTag("nav-board").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(Destination.BOARD, selected) }
        compose.onNodeWithTag("nav-tools").assertIsDisplayed().performClick()
        compose.runOnIdle { assertTrue(toolsOpened) }
        listOf("Machines", "Terminal", "Files", "Schedules", "Screens", "Settings", "Worktrees").forEach {
            compose.onNodeWithText(it).assertDoesNotExist()
        }
    }

    @Test fun navigationRailShowsEveryDestinationAndSettingsWithoutTools() {
        var selected: Destination? = null
        var settingsOpened = false
        compose.setContent {
            DieterTheme {
                DieterNavigationRail(
                    selected = Destination.CHATS,
                    onSelect = { selected = it },
                    projectSurfacesEnabled = true,
                    onSettings = { settingsOpened = true },
                    onCreate = {},
                )
            }
        }

        (primaryNavigationItems.map { it.destination } +
            listOf(Destination.MACHINES, Destination.TERMINALS, Destination.FILES, Destination.SCHEDULES, Destination.SCREENS)).forEach {
            compose.onNodeWithTag("nav-${it.name.lowercase()}").assertIsDisplayed().assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(it, selected) }
        }
        compose.onNodeWithTag("nav-settings").assertIsDisplayed().assertIsEnabled().performClick()
        compose.runOnIdle { assertTrue(settingsOpened) }
        compose.onNodeWithTag("nav-tools").assertDoesNotExist()
    }

    @Test fun navigationRailDisablesProjectDestinationsWithoutAnAvailableProject() {
        compose.setContent {
            DieterTheme {
                DieterNavigationRail(
                    selected = Destination.CHATS,
                    onSelect = {},
                    projectSurfacesEnabled = false,
                    onSettings = {},
                    onCreate = {},
                )
            }
        }

        compose.onNodeWithTag("nav-files").assertIsNotEnabled()
        compose.onNodeWithTag("nav-schedules").assertIsNotEnabled()
        compose.onNodeWithTag("nav-terminals").assertIsEnabled()
        compose.onNodeWithTag("nav-machines").assertIsEnabled()
        compose.onNodeWithTag("nav-screens").assertIsEnabled()
    }

    @Test fun toolsOfferExistingDestinationsAndSettings() {
        var selected: Destination? = null
        var settingsOpened = false
        compose.setContent {
            DieterTheme {
                DieterToolsSheet(
                    selected = Destination.BOARD,
                    projectSurfacesEnabled = true,
                    onSelect = { selected = it },
                    onSettings = { settingsOpened = true },
                    onDismiss = {},
                )
            }
        }
        listOf(Destination.MACHINES, Destination.TERMINALS, Destination.FILES, Destination.SCHEDULES, Destination.SCREENS).forEach {
            compose.onNodeWithTag("tool-${it.name.lowercase()}").assertIsDisplayed().assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(it, selected) }
        }
        compose.onNodeWithTag("tool-settings").assertIsDisplayed().performClick()
        compose.runOnIdle { assertTrue(settingsOpened) }
        compose.onNodeWithText("Worktrees").assertDoesNotExist()
    }

    @Test fun projectToolsAreDisabledWithoutAnAvailableProject() {
        var selected: Destination? = null
        var settingsOpened = false
        compose.setContent {
            DieterTheme {
                DieterToolsSheet(
                    selected = Destination.CHATS,
                    projectSurfacesEnabled = false,
                    onSelect = { selected = it },
                    onSettings = { settingsOpened = true },
                    onDismiss = {},
                )
            }
        }
        compose.onNodeWithTag("tool-files").assertIsNotEnabled().performClick()
        compose.onNodeWithTag("tool-schedules").assertIsNotEnabled().performClick()
        compose.runOnIdle { assertEquals(null, selected) }
        compose.onNodeWithTag("tool-machines").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(Destination.MACHINES, selected) }
        compose.onNodeWithTag("tool-screens").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(Destination.SCREENS, selected) }
        compose.onNodeWithTag("tool-terminals").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(Destination.TERMINALS, selected) }
        compose.onNodeWithTag("tool-settings").assertIsEnabled().performClick()
        compose.runOnIdle { assertTrue(settingsOpened) }
    }

    @Test fun sheetRetainsPrimaryNavigationAndCanBeClosed() {
        var selected: Destination? = null
        var dismissed = false
        compose.setContent {
            DieterTheme {
                DieterToolsSheet(
                    selected = Destination.SCREENS,
                    projectSurfacesEnabled = false,
                    onSelect = { selected = it },
                    onSettings = {},
                    onDismiss = { dismissed = true },
                )
            }
        }
        compose.onNodeWithTag("nav-tools").assertIsSelected()
        compose.onNodeWithTag("nav-chats").performClick()
        compose.runOnIdle { assertEquals(Destination.CHATS, selected) }
        compose.onNodeWithTag("nav-board").performClick()
        compose.runOnIdle { assertEquals(Destination.BOARD, selected) }
        compose.onNodeWithTag("nav-tools").performClick()
        compose.runOnIdle { assertTrue(dismissed) }
    }

    @Test fun largeTextKeepsToolsReachableByScrolling() {
        var settingsOpened = false
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                DieterTheme {
                    DieterToolsSheet(
                        selected = Destination.CHATS,
                        projectSurfacesEnabled = true,
                        onSelect = {},
                        onSettings = { settingsOpened = true },
                        onDismiss = {},
                    )
                }
            }
        }
        compose.onNodeWithTag("tools-grid").performScrollToNode(hasTestTag("tool-settings"))
        compose.onNodeWithTag("tool-settings").assertIsDisplayed().performClick()
        compose.runOnIdle { assertTrue(settingsOpened) }
        compose.onNodeWithTag("nav-tools").assertIsDisplayed()
    }
}
