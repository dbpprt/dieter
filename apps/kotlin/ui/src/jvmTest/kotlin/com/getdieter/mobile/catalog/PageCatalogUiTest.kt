@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.catalog

import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.test.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.store.*
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlinx.coroutines.Dispatchers

/**
 * Every primary page at phone size, light and dark, against the fixture: a smoke test that each
 * renders, and with screenshots enabled (`dieter.screenshots`) a catalog for checking that the
 * pages share one list style.
 */
class PageCatalogUiTest {
    private fun DesktopComposeUiTest.shot(name: String) {
        val directory = File(System.getProperty("dieter.screenshots") ?: return, "catalog")
        waitForIdle()
        directory.mkdirs()
        val image = onAllNodes(isRoot()).onLast().captureToImage().toAwtImage()
        ImageIO.write(image, "png", File(directory, "$name.png"))
    }

    private fun catalog(appearance: String) =
        runDesktopComposeUiTest(width = 412, height = 915) {
            val core = DesktopFixture.core()
            val store = MobileStore(core, Dispatchers.Unconfined)
            store.layout.setInterfaceMode(InterfaceMode.TOUCH)
            store.theme.setAppearance(appearance)
            DesktopFixture.publish(core)
            DesktopFixture.publishBoard(core)
            setContent { MobileApp(store, desktopHost = false) }
            waitForIdle()
            try {
                for (tab in listOf("inbox", "mail", "projects", "chats")) {
                    onNodeWithTag("nav-$tab").performClick()
                    waitForIdle()
                    shot("$appearance-$tab")
                }
                onNodeWithTag("nav-more").performClick()
                waitForIdle()
                shot("$appearance-more")
                for (place in listOf("channels", "terminals", "settings")) {
                    if (onAllNodesWithTag("more-$place").fetchSemanticsNodes().isEmpty()) {
                        onNodeWithTag("nav-more").performClick()
                        waitForIdle()
                    }
                    runCatching {
                        onNodeWithTag("more-$place").performClick()
                        waitForIdle()
                        shot("$appearance-$place")
                    }
                    onNodeWithTag("nav-inbox").performClick()
                    waitForIdle()
                }
            } finally {
                store.close()
            }
        }

    @Test fun light() = catalog("light")

    @Test fun dark() = catalog("dark")
}
