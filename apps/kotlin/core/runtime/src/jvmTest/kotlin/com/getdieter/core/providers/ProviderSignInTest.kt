package com.getdieter.core.providers

import com.getdieter.api.v1.ProviderIdentity
import com.getdieter.api.v1.ProviderLoginChallenge
import com.getdieter.api.v1.ProviderLoginFlow
import com.getdieter.api.v1.ProviderLoginInput
import com.getdieter.api.v1.ProviderLoginPhase
import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.box
import com.getdieter.core.providers.ProviderFixtures.kv
import com.getdieter.core.providers.ProviderFixtures.laptop
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderFixtures.mac
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.SilentLogger
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

class ProviderSignInTest {
    private val macDaemon = FakeProviderDaemon("mac")
    private val boxDaemon = FakeProviderDaemon("box")
    private val accounts = ProviderAccounts()
    private var ids = 0

    init {
        accounts.apply(
            ProviderRecords.decode(
                kv(
                    account(CLAUDE_WORK, "claude", "Work"),
                    account(CHATGPT_TEAM, "chatgpt", "Team"),
                    account("pa_hosthosthosthosthosthosth", "claude", "Host", method = "host"),
                )
            ),
            listOf(mac, box, laptop),
        )
    }

    private fun TestScope.signIn() =
        ProviderSignIn(
            accounts,
            FakeProviderFleet(macDaemon, boxDaemon),
            backgroundScope,
            SilentLogger,
            newId = { "s${++ids}" },
        )

    private fun session(id: String) = accounts.view.value.session(id)!!

    /** Runs the sign-ins (background work) past every retry delay. */
    private fun TestScope.settle() {
        advanceTimeBy(1.minutes)
        runCurrent()
    }

    @Test
    fun aDeviceCodeChallengeRefreshesUntilTheSignInSucceeds() = runTest {
        boxDaemon.challenge =
            ProviderLoginChallenge(
                open_url = "https://auth.openai.com/codex/device",
                user_code = "AAAA-1111",
                expires_at = "2026-11-14T12:15:00Z",
                expects = ProviderLoginInput.PROVIDER_LOGIN_INPUT_NONE,
            )
        val signIn = signIn()
        val id = signIn.start(CHATGPT_TEAM, "box", "device_code")
        runCurrent()
        assertEquals(
            ProviderLoginFlow.PROVIDER_LOGIN_FLOW_DEVICE_CODE,
            boxDaemon.starts.single().flow,
        )
        assertEquals(CHATGPT_TEAM, boxDaemon.starts.single().account_id)
        assertEquals("login-box", boxDaemon.watches.single().login_id)
        assertEquals(SignInPhases.WAITING, session(id).phase)
        assertEquals("AAAA-1111", session(id).challenge?.user_code)
        assertEquals(id, signIn.start(CHATGPT_TEAM, "box"), "one open session per machine")

        // The device code expired and the daemon issued a new one.
        boxDaemon.emit(
            boxDaemon.login(
                ProviderLoginPhase.PROVIDER_LOGIN_PHASE_WAITING,
                CHATGPT_TEAM,
                {
                    it.copy(challenge = it.challenge?.copy(user_code = "BBBB-2222"))
                },
            )
        )
        runCurrent()
        assertEquals("BBBB-2222", session(id).challenge?.user_code)

        boxDaemon.emit(
            boxDaemon.login(
                ProviderLoginPhase.PROVIDER_LOGIN_PHASE_SUCCEEDED,
                CHATGPT_TEAM,
                {
                    it.copy(identity = ProviderIdentity(email = "team@corp.com"))
                },
            )
        )
        settle()
        assertEquals(SignInPhases.SUCCEEDED, session(id).phase)
        assertEquals("team@corp.com", session(id).email)
        // A later frame cannot move a finished session.
        boxDaemon.emit(boxDaemon.login(ProviderLoginPhase.PROVIDER_LOGIN_PHASE_FAILED))
        settle()
        assertEquals(SignInPhases.SUCCEEDED, session(id).phase, "it keeps its final state")

        signIn.dismiss(id)
        settle()
        assertNull(accounts.view.value.session(id))
        assertTrue(boxDaemon.cancels.isEmpty(), "a finished sign-in is not canceled")
    }

    @Test
    fun aPastedCodeOrCallbackAddressGoesToTheSigningMachine() = runTest {
        val signIn = signIn()
        val id = signIn.start(CLAUDE_WORK, "box", "paste_code")
        runCurrent()
        assertEquals("code", SignInPhases.expects(session(id).challenge?.expects))
        signIn.submit(id, code = "  abc#123  ", callbackUrl = null)
        assertEquals("abc#123", boxDaemon.submits.single().code)
        assertEquals("login-box", boxDaemon.submits.single().login_id)
        assertEquals(SignInPhases.COMPLETING, session(id).phase)
        signIn.submit(id, code = null, callbackUrl = "http://localhost:1455/auth/callback?code=x")
        assertEquals(
            "http://localhost:1455/auth/callback?code=x",
            boxDaemon.submits.last().callback_url,
        )
        assertFailsWith<CoreException> { signIn.submit(id, code = " ", callbackUrl = null) }
        assertFailsWith<CoreException> { signIn.submit("unknown", code = "x", callbackUrl = null) }
        assertTrue(macDaemon.submits.isEmpty())
    }

