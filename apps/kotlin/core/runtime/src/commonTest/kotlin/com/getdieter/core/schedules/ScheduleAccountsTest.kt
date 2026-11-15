package com.getdieter.core.schedules

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Checkout
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.Schedule
import com.getdieter.client.v1.AgentChoice
import com.getdieter.core.client.ClientFailure
import com.getdieter.core.client.agentControlsState
import com.getdieter.core.client.choosing
import com.getdieter.core.client.rules.CreationExports
import com.getdieter.core.composition.Creation
import com.getdieter.core.composition.CreationDestinations
import com.getdieter.core.composition.CreationInput
import com.getdieter.core.providers.ProviderFixtures
import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_HOME
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.default
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderKinds
import com.getdieter.core.providers.ProvidersPresenter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant

class ScheduleAccountsTest {
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
            models = listOf(HarnessModel(id = "sol")),
        )
    private val harnesses = listOf(claude, codex)
    private val boards = listOf(Board(id = "b1"))
    private val project =
        Project(id = "p", checkouts = listOf(Checkout(id = "k1", daemon_id = "box")))

    /**
     * Work is signed in on box, Home only on mac (its box sign-in expired); Work is the default.
     */
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

    private val stored =
        Schedule(
            id = "s",
            project_id = "p",
            checkout_id = "k1",
            board_id = "b1",
            provider = "claude-code",
            model = "opus",
            account_id = CLAUDE_HOME,
        )

    @Test
    fun draftsKeepTheSchedulesAccountAndTheEditorsChoice() {
        val editing = ScheduleDrafts.make(stored, "p", "UTC", boards, null, harnesses)
        assertEquals(CLAUDE_HOME, editing.account_id, "editing preselects the schedule's account")
        assertEquals(CLAUDE_HOME, ScheduleDrafts.selection(editing).account_id)
        val fresh = ScheduleDrafts.make(null, "p", "UTC", boards, null, harnesses)
        assertEquals("claude-code", fresh.provider)
        assertEquals("", fresh.account_id, "a new schedule runs on the provider default")
        val agentless =
            ScheduleDrafts.make(
                stored.copy(provider = "", model = ""),
                "p",
                "UTC",
                boards,
                null,
                harnesses,
            )
        assertEquals("", agentless.account_id, "a defaulted agent drops a stray account")

        val chosen =
            ScheduleDrafts.choose(
                editing,
                ScheduleDrafts.selection(editing).copy(account_id = CLAUDE_WORK),
            )
        assertEquals(CLAUDE_WORK, chosen.account_id)
        assertEquals(
            CLAUDE_WORK,
            ScheduleDrafts.normalized(chosen, "p", "k1").account_id,
            "the account is saved",
        )
        assertEquals("", ScheduleDrafts.choose(chosen, ScheduleDrafts.selection(fresh)).account_id)
    }

    @Test
    fun theEditorJudgesAccountsOnTheSchedulesMachine() {
        val draft = ScheduleDrafts.make(stored, "p", "UTC", boards, null, harnesses)
        // The mobile editor previews the draft's agent as a creation form on its checkout.
        val plan =
            Creation.plan(
                CreationInput(
                    project = project,
                    board = boards.first(),
                    checkoutId = draft.checkout_id,
                    selection = ScheduleDrafts.selection(draft),
                ),
                CreationDestinations(
                    online = setOf("box", "mac"),
                    catalogs = mapOf("box" to harnesses),
                    providers = providers,
                ),
            )
        assertEquals("box", plan.daemonId)
        val controls = plan.controls
        val state = agentControlsState(controls)
        assertEquals(CLAUDE_HOME, state.selection?.account_id)
        assertEquals(listOf(CLAUDE_HOME, CLAUDE_WORK), state.accounts.map { it.id })
        assertEquals(listOf(false, true), state.accounts.map { it.ready })
        assertEquals("Sign-in expired on box", state.accounts.first().reason)
        assertTrue(state.account_blocked, "Home cannot run on box")
        assertEquals("Home", state.account_label)

        val switched =
            ScheduleDrafts.choose(draft, controls.choosing(AgentChoice(account = CLAUDE_WORK)))
        assertEquals(CLAUDE_WORK, switched.account_id)
        assertEquals("claude-code", switched.provider)
        assertFailsWith<ClientFailure> { controls.choosing(AgentChoice(account = CHATGPT_TEAM)) }

        // The Mac editor keeps its own draft and asks SharedRules with the schedule's machine.
        val mac =
            CreationExports.agentControls(
                ScheduleDrafts.selection(draft),
                HarnessCatalog(harnesses),
                locked = false,
                choice = AgentChoice(account = CLAUDE_WORK),
                providers =
                    ProvidersPresenter.slice(providers, Instant.parse("2026-11-14T12:00:00Z")),
                daemonId = "box",
            )
        assertEquals(CLAUDE_WORK, ScheduleDrafts.choose(draft, mac.selection!!).account_id)
        assertEquals(listOf(false, true), mac.accounts.map { it.ready })
        assertFalse(mac.account_blocked)
    }
}
