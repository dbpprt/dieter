package com.getdieter.core.selection

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCapability
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.ProviderOption
import com.getdieter.api.v1.ProviderOptionChoice
import com.getdieter.client.v1.AgentChoice
import com.getdieter.client.v1.AgentOptionChoice
import com.getdieter.client.v1.AgentOptionKind
import com.getdieter.core.client.ClientFailure
import com.getdieter.core.client.agentControlsState
import com.getdieter.core.client.choosing
import com.getdieter.core.client.providerNotice
import com.getdieter.core.client.rules.CreationExports
import com.getdieter.core.composition.CreationMemory
import com.getdieter.core.providers.AgentAccountRules
import com.getdieter.core.providers.OmpAccounts
import com.getdieter.core.providers.ProviderFixtures
import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_HOME
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.default
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderKinds
import com.getdieter.core.providers.ProvidersPresenter
import com.getdieter.core.providers.ProvidersView
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

/** Oh My Pi's accounts follow its model's provider; its advisor may run on the other provider's. */
class OmpAccountsTest {
    private val sonnet = "anthropic/claude-sonnet-5-5"
    private val opus = "anthropic/claude-opus-5-5"
    private val sol = "openai-codex/gpt-6-sol"

    private val omp =
        Harness(
            id = "omp",
            name = "Oh My Pi",
            default_model = sonnet,
            models = listOf(HarnessModel(sonnet), HarnessModel(opus), HarnessModel(sol)),
            capabilities =
                listOf(
                    HarnessCapability("model-selection", "between-turns"),
                    HarnessCapability("effort-selection", "between-turns"),
                    HarnessCapability("account-selection", "between-turns"),
                ),
            options =
                listOf(
                    ProviderOption(
                        id = "advisor_model",
                        name = "Advisor",
                        type = "enum",
                        default_value = "off",
                        mutable = true,
                        choices =
                            listOf(
                                ProviderOptionChoice("off", "Off"),
                                ProviderOptionChoice(opus, "Claude Opus 5.5"),
                                ProviderOptionChoice(sol, "GPT-6 Sol"),
                            ),
                    ),
                    ProviderOption(
                        id = "advisor_effort",
                        name = "Advisor thinking",
                        type = "enum",
                        default_value = "medium",
                        mutable = true,
                        choices =
                            listOf(ProviderOptionChoice("low"), ProviderOptionChoice("medium")),
                    ),
                    ProviderOption(
                        id = "advisor_account",
                        name = "Advisor account",
                        type = "string",
                        mutable = true,
                    ),
                ),
        )
    private val claudeCode =
        Harness(
            id = "claude-code",
            name = "Claude Code",
            default_model = "opus",
            models = listOf(HarnessModel("opus")),
        )
    private val harnesses = listOf(omp, claudeCode)

    private val web = "pa_dddddddddddddddddddddddddd"
    private val boxLogin = "pa_eeeeeeeeeeeeeeeeeeeeeeeeee"

    /**
     * Work allows Oh My Pi, Home does not; Team is a Codex sign-in, Web a Sign in with ChatGPT
     * login, Box login the machine's own. All are signed in on box.
     */
    private val providers =
        ProviderFixtures.view(
            account(CLAUDE_WORK, "claude", "Work", omp = true),
            account(CLAUDE_HOME, "claude", "Home"),
            account(CHATGPT_TEAM, "chatgpt", "Team", method = "codex"),
            account(web, "chatgpt", "Web", method = "siwc"),
            account(boxLogin, "chatgpt", "Box login", method = "host"),
            default("claude", CLAUDE_WORK),
            default("chatgpt", CHATGPT_TEAM),
            login(CLAUDE_WORK, "box"),
            login(CLAUDE_HOME, "box"),
            login(CHATGPT_TEAM, "box"),
            login(web, "box"),
            login(boxLogin, "box"),
        )

    private fun controls(
        selection: HarnessSelection,
        view: ProvidersView = providers,
        last: String = "",
        locked: Boolean = false,
    ) =
        AgentControls(
            selection,
            harnesses,
            locked = locked,
            accounts = AgentAccountRules.forMachine(view, "box", last),
        )