    @Test
    fun cancelingStopsTheWatchAndTellsTheMachine() = runTest {
        val signIn = signIn()
        val id = signIn.start(CLAUDE_WORK, "box")
        runCurrent()
        signIn.cancel(id)
        runCurrent()
        assertEquals(SignInPhases.CANCELED, session(id).phase)
        assertEquals(listOf("login-box"), boxDaemon.cancels)
        boxDaemon.emit(boxDaemon.login(ProviderLoginPhase.PROVIDER_LOGIN_PHASE_SUCCEEDED))
        settle()
        assertEquals(SignInPhases.CANCELED, session(id).phase)

        // Dismissing a live session cancels it too.
        val live = signIn.start(CLAUDE_WORK, "mac")
        runCurrent()
        signIn.dismiss(live)
        settle()
        assertNull(accounts.view.value.session(live))
        assertEquals(listOf("login-mac"), macDaemon.cancels)
    }

    @Test
    fun signingInOnAllMachinesWalksEveryOnlineMachineWithoutASignIn() = runTest {
        accounts.apply(
            ProviderRecords.decode(
                kv(
                    account(CLAUDE_WORK, "claude", "Work"),
                    login(CLAUDE_WORK, "laptop", state = ProviderKinds.SIGNED_OUT),
                )
            ),
            listOf(mac, box, laptop),
        )
        val signIn = signIn()
        val id = signIn.startAll(CLAUDE_WORK)
        runCurrent()
        assertEquals("mac", session(id).daemonId, "this device's machine first")
        assertEquals(listOf("box"), session(id).remaining, "the offline laptop is left out")
        macDaemon.emit(macDaemon.login(ProviderLoginPhase.PROVIDER_LOGIN_PHASE_SUCCEEDED))
        runCurrent()
        assertEquals("box", session(id).daemonId)
        assertEquals(emptyList(), session(id).remaining)
        assertEquals(SignInPhases.WAITING, session(id).phase)
        assertEquals(1, boxDaemon.starts.size)
        boxDaemon.emit(boxDaemon.login(ProviderLoginPhase.PROVIDER_LOGIN_PHASE_SUCCEEDED))
        settle()
        assertEquals(SignInPhases.SUCCEEDED, session(id).phase)

        // A failure stops the walk where it happened.
        val again = signIn.startAll(CLAUDE_WORK)
        runCurrent()
        macDaemon.emit(
            macDaemon.login(
                ProviderLoginPhase.PROVIDER_LOGIN_PHASE_FAILED,
                "",
                {
                    it.copy(error_message = "The code was wrong")
                },
            )
        )
        settle()
        assertEquals(SignInPhases.FAILED, session(again).phase)
        assertEquals("The code was wrong", session(again).error)
        assertEquals("mac", session(again).daemonId)
        assertEquals(listOf("box"), session(again).remaining)
        assertEquals(1, boxDaemon.starts.size)
    }

    @Test
    fun aBrokenWatchReopensAndAFailedStartFailsTheSession() = runTest {
        val signIn = signIn()
        val id = signIn.start(CLAUDE_WORK, "box")
        runCurrent()
        boxDaemon.streams.last().close(IOException("stream reset"))
        settle()
        assertEquals(2, boxDaemon.watches.size, "the watch opened again")
        assertEquals(SignInPhases.WAITING, session(id).phase)
        repeat(ProviderSignIn.MAX_WATCH_ATTEMPTS + 1) {
            boxDaemon.streams.last().close(IOException("stream reset"))
            settle()
        }
        assertEquals(SignInPhases.FAILED, session(id).phase)

        macDaemon.before = { method ->
            if (method == "StartProviderLogin")
                throw GrpcException(GrpcStatus.FAILED_PRECONDITION, "Claude Code is not installed")
        }
        val failed = signIn.start(CLAUDE_WORK, "mac")
        settle()
        assertEquals(SignInPhases.FAILED, session(failed).phase)
        assertEquals("Claude Code is not installed", session(failed).error)
    }

    @Test
    fun onlyReachableMachinesAndSignInMethodsStart() = runTest {
        val signIn = signIn()
        assertFailsWith<CoreException> { signIn.start(CLAUDE_WORK, "laptop") }
        assertFailsWith<CoreException> { signIn.start("pa_hosthosthosthosthosthosth", "box") }
        assertFailsWith<CoreException> { signIn.start("pa_missing", "box") }
        assertFailsWith<CoreException> { signIn.start(CLAUDE_WORK, "box", "carrier_pigeon") }
        assertTrue(accounts.view.value.sessions.isEmpty())
    }
}
