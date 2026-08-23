package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.test.junit4.v2.createComposeRule
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class RemoteTerminalViewTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun vtRendererRunsWithoutTheUnusedLocalProcessJniBridge() {
        lateinit var terminal: RemoteTerminalView
        var input = byteArrayOf()
        composeRule.setContent {
            DieterTheme {
                AndroidView(
                    factory = { context ->
                        RemoteTerminalView(context).also { view ->
                            terminal = view
                            view.onInput = { input += it }
                            view.applyScreen(
                                TerminalScreenState(
                                    "\u001B[32mANDROID_RENDER_OK\u001B[0m\r\n".encodeToByteArray(),
                                    resetRevision = 1,
                                ),
                            )
                        }
                    },
                    modifier = Modifier.size(width = 320.dp, height = 180.dp),
                )
            }
        }

        composeRule.runOnIdle {
            assertTrue(terminal.transcriptForTesting().contains("ANDROID_RENDER_OK"))
            assertTrue(terminal.cursorVisibleForTesting())
            terminal.sendBytes("echo input\n".encodeToByteArray())
            assertTrue(input.decodeToString().contains("echo input"))
            assertTrue(terminal.width > 0 && terminal.height > 0)
        }
        composeRule.waitUntil(timeoutMillis = 2_500) {
            terminal.cursorBlinkTransitionsForTesting() >= 2
        }
        composeRule.runOnIdle {
            assertTrue(terminal.cursorBlinkTransitionsForTesting() >= 2)
            terminal.sendBytes("cursor wakes\n".encodeToByteArray())
            assertTrue(terminal.cursorVisibleForTesting())
        }
    }
}
