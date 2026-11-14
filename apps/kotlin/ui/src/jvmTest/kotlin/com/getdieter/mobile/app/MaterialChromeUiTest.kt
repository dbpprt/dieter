@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.app

import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.navigation.MobileTab
import com.getdieter.mobile.store.MobileStore
import java.io.File
import javax.imageio.ImageIO
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers

class MaterialChromeUiTest {
    private val DpRect.centerY
        get() = (top + bottom) / 2

    private fun DesktopComposeUiTest.launch(tab: MobileTab): MobileStore {
        val core = DesktopFixture.core()
        val store = MobileStore(core, Dispatchers.Unconfined)
        store.theme.setAppearance("dark")
        DesktopFixture.publish(core)
        store.selectTab(tab)
        setContent { MobileApp(store) }
        waitForIdle()
        return store
    }

    private fun DesktopComposeUiTest.title(tab: MobileTab) =
        onNode(
            hasText(tab.title) and
                !hasAnyAncestor(hasTestTag("nav-${tab.name.lowercase()}")) and
                !hasTestTag("nav-${tab.name.lowercase()}")
        )

    private fun DesktopComposeUiTest.shot(name: String) {
        val directory = System.getProperty("dieter.screenshots") ?: return
        File(directory).mkdirs()
        ImageIO.write(
            onRoot().captureToImage().toAwtImage(),
            "png",
            File(directory, "$name.png"),
        )
    }

    @Test
    fun projectsTitleAndAddShareTheRailToolbar() =
        runDesktopComposeUiTest(width = 1200, height = 800) {
            val store = launch(MobileTab.PROJECTS)
            try {
                onNodeWithTag("rail-new").assertIsDisplayed()
                val heading = title(MobileTab.PROJECTS).getBoundsInRoot()
                val add = onNodeWithTag("chrome-projects-add").getBoundsInRoot()
                assertTrue(abs((heading.centerY - add.centerY).value) < 16f)
                onNodeWithText("2 projects").assertIsDisplayed()
                assertTrue(
                    onNodeWithText("Search projects and boards").getBoundsInRoot().top < 100.dp
                )
                shot("mobile-tablet-projects")
                onNodeWithTag("chrome-projects-add").performClick()
                onNodeWithText("New project").assertIsDisplayed()
                onNodeWithText("New folder").assertIsDisplayed()
            } finally {
                store.close()
            }
        }

    @Test
    fun chatsTitleAndOptionsShareTheRailToolbar() =
        runDesktopComposeUiTest(width = 1200, height = 800) {
            val store = launch(MobileTab.CHATS)
            try {
                onNodeWithTag("rail-new").assertIsDisplayed()
                val heading = title(MobileTab.CHATS).getBoundsInRoot()
                val options = onNodeWithTag("chrome-chats-menu").getBoundsInRoot()
                assertTrue(abs((heading.centerY - options.centerY).value) < 16f)
                assertTrue(onNodeWithText("Search chats").getBoundsInRoot().top < 100.dp)
                shot("mobile-tablet-chats")
                onNodeWithTag("chrome-chats-menu").performClick()
                onNodeWithText("Archived chats").performClick()
                onNodeWithText("Archived chats").assertIsDisplayed()
            } finally {
                store.close()
            }
        }

    @Test
    fun phoneKeepsItsLargeProjectsTitle() =
        runDesktopComposeUiTest(width = 390, height = 844) {
            val store = launch(MobileTab.PROJECTS)
            try {
                onNodeWithTag("rail-new").assertDoesNotExist()
                val heading = title(MobileTab.PROJECTS).getBoundsInRoot()
                val add = onNodeWithTag("chrome-projects-add").getBoundsInRoot()
                assertTrue(heading.top > add.bottom)
                shot("mobile-phone-projects")
            } finally {
                store.close()
            }
        }
}
