package com.dbpprt.dieter.ui

import android.Manifest
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.test.espresso.Espresso.closeSoftKeyboard
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import androidx.lifecycle.ViewModelProvider
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.api.v1.ListTerminalsRequest
import com.dbpprt.dieter.api.v1.Terminal
import com.dbpprt.dieter.api.v1.TerminalRef
import com.dbpprt.dieter.e2e.IsolatedCore
import com.dbpprt.dieter.e2e.Evidence
import java.security.MessageDigest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** Actual terminal surface → view model/controllers → authenticated gateway → shell. */
@RunWith(AndroidJUnit4::class)
class TerminalInputEndToEndTest {
    private val compose = createAndroidComposeRule<MainActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
        .around(compose).around(com.dbpprt.dieter.e2e.FailureEvidence())

    @Test
    fun visibleTerminalDeliversChunkedInputAndEditingBytes() {
        val container = (compose.activity.application as DieterApplication).container
        val connected = IsolatedCore.connect(container)
        val project = connected.projects.first { candidate -> connected.boards[candidate.id].orEmpty().isNotEmpty() }
        val daemonId = IsolatedCore.daemonId(container)
        fun terminals(): List<Terminal> = runBlocking {
            container.core.onMachine(daemonId) { client ->
                (client.ListTerminals().execute(ListTerminalsRequest()).terminals +
                    client.ListTerminals().execute(ListTerminalsRequest(project_id = project.id)).terminals).distinctBy { it.id }
            }
        }
        val name = "android-input-e2e"
        try {
            compose.onNodeWithTag("nav-tools").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithTag("tool-terminals").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("tool-terminals").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithTag("new-terminal").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("terminal-machine").performClick()
            compose.onNodeWithTag("terminal-machine-$daemonId").performClick()
            compose.waitUntil(10_000) {
                ViewModelProvider(compose.activity)[DieterViewModel::class.java].state.value.terminalWorkspace.scope?.daemonId == daemonId
            }
            compose.onNodeWithTag("new-terminal").performClick()
            compose.onNodeWithTag("terminal-name").performTextReplacement(name)
            closeSoftKeyboard()
            compose.onNodeWithTag("terminal-shell-sh").performScrollTo().performClick()
            compose.onNodeWithTag("create-terminal").performScrollTo().performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithTag("terminal-canvas").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("terminal-canvas").assertIsDisplayed()

            // The escaped marker cannot pass by merely displaying the echoed command.
            input("PS1=; PS2=; stty -echo; printf '\\101NDROID_INPUT_READY\\n'\n")
            awaitOutput("ANDROID_INPUT_READY")
            // Read bytes in raw mode: an interactive shell's canonical input queue
            // can discard a large paste before parsing its individual lines.
            // The receiver checks the actual app/controller/gateway/PTY byte stream.
            val burst = "abcdef0123456789".repeat(5248)
            val digest = MessageDigest.getInstance("SHA-256").digest(burst.toByteArray())
                .joinToString("") { "%02x".format(it) }
            val receiver = """
                import os,termios,tty,hashlib
                saved=termios.tcgetattr(0)
                tty.setraw(0)
                print("ANDROID_RAW_"+"READY",flush=True)
                remaining=${burst.length}
                data=b""
                while remaining:
                    chunk=os.read(0,remaining)
                    data+=chunk
                    remaining-=len(chunk)
                termios.tcsetattr(0,termios.TCSANOW,saved)
                print("ANDROID_INPUT_"+"BURST_OK:"+str(len(data))+":"+hashlib.sha256(data).hexdigest(),flush=True)
            """.trimIndent()
            input("python3 -c '$receiver'\n")
            awaitOutput("ANDROID_RAW_READY")
            assertTrue(burst.toByteArray().size > 64 * 1024)
            input(burst)
            awaitOutput("ANDROID_INPUT_BURST_OK:${burst.length}:$digest")
            input("printf '%s\\n' ANDROID_INPUT_EDIT_OKx\u007f\n")
            awaitOutput("ANDROID_INPUT_EDIT_OK")
            val text = transcript()
            assertFalse(text.contains("ANDROID_INPUT_EDIT_OKx"))
            assertEquals(1, Regex("ANDROID_INPUT_BURST_OK").findAll(text).count())

            val terminals = terminals().filter { it.name == name }
            assertEquals(1, terminals.size)
            assertEquals("running", terminals.single().status)
            Evidence.display("terminal-input-e2e.png")
        } finally {
            terminals().filter { it.name == name }.forEach { terminal ->
                runBlocking { container.core.onMachine(daemonId) { it.CloseTerminal().execute(TerminalRef(terminal_id = terminal.id)) } }
            }
        }
    }

    private fun input(text: String) = compose.runOnIdle {
        requireNotNull(findTerminal(compose.activity.window.decorView))
            .onCreateInputConnection(EditorInfo()).commitText(text, 1)
    }

    private fun transcript(): String = compose.runOnIdle {
        requireNotNull(findTerminal(compose.activity.window.decorView)).transcriptForTesting()
    }

    private fun awaitOutput(marker: String) {
        try {
            compose.waitUntil(20_000) { transcript().contains(marker) }
        } catch (error: Throwable) {
            val state = compose.runOnIdle { ViewModelProvider(compose.activity)[DieterViewModel::class.java].state.value }
            throw AssertionError("Missing $marker; terminal error=${state.error}; transcript=${transcript()}", error)
        }
    }

    private fun findTerminal(view: View): RemoteTerminalView? {
        if (view is RemoteTerminalView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) findTerminal(view.getChildAt(index))?.let { return it }
        return null
    }
}
