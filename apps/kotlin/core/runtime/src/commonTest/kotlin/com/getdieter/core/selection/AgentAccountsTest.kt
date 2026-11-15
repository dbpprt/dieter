package com.getdieter.core.selection

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.AgentChoice
import com.getdieter.core.client.ClientFailure
import com.getdieter.core.client.agentControlsState
import com.getdieter.core.client.choosing
import com.getdieter.core.client.providerNotice
import com.getdieter.core.client.rules.CreationExports
import com.getdieter.core.composition.Creation
import com.getdieter.core.composition.CreationInput
import com.getdieter.core.composition.CreationMemory
import com.getdieter.core.providers.AgentAccountRules
import com.getdieter.core.providers.AgentAccounts
import com.getdieter.core.providers.ProviderFixtures
import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_HOME
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.default
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderKinds
import com.getdieter.core.providers.ProvidersPresenter
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.storage.CoreStorage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class AgentAccountsTest {
    private val claude =
        Harness(
            id = "claude-code",
            name = "Claude Code",
            default_model = "opus",
            models = listOf(HarnessModel(id = "opus")),
        )
    private val codex =
        Harness(
            id = "codex",
            name = "Codex",
            default_model = "sol",
            models = listOf(HarnessModel("sol")),
        )
    private val pi =
        Harness(id = "pi", name = "Pi", default_model = "m", models = listOf(HarnessModel("m")))
    private val harnesses = listOf(claude, codex, pi)

    /** Work is signed in on box, Home only on mac; Work is Claude's default. */
    private val providers =
        ProviderFixtures.view(
            account(CLAUDE_WORK, "claude", "Work", email = "alice@corp.com"),
            account(CLAUDE_HOME, "claude", "Home"),
            account(CHATGPT_TEAM, "chatgpt", "Team"),
            default("claude", CLAUDE_WORK),
            login(CLAUDE_WORK, "box"),
            login(CLAUDE_HOME, "mac"),
            login(CLAUDE_HOME, "box", state = ProviderKinds.EXPIRED),
        )

    private fun controls(
        selection: HarnessSelection,
        daemonId: String = "box",
        last: String = "",
    ) =
        AgentControls(
            selection,
            harnesses,
            accounts = AgentAccountRules.forMachine(providers, daemonId, last),
        )

    @Test
    fun pickersListTheChosenAgentsProviderAccounts() {
        val onBox = controls(HarnessSelection("claude-code", "opus"))
        assertEquals(listOf(CLAUDE_HOME, CLAUDE_WORK), onBox.accountOptions.map { it.id })
        assertTrue(onBox.accountEnabled)
        assertEquals(CLAUDE_WORK, onBox.account?.id, "the provider default preselects")
        assertEquals("Work", onBox.accountLabel)
        assertFalse(onBox.accountBlocked)
        val state = agentControlsState(onBox)
        assertEquals(CLAUDE_WORK, state.selection?.account_id)
        assertEquals(listOf("Home", "Work"), state.accounts.map { it.label })
        val home = state.accounts.first()
        assertFalse(home.ready)
        assertEquals("Sign-in expired on box", home.reason)
        assertEquals("alice@corp.com", state.accounts.last().detail)
        assertTrue(state.accounts.last().is_default)
        assertTrue(state.account_enabled)
        assertEquals("Work", state.account_label)
        assertFalse(state.account_blocked)

        val codexControls = controls(HarnessSelection("codex", "sol"))
        assertEquals(listOf(CHATGPT_TEAM), codexControls.accountOptions.map { it.id })
        assertNull(codexControls.account, "no default and none signed in on box")
        assertEquals("Default account", codexControls.accountLabel)
        assertFalse(codexControls.accountBlocked, "the daemon resolves it")

        val piControls = controls(HarnessSelection("pi", "m"))
        assertTrue(piControls.accountOptions.isEmpty())
        assertFalse(piControls.accountEnabled)
        assertTrue(agentControlsState(piControls).accounts.isEmpty())
    }

    @Test
    fun theChosenAccountThenTheConversationsThenTheDefault() {
        val chosen = controls(HarnessSelection("claude-code", "opus", account_id = CLAUDE_HOME))
        assertEquals(CLAUDE_HOME, chosen.account?.id)
        assertTrue(chosen.accountBlocked, "Home's sign-in expired on box")
        val notice = providerNotice(chosen)!!
        assertEquals(CLAUDE_HOME, notice.account_id)
        assertEquals("box", notice.daemon_id)
        assertEquals("Home's sign-in expired on box", notice.title)
        assertEquals(AgentAccountRules.ACTION_SIGN_IN_AGAIN, notice.action)

        val last = controls(HarnessSelection("claude-code", "opus"), last = CLAUDE_HOME)
        assertEquals(CLAUDE_HOME, last.account?.id, "the conversation's last account comes next")

        val onMac = controls(HarnessSelection("claude-code", "opus"), daemonId = "mac")
        assertEquals(CLAUDE_WORK, onMac.account?.id)
        assertTrue(onMac.accountBlocked)
        val signIn = providerNotice(onMac)!!
        assertEquals("Work isn't signed in on mac", signIn.title)
        assertEquals(AgentAccountRules.ACTION_SIGN_IN, signIn.action)
        assertNull(providerNotice(controls(HarnessSelection("claude-code", "opus"))))

        // Without a default, the only account signed in on the machine is the one a send uses.
        val noDefault =
            AgentControls(
                HarnessSelection("claude-code", "opus"),
                harnesses,
                accounts =
                    AgentAccountRules.forMachine(
                        providers.copy(
                            accounts = providers.accounts.map { it.copy(isDefault = false) }
                        ),
                        "mac",
                    ),
            )
        assertEquals(CLAUDE_HOME, noDefault.account?.id)

        val removed = controls(HarnessSelection("claude-code", "opus", account_id = "pa_gone"))
        assertEquals("pa_gone", removed.missingAccount)
        assertNull(removed.account)
        assertTrue(removed.accountBlocked)
        assertEquals(AgentAccountRules.ACTION_CHOOSE_ACCOUNT, providerNotice(removed)!!.action)
    }

    @Test
    fun choosingAnAccountKeepsTheAgentAndValidatesTheAccount() {
        val open = controls(HarnessSelection("claude-code", "opus"))
        assertEquals(
            HarnessSelection("claude-code", "opus", account_id = CLAUDE_HOME),
            open.choosing(AgentChoice(account = CLAUDE_HOME)),
        )
        assertFailsWith<ClientFailure> { open.choosing(AgentChoice(account = CHATGPT_TEAM)) }
        assertFailsWith<ClientFailure> {
            controls(HarnessSelection("pi", "m")).choosing(AgentChoice(account = CLAUDE_WORK))
        }
        // A started conversation keeps its agent but may change accounts between turns.
        val started =
            AgentControls(
                HarnessSelection("claude-code", "opus"),
                harnesses,
                locked = true,
                accounts = AgentAccountRules.forMachine(providers, "box"),
            )
        assertTrue(started.accountEnabled)
        assertEquals(CLAUDE_HOME, started.choosing(AgentChoice(account = CLAUDE_HOME)).account_id)
        // Another agent starts without an account.
        val switched =
            open
                .copy(selection = open.choosingAccount(CLAUDE_HOME))
                .choosing(AgentChoice(provider = "codex"))
        assertEquals("", switched.account_id)
        // Other choices keep it.
        val withAccount = open.copy(selection = open.choosingAccount(CLAUDE_HOME))
        assertEquals(CLAUDE_HOME, withAccount.choosing(AgentChoice(effort = "high")).account_id)
    }

    @Test
    fun formsOutsideTheCoreJudgeAccountsFromTheProvidersSlice() {
        val slice = ProvidersPresenter.slice(providers, Instant.parse("2026-11-14T12:00:00Z"))
        val state =
            CreationExports.agentControls(
                HarnessSelection("claude-code", "opus"),
                HarnessCatalog(harnesses),
                locked = false,
                choice = AgentChoice(account = CLAUDE_HOME),
                providers = slice,
                daemonId = "mac",
            )
        assertEquals(CLAUDE_HOME, state.selection?.account_id)
        assertEquals(listOf(true, false), state.accounts.map { it.ready })
        assertEquals("Not signed in on mac", state.accounts.last().reason)
        assertEquals("alice@corp.com", state.accounts.last().detail)
        assertFalse(state.account_blocked)
        val none =
            CreationExports.agentControls(
                HarnessSelection("claude-code", "opus"),
                HarnessCatalog(harnesses),
                locked = false,
                choice = AgentChoice(),
                providers = com.getdieter.client.v1.ProvidersSlice(),
                daemonId = "",
            )
        assertTrue(none.accounts.isEmpty())
        assertEquals("Default account", none.account_label)
    }

    @Test
    fun sendsAndCreationsCarryTheAccount() {
        val card =
            Card(
                id = "c",
                provider = "claude-code",
                model = "opus",
                initial_prompt_sent_at = "2026-11-14T10:00:00Z",
                provider_account_id = CLAUDE_WORK,
            )
        val draft = HarnessSelection("claude-code", "opus", account_id = CLAUDE_HOME)
        assertEquals(CLAUDE_HOME, Selections.forSend(draft, card, harnesses).account_id)
        assertEquals("", Selections.forSend(null, card, harnesses).account_id, "keeps the card's")
        assertEquals(draft, Selections.pending(draft, card, harnesses))
        assertNull(
            Selections.pending(draft.copy(account_id = CLAUDE_WORK), card, harnesses),
            "the conversation already runs on Work",
        )
        val request =
            Creation.request(
                CreationInput(
                    project = Project(id = "p"),
                    chat = true,
                    prompt = "Hi",
                    selection = draft,
                )
            )
        assertEquals(CLAUDE_HOME, request.account_id)
        assertEquals(
            CLAUDE_HOME,
            Selections.resolve(draft, harnesses)?.account_id,
            "an account stays with its harness",
        )
        assertEquals("", Selections.resolve(draft.copy(provider = "gone"), harnesses)?.account_id)
    }

    @Test
    fun creationRemembersEachProvidersAccount() {
        val files = FakeFileSystem()
        val memory = CreationMemory(CoreStorage(files, "/state".toPath()), SilentLogger)
        memory.remember(HarnessSelection("claude-code", "opus", account_id = CLAUDE_HOME))
        memory.remember(HarnessSelection("codex", "sol", account_id = CHATGPT_TEAM))
        memory.remember(HarnessSelection("claude-code", "opus"))
        val restored = CreationMemory(CoreStorage(files, "/state".toPath()), SilentLogger)
        assertEquals(
            mapOf("claude" to CLAUDE_HOME, "chatgpt" to CHATGPT_TEAM),
            restored.state.value.accounts,
            "choosing no account keeps the last one",
        )
        assertEquals(CLAUDE_HOME, restored.selection(harnesses)?.account_id)
        assertEquals(
            "",
            CreationMemory(CoreStorage(files, "/other".toPath()), SilentLogger).account("pi"),
        )
        assertEquals(
            AgentAccounts(),
            AgentAccountRules.forMachine(com.getdieter.core.providers.ProvidersView(), null),
        )
    }
}