    private fun advised(model: String, advisor: String, account: String? = null) =
        HarnessSelection(
            "omp",
            model,
            provider_options =
                buildMap {
                    put("advisor_model", advisor)
                    put("advisor_effort", "medium")
                    if (account != null) put("advisor_account", account)
                },
        )

    @Test
    fun accountsFollowTheModelsProvider() {
        val claude = controls(HarnessSelection("omp", sonnet))
        assertEquals(ProviderKinds.CLAUDE, claude.providerKind)
        assertEquals(listOf(CLAUDE_WORK), claude.accountOptions.map { it.id }, "only with access")
        assertEquals(CLAUDE_WORK, claude.account?.id)
        assertNull(claude.accountHint)
        assertFalse(claude.accountBlocked)

        val chatgpt = controls(HarnessSelection("omp", sol))
        assertEquals(ProviderKinds.CHATGPT, chatgpt.providerKind)
        assertEquals(
            listOf(boxLogin, CHATGPT_TEAM),
            chatgpt.accountOptions.map { it.id },
            "ChatGPT logins only: Sign in with ChatGPT is left out",
        )
        assertEquals(CHATGPT_TEAM, chatgpt.account?.id)
        val state = agentControlsState(chatgpt)
        assertEquals(listOf("Box login", "Team"), state.accounts.map { it.label })
        assertTrue(state.account_enabled)
        assertEquals("", state.account_hint)
        assertEquals(CHATGPT_TEAM, state.selection?.account_id)

        // A blank model is the harness default's.
        assertEquals(ProviderKinds.CLAUDE, controls(HarnessSelection("omp")).providerKind)
        // Claude Code keeps every Claude account.
        assertEquals(2, controls(HarnessSelection("claude-code", "opus")).accountOptions.size)
    }

    @Test
    fun withoutAnAllowedLoginTheComposerSaysWhereToAllowOne() {
        val noAccess =
            ProviderFixtures.view(
                account(CLAUDE_HOME, "claude", "Home"),
                account(CHATGPT_TEAM, "chatgpt", "Team"),
                login(CLAUDE_HOME, "box"),
            )
        val blocked = controls(HarnessSelection("omp", sonnet), noAccess)
        assertTrue(blocked.accountOptions.isEmpty())
        assertFalse(blocked.accountEnabled)
        assertEquals(
            "Allow Oh My Pi to use a Claude login in Settings › Providers.",
            blocked.accountHint,
        )
        assertTrue(blocked.accountBlocked, "the daemon would refuse the turn")
        assertEquals(blocked.accountHint, agentControlsState(blocked).account_hint)
        val notice = providerNotice(blocked)!!
        assertEquals(blocked.accountHint, notice.title)
        assertEquals(AgentAccountRules.ACTION_CHOOSE_ACCOUNT, notice.action)
        assertEquals("box", notice.daemon_id)

        val chatgptOnly =
            controls(
                HarnessSelection("omp", sonnet),
                ProviderFixtures.view(account(CHATGPT_TEAM, "chatgpt", "Team")),
            )
        assertEquals(
            "Add a Claude account in Settings › Providers and allow Oh My Pi to use it.",
            chatgptOnly.accountHint,
        )
        val siwcOnly =
            controls(
                HarnessSelection("omp", sol),
                ProviderFixtures.view(account(web, "chatgpt", "Web", method = "siwc")),
            )
        assertTrue(siwcOnly.accountHint!!.startsWith("Oh My Pi runs ChatGPT models on a Codex"))

        // Before any account is known, nothing blocks; the hint still says what is needed.
        val unknown = controls(HarnessSelection("omp", sonnet), ProvidersView())
        assertFalse(unknown.accountBlocked)
        assertNull(providerNotice(unknown))
        assertTrue(unknown.accountHint != null)
        // Other agents never show the hint.
        assertNull(controls(HarnessSelection("claude-code", "opus"), noAccess).accountHint)
    }

