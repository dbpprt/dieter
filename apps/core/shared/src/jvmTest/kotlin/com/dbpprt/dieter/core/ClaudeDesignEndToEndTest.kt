package com.dbpprt.dieter.core

import com.dbpprt.dieter.client.v1.ClaudeDesignAccess
import com.dbpprt.dieter.client.v1.ClaudeDesignCode
import com.dbpprt.dieter.client.v1.ClaudeDesignCommand
import com.dbpprt.dieter.client.v1.ClaudeDesignSelect
import com.dbpprt.dieter.client.v1.ClaudeDesignSignIn
import com.dbpprt.dieter.client.v1.ClaudeDesignSlice
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Step
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Claude Design as every client drives it through the core: the isolated daemon's fixture stands in
 * for Claude Code, so no test reaches claude.ai or the operator's Claude login.
 */
class ClaudeDesignEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    @Test
    fun aClientSignsInWithTheManualCodeAndAllowsClaudeDesign() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val api = ClientApi(runtime)
        val slice = MutableStateFlow<ClaudeDesignSlice?>(null)
        val watch =
            api.observe(Slice.SLICE_CLAUDE_DESIGN, "") {
                slice.value = Update.ADAPTER.decode(it.encode()).claude_design
            }
        suspend fun design(command: ClaudeDesignCommand) =
            api.dispatch(Command(claude_design = command))

        design(ClaudeDesignCommand(select = ClaudeDesignSelect(daemon_id = fixture.daemonId)))
        slice.await(30.seconds, describe = { "status: ${slice.value}" }) {
            it?.status?.available == true
        }
        assertEquals("Not signed in", slice.value!!.headline)
        assertTrue(slice.value!!.can_sign_in)
        assertFalse(slice.value!!.status!!.access_enabled)

        design(ClaudeDesignCommand(sign_in = Step()))
        slice.await(30.seconds, describe = { "sign-in: ${slice.value}" }) {
            it?.sign_in?.phase == ClaudeDesignSignIn.Phase.PHASE_WAITING
        }
        val waiting = slice.value!!
        assertTrue(
            waiting.sign_in!!.open_url.startsWith("https://claude.invalid/design/sign-in"),
            waiting.toString(),
        )
        assertTrue(waiting.sign_in!!.active)
        assertFalse(waiting.can_sign_in, "one sign-in runs at a time")

        design(ClaudeDesignCommand(submit_code = ClaudeDesignCode(code = " DIETER-FIXTURE-CODE ")))
        slice.await(30.seconds, describe = { "signed in: ${slice.value}" }) {
            it?.sign_in?.phase == ClaudeDesignSignIn.Phase.PHASE_SUCCEEDED &&
                it.status?.signed_in == true
        }
        assertEquals("Signed in", slice.value!!.headline)
        assertTrue(slice.value!!.can_change_access)

        design(ClaudeDesignCommand(set_access = ClaudeDesignAccess(enabled = true)))
        slice.await(30.seconds, describe = { "access on: ${slice.value}" }) {
            it?.status?.access_enabled == true && !it.access_pending
        }
        design(
            ClaudeDesignCommand(
                set_access = ClaudeDesignAccess(enabled = false, revoke_grant = true)
            )
        )
        slice.await(30.seconds, describe = { "access off: ${slice.value}" }) {
            it?.status?.access_enabled == false && !it.access_pending
        }
        assertEquals("", slice.value!!.error)

        // Leaving the settings ends the surface; the daemon keeps what it stored.
        design(ClaudeDesignCommand(select = ClaudeDesignSelect()))
        slice.await(10.seconds, describe = { "cleared: ${slice.value}" }) {
            it?.daemon_id == "" && it.status == null
        }
        watch.close()
    }

    @Test
    fun aCodeStillFinishesTheSignInAfterTheStreamDropped() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val api = ClientApi(runtime)
        val slice = MutableStateFlow<ClaudeDesignSlice?>(null)
        val watch =
            api.observe(Slice.SLICE_CLAUDE_DESIGN, "") {
                slice.value = Update.ADAPTER.decode(it.encode()).claude_design
            }
        suspend fun design(command: ClaudeDesignCommand) =
            api.dispatch(Command(claude_design = command))

        design(ClaudeDesignCommand(select = ClaudeDesignSelect(daemon_id = fixture.daemonId)))
        slice.await(30.seconds, describe = { "status: ${slice.value}" }) {
            it?.status?.available == true
        }
        design(ClaudeDesignCommand(sign_in = Step()))
        slice.await(30.seconds, describe = { "sign-in: ${slice.value}" }) {
            it?.sign_in?.phase == ClaudeDesignSignIn.Phase.PHASE_WAITING
        }

        // As when a phone leaves for the browser: the machine's connection drops.
        runtime.onCore { runtime.sessions.invalidate(fixture.daemonId) }
        assertEquals(
            ClaudeDesignSignIn.Phase.PHASE_WAITING,
            slice.value!!.sign_in!!.phase,
            "the sign-in keeps waiting for its code",
        )

        design(ClaudeDesignCommand(submit_code = ClaudeDesignCode(code = "DIETER-FIXTURE-CODE")))
        slice.await(30.seconds, describe = { "signed in: ${slice.value}" }) {
            it?.sign_in?.phase == ClaudeDesignSignIn.Phase.PHASE_SUCCEEDED &&
                it.status?.signed_in == true
        }
        watch.close()
    }
}
