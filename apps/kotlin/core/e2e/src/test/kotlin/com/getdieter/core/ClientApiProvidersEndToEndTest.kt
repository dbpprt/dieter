package com.getdieter.core

import com.getdieter.client.v1.Command
import com.getdieter.client.v1.ProviderAccountRef
import com.getdieter.client.v1.ProviderAccountRow
import com.getdieter.client.v1.ProviderCreate
import com.getdieter.client.v1.ProviderSessionRef
import com.getdieter.client.v1.ProviderSeverity
import com.getdieter.client.v1.ProviderSignInInput
import com.getdieter.client.v1.ProviderSignInStart
import com.getdieter.client.v1.ProvidersCommand
import com.getdieter.client.v1.ProvidersSlice
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Update
import com.getdieter.core.client.ClientApi
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Provider accounts over the real gateway and daemon, on the fixture's seeded accounts and its
 * deterministic sign-in backend: the slice shows the replicated accounts with their usage, a new
 * account signs in with a pasted code right after it was created, a ChatGPT reset credit is spent,
 * and a removed account leaves the slice.
 */
class ClientApiProvidersEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private fun ClientApi.providers(): MutableStateFlow<ProvidersSlice?> {
        val slice = MutableStateFlow<ProvidersSlice?>(null)
        observe(Slice.SLICE_PROVIDERS, "") { update ->
            Update.ADAPTER.decode(update.encode()).providers?.let { slice.value = it }
        }
        return slice
    }

    private fun ProvidersSlice?.account(id: String): ProviderAccountRow? =
        this?.groups?.flatMap { it.accounts }?.firstOrNull { it.id == id }

    private suspend fun ClientApi.providers(command: ProvidersCommand) =
        dispatch(Command(providers = command))

    @Test
    fun accountsSignInSpendResetsAndLeaveThroughTheCore() = e2e {
        val fixture = fixture(seeded = true)
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val api = ClientApi(runtime)
        val slice = api.providers()
        fun signedIn(row: ProviderAccountRow?) =
            row?.machines?.any { it.daemon_id == fixture.daemonId && it.state == "signed_in" } ==
                true

        // The seeded accounts arrive from the account replica with their usage.
        val seeded =
            slice.await(describe = { "seeded accounts: ${slice.value}" }) {
                signedIn(it.account(WORK)) &&
                    signedIn(it.account(PERSONAL)) &&
                    it.account(WORK)?.remaining == 62
            }
        assertEquals(listOf("claude", "chatgpt"), seeded!!.groups.map { it.provider })
        val work = seeded.account(WORK)!!
        assertEquals("Work", work.label)
        assertTrue(work.is_default)
        assertEquals("claude-code", work.method)
        assertEquals(listOf(62, 88), work.windows.map { it.remaining })
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_NORMAL, work.severity)
        assertTrue(work.usage_observed_at.isNotEmpty())
        val primary = work.machines.first { it.daemon_id == fixture.daemonId }
        assertEquals("Signed in", primary.state_label)
        assertTrue(primary.online)
        assertTrue(primary.can_sign_out)
        val personal = seeded.account(PERSONAL)!!
        assertEquals("Personal", personal.label)
        assertTrue(personal.is_default)
        assertEquals(59, personal.remaining)
        assertTrue(personal.can_reset)
        assertEquals("Reset usage limits (1 credit)", personal.reset_label)
        assertEquals(listOf("claude", "chatgpt"), seeded.summary!!.items.map { it.provider })

        // A new account signs in at once on the primary machine with the code Anthropic shows.
        val scratch =
            api.providers(
                    ProvidersCommand(
                        create = ProviderCreate(provider = "claude", label = "Scratch")
                    )
                )
                .provider_account!!
                .account_id
        val sessionId =
            api.providers(
                    ProvidersCommand(
                        sign_in =
                            ProviderSignInStart(account_id = scratch, daemon_id = fixture.daemonId)
                    )
                )
                .provider_sign_in!!
                .session_id
        val waiting =
            slice.await(describe = { "waiting sign-in: ${slice.value?.sessions}" }) { value ->
                value?.sessions?.any { it.id == sessionId && it.phase == "waiting" } == true
            }!!
        val session = waiting.sessions.first { it.id == sessionId }
        assertEquals("code", session.expects)
        assertEquals(scratch, session.account_id)
        assertEquals("Scratch", session.account_label)
        assertEquals("Sign in to Claude Code on ${session.machine}", session.title)
        assertTrue(session.open_url.startsWith("https://claude.ai/oauth/authorize"))
        assertEquals("Paste the code Anthropic shows you", session.instructions)
        api.providers(
            ProvidersCommand(
                submit = ProviderSignInInput(session_id = sessionId, code = "FIXTURE-CODE")
            )
        )
        slice.await(describe = { "signed in: ${slice.value?.sessions}" }) { value ->
            value?.sessions?.any { it.id == sessionId && it.phase == "succeeded" } == true
        }
        slice.await(describe = { "Scratch's login: ${slice.value.account(scratch)}" }) {
            signedIn(it.account(scratch))
        }
        api.providers(ProvidersCommand(dismiss = ProviderSessionRef(sessionId)))
        slice.await(describe = { "dismissed: ${slice.value?.sessions}" }) { value ->
            value != null && value.sessions.none { it.id == sessionId }
        }

        // Personal's reset credit is spent on the machine signed in to it.
        val reset =
            api.providers(ProvidersCommand(consume_reset = ProviderAccountRef(PERSONAL)))
                .provider_reset!!
        assertEquals(PERSONAL, reset.account_id)
        assertEquals("reset", reset.outcome)
        assertEquals("Usage limits were reset.", reset.message)

        // A removed account leaves the slice.
        api.providers(ProvidersCommand(remove = ProviderAccountRef(scratch)))
        slice.await(describe = { "removed: ${slice.value}" }) {
            it != null && it.account(scratch) == null
        }
        assertTrue(slice.value.account(WORK) != null, "the other accounts stay")
        assertEquals("", slice.value!!.error)
    }

    private companion object {
        const val WORK = "pa_fixtureworkaccount22222222"
        const val PERSONAL = "pa_fixturepersonalaccount2222"
    }
}