    @Test
    fun movingToTheOtherProvidersModelMovesToItsAccount() {
        val onWork = controls(HarnessSelection("omp", sonnet, account_id = CLAUDE_WORK))
        val moved = onWork.choosing(AgentChoice(model = sol))
        assertEquals(sol, moved.model)
        assertEquals("", moved.account_id, "ChatGPT's default, which Oh My Pi may use")
        assertEquals(CHATGPT_TEAM, onWork.copy(selection = moved).account?.id)
        assertEquals(
            CLAUDE_WORK,
            onWork.choosing(AgentChoice(model = opus)).account_id,
            "the same provider keeps the account",
        )

        // A started conversation on Work moves to ChatGPT's default too.
        val started = controls(HarnessSelection("omp", sonnet), last = CLAUDE_WORK, locked = true)
        assertTrue(started.modelEnabled)
        val next = started.copy(selection = started.choosing(AgentChoice(model = sol)))
        assertEquals(CHATGPT_TEAM, next.account?.id)

        // A default Oh My Pi may not use is passed over by name, since the daemons would use it.
        val unusableDefaults =
            ProviderFixtures.view(
                account(CLAUDE_WORK, "claude", "Work", omp = true),
                account(CLAUDE_HOME, "claude", "Home"),
                account(CHATGPT_TEAM, "chatgpt", "Team", method = "codex"),
                account(web, "chatgpt", "Web", method = "siwc"),
                default("claude", CLAUDE_HOME),
                default("chatgpt", web),
                login(CLAUDE_WORK, "box"),
                login(CHATGPT_TEAM, "box"),
            )
        val claude = controls(HarnessSelection("claude-code", "opus"), unusableDefaults)
        assertEquals(CLAUDE_WORK, claude.choosing(AgentChoice(provider = "omp")).account_id)
        val toSol =
            controls(HarnessSelection("omp", sonnet), unusableDefaults)
                .choosing(AgentChoice(model = sol))
        assertEquals(CHATGPT_TEAM, toSol.account_id)
        assertEquals(
            CLAUDE_WORK,
            controls(HarnessSelection("omp", sonnet), unusableDefaults).settledSelection.account_id,
            "creations name it as well",
        )
        assertFailsWith<ClientFailure> { onWork.choosing(AgentChoice(account = CLAUDE_HOME)) }
        assertFailsWith<ClientFailure> {
            controls(HarnessSelection("omp", sol)).choosing(AgentChoice(account = web))
        }
    }

    @Test
    fun theAdvisorRunsOnTheOtherProvidersAccount() {
        fun shown(controls: AgentControls) = agentControlsState(controls).options.map { it.id }

        val off = controls(HarnessSelection("omp", sonnet))
        assertFalse(off.advisorAccountApplies)
        assertEquals(listOf("advisor_model", "advisor_effort"), shown(off))

        val sameProvider = controls(advised(sonnet, opus, account = CLAUDE_WORK))
        assertFalse(sameProvider.advisorAccountApplies, "it shares the conversation's account")
        assertEquals(listOf("advisor_model", "advisor_effort"), shown(sameProvider))
        assertEquals("", sameProvider.settledSelection.provider_options["advisor_account"])
        assertFailsWith<ClientFailure> {
            sameProvider.choosing(
                AgentChoice(option = AgentOptionChoice("advisor_account", CLAUDE_WORK))
            )
        }

        val other = controls(advised(sonnet, sol))
        assertTrue(other.advisorAccountApplies)
        assertEquals(listOf(boxLogin, CHATGPT_TEAM), other.advisorAccountOptions.map { it.id })
        val state = agentControlsState(other)
        val option = state.options.single { it.id == "advisor_account" }
        assertEquals(AgentOptionKind.AGENT_OPTION_KIND_CHOICE, state.option_kinds[option.id])
        assertEquals(listOf(boxLogin, CHATGPT_TEAM), option.choices.map { it.value_ })
        assertEquals(listOf("Box login", "Team"), option.choices.map { it.name })
        assertEquals(CHATGPT_TEAM, state.option_values[option.id], "ChatGPT's default")
        assertEquals(
            "",
            state.selection?.provider_options?.get("advisor_account").orEmpty(),
            "the default is sent as none",
        )

        val chosen =
            other.choosing(AgentChoice(option = AgentOptionChoice("advisor_account", boxLogin)))
        assertEquals(boxLogin, chosen.provider_options["advisor_account"])
        assertEquals(
            boxLogin,
            agentControlsState(other.copy(selection = chosen)).option_values["advisor_account"],
        )
        for (refused in listOf(web, CLAUDE_WORK, "pa_gone")) assertFailsWith<ClientFailure>(
            refused
        ) {
            other.choosing(AgentChoice(option = AgentOptionChoice("advisor_account", refused)))
        }
        // Back to a Claude advisor: it shares the conversation's account again.
        val back =
            other
                .copy(selection = chosen)
                .choosing(AgentChoice(option = AgentOptionChoice("advisor_model", opus)))
        assertEquals("", back.provider_options["advisor_account"])
        // The implementation model moving to ChatGPT puts the ChatGPT advisor on its account.
        val moved =
            other.copy(selection = chosen).choosing(AgentChoice(model = sol)).provider_options
        assertEquals("", moved["advisor_account"])

        // The conversation's recorded advisor account of the old provider is dropped.
        val stale = controls(advised(sonnet, sol, account = CLAUDE_WORK))
        assertEquals("", stale.settledSelection.provider_options["advisor_account"])
        assertEquals(CHATGPT_TEAM, stale.advisorAccount?.id)

        // Without an account to resolve, the picker offers the provider's default.
        val none =
            controls(
                advised(sonnet, sol),
                ProviderFixtures.view(account(CLAUDE_WORK, "claude", "Work", omp = true)),
            )
        val defaultOnly = agentControlsState(none).options.single { it.id == "advisor_account" }
        assertEquals(
            listOf("" to "Default account"),
            defaultOnly.choices.map { it.value_ to it.name },
        )
        assertEquals("", agentControlsState(none).option_values["advisor_account"])
    }

