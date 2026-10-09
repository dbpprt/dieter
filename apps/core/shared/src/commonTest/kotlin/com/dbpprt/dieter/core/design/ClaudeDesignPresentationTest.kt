package com.dbpprt.dieter.core.design

import com.dbpprt.dieter.api.v1.ClaudeDesignStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ClaudeDesignPresentationTest {
    private val ready =
        ClaudeDesignStatus(
            available = true,
            can_sign_in = true,
            runtime_ready = true,
            claude_code_version = "2.1.285",
        )

    @Test
    fun statusReadsTheSameOnEveryClient() {
        assertEquals(
            "Checking…",
            ClaudeDesignPresentation.of(ClaudeDesignView(daemonId = "d", loading = true)).headline,
        )
        assertEquals(
            "Status unavailable",
            ClaudeDesignPresentation.of(ClaudeDesignView(daemonId = "d", error = "offline"))
                .headline,
        )
        val unavailable =
            ClaudeDesignPresentation.of(
                ClaudeDesignView(
                    daemonId = "d",
                    status = ClaudeDesignStatus(runtime_ready = true, reason = "Not enabled."),
                )
            )
        assertEquals("Unavailable" to "Not enabled.", unavailable.headline to unavailable.detail)
        assertFalse(unavailable.canSignIn || unavailable.canChangeAccess)
        val notInstalled =
            ClaudeDesignPresentation.of(
                ClaudeDesignView(
                    daemonId = "d",
                    status =
                        ClaudeDesignStatus(can_sign_in = true, claude_code_version = "2.1.285"),
                )
            )
        assertEquals("Not signed in", notInstalled.headline)
        assertTrue(notInstalled.canSignIn && "2.1.285" in notInstalled.detail)
        val signedIn =
            ClaudeDesignPresentation.of(
                ClaudeDesignView(daemonId = "d", status = ready.copy(signed_in = true))
            )
        assertEquals("Signed in", signedIn.headline)
        assertTrue(signedIn.canChangeAccess)
        assertFalse(
            ClaudeDesignPresentation.of(
                    ClaudeDesignView(daemonId = "d", status = ready, accessPending = true)
                )
                .canChangeAccess
        )
    }

    @Test
    fun onlyThisDevicesMachineFinishesTheBrowserSignInByItself() {
        val waiting =
            ClaudeDesignSignIn(
                id = "s",
                phase = ClaudeDesignSignInPhase.WAITING,
                url = "https://claude.com/auto",
                manualUrl = "https://claude.com/manual",
            )
        val local =
            ClaudeDesignPresentation.of(
                ClaudeDesignView(daemonId = "d", status = ready, signIn = waiting, local = true)
            )
        assertEquals("https://claude.com/auto", local.openUrl)
        assertFalse(local.codeRequired)
        assertFalse(local.canSignIn, "one sign-in at a time")
        val remote =
            ClaudeDesignPresentation.of(
                ClaudeDesignView(daemonId = "d", status = ready, signIn = waiting, local = false)
            )
        assertEquals("https://claude.com/manual" to true, remote.openUrl to remote.codeRequired)
        val manualFirst =
            ClaudeDesignPresentation.of(
                ClaudeDesignView(
                    daemonId = "d",
                    status = ready,
                    signIn = waiting.copy(manualFirst = true),
                    local = true,
                )
            )
        assertTrue(manualFirst.codeRequired)
        val finished =
            ClaudeDesignPresentation.of(
                ClaudeDesignView(
                    daemonId = "d",
                    status = ready,
                    signIn = waiting.copy(phase = ClaudeDesignSignInPhase.FAILED),
                )
            )
        assertTrue(finished.canSignIn, "a failed sign-in can be retried")
    }
}
