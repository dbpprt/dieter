package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.screens.ScreenController
import com.dbpprt.dieter.ui.theme.DieterTheme
import kotlinx.coroutines.awaitCancellation
import org.junit.Rule
import org.junit.Test

class ScreenCapabilityPickerTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun unsupportedLinuxHostIsVisibleButCannotStartScreenSession() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val machines = listOf(
            EndpointConnection(
                id = "linux",
                label = "Linux host",
                address = "isolated",
                daemonId = "daemon-linux",
                remoteDesktopReady = false,
                remoteDesktopReason = "Native screen sharing is currently supported on macOS only",
                remoteDesktopPlatform = "linux",
            ),
            EndpointConnection(
                id = "mac",
                label = "Mac host",
                address = "isolated",
                daemonId = "daemon-mac",
                remoteDesktopReady = true,
                remoteDesktopPlatform = "darwin",
            ),
        )
        compose.setContent {
            DieterTheme {
                ScreenWorkspace(
                    machines = machines,
                    padding = PaddingValues(),
                    controller = androidx.compose.runtime.remember { ScreenController(context) },
                    openConnection = { awaitCancellation() },
                )
            }
        }

        compose.onNodeWithTag("screen-machine").performClick()
        compose.onNodeWithTag("screen-machine-linux").assertIsNotEnabled()
        compose.onNodeWithTag("screen-machine-mac").assertIsEnabled().performClick()
        compose.onNodeWithTag("screen-connect").assertIsEnabled()
    }
}