    @Test
    fun aDefaultAdvisorAccountMatchesTheOneTheDaemonRecorded() {
        val card =
            Card(
                id = "c",
                provider = "omp",
                model = sonnet,
                initial_prompt_sent_at = "2026-11-27T10:00:00Z",
                provider_account_id = CLAUDE_WORK,
                provider_options =
                    mapOf(
                        "advisor_model" to sol,
                        "advisor_effort" to "medium",
                        "advisor_account" to CHATGPT_TEAM,
                    ),
            )
        assertNull(Selections.pending(advised(sonnet, sol, account = ""), card, harnesses))
        assertNull(
            Selections.pending(advised(sonnet, sol, account = CHATGPT_TEAM), card, harnesses)
        )
        val other = advised(sonnet, sol, account = boxLogin)
        assertEquals(other, Selections.pending(other, card, harnesses))
    }

    @Test
    fun creationRemembersOhMyPisAccountsApart() {
        val files = FakeFileSystem()
        val memory = CreationMemory(CoreStorage(files, "/state".toPath()), SilentLogger)
        memory.remember(HarnessSelection("claude-code", "opus", account_id = CLAUDE_HOME))
        memory.remember(HarnessSelection("omp", sol, account_id = CHATGPT_TEAM))
        memory.remember(HarnessSelection("omp", sonnet, account_id = CLAUDE_WORK))
        assertEquals(
            mapOf(
                "claude" to CLAUDE_HOME,
                "omp/chatgpt" to CHATGPT_TEAM,
                "omp/claude" to CLAUDE_WORK,
            ),
            memory.state.value.accounts,
        )
        assertEquals(CLAUDE_WORK, memory.selection(harnesses)?.account_id)
        assertEquals(CHATGPT_TEAM, memory.account("omp", sol))
        assertEquals("", memory.account("omp", "local/model"))
    }

    @Test
    fun formsJudgeOhMyPiAccessFromTheProvidersSlice() {
        val slice = ProvidersPresenter.slice(providers, Instant.parse("2026-11-27T12:00:00Z"))
        val state =
            CreationExports.agentControls(
                HarnessSelection("omp", sonnet),
                HarnessCatalog(harnesses),
                locked = false,
                choice = AgentChoice(),
                providers = slice,
                daemonId = "box",
            )
        assertEquals(listOf(CLAUDE_WORK), state.accounts.map { it.id })
        val chatgpt =
            CreationExports.agentControls(
                HarnessSelection("omp", sonnet),
                HarnessCatalog(harnesses),
                locked = false,
                choice = AgentChoice(model = sol),
                providers = slice,
                daemonId = "box",
            )
        assertEquals(listOf(boxLogin, CHATGPT_TEAM), chatgpt.accounts.map { it.id })
        assertEquals(CHATGPT_TEAM, chatgpt.selection?.account_id)
        assertTrue(OmpAccounts.provider("local/model") == null)
    }
}
