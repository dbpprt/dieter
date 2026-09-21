package com.dbpprt.dieter.ui

import androidx.compose.runtime.CompositionLocalProvider
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
import androidx.compose.ui.unit.Density
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ScreenNavigationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun bottomBarKeepsOnlyChatsBoardsAndTools() {
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
        compose.onNodeWithTag("nav-chats").assertIsSelected()
        compose.onNodeWithTag("nav-board").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(Destination.BOARD, selected) }
        compose.onNodeWithTag("nav-tools").assertIsDisplayed().performClick()
        compose.runOnIdle { assertTrue(toolsOpened) }
        listOf("Terminal", "Files", "Schedules", "Screens", "Settings", "Worktrees").forEach {
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
            listOf(Destination.TERMINALS, Destination.FILES, Destination.SCHEDULES, Destination.SCREENS)).forEach {
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
        listOf(Destination.TERMINALS, Destination.FILES, Destination.SCHEDULES, Destination.SCREENS).forEach {
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
