package com.dbpprt.dieter.core.selection

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.EffortConfig
import com.dbpprt.dieter.api.v1.EffortOption
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessCapability
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.ProviderOption
import com.dbpprt.dieter.api.v1.ProviderOptionChoice
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.core.composition.RestoredMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The composer's agent for the next message: what it shows, when a choice
 * is released, and what a send carries. Ports the Mac's composer settings
 * tests.
 */
class ComposerAgentTest {
    private val fast = ProviderOption(id = "fast_mode", type = "bool", default_value = "false", mutable = true, models = listOf("model-a", "model-b"))
    private val sandbox = ProviderOption(id = "sandbox", type = "enum", default_value = "safe", choices = listOf(ProviderOptionChoice(value_ = "safe"), ProviderOptionChoice(value_ = "open")))
    private val codex = Harness(
        id = "codex", name = "Codex", default_model = "model-a",
        models = listOf(
            HarnessModel(id = "model-a", name = "A", default_effort = "medium", efforts = listOf("low", "medium", "high")),
            HarnessModel(id = "model-b", name = "B", efforts = listOf("low", "high")),
            HarnessModel(id = "model-c", name = "C"),
        ),
        effort = EffortConfig(options = listOf(EffortOption("low", "Low"), EffortOption("medium", "Medium"), EffortOption("high", "High"))),
        capabilities = listOf(HarnessCapability("model-selection", "between-turns"), HarnessCapability("effort-selection", "between-turns")),
        options = listOf(fast, sandbox),
    )
    private val claude = Harness(id = "claude", name = "Claude", default_model = "opus", models = listOf(HarnessModel(id = "opus")))

    /** The Mac fixture: a started card on Codex model A, effort high, fast mode off. */
    private val started = Card(
        id = "card-settings", scope = "board", provider = "codex", model = "model-a", effort = "high",
        provider_options = mapOf("fast_mode" to "false", "sandbox" to "safe"), initial_prompt_sent_at = "2026-09-10T12:00:00Z",
    )

    @Test
    fun aChoiceSurvivesActiveSnapshotsUntilTheConversationRunsWithIt() {
        val chosen = HarnessSelection("codex", "model-b", "low", mapOf("fast_mode" to "true", "sandbox" to "safe"))
        assertEquals(chosen, Selections.pending(chosen, started, listOf(codex)), "the active turn's snapshot still shows the old settings")
        assertEquals(chosen, AgentControls.forComposer(chosen, started, listOf(codex)).selection)
        val admitted = started.copy(model = "model-b", effort = "low", provider_options = mapOf("fast_mode" to "true", "sandbox" to "safe"))
        assertNull(Selections.pending(chosen, admitted, listOf(codex)), "released once the card runs with it")
        assertNull(Selections.pending(chosen.copy(effort = "default"), admitted.copy(effort = ""), listOf(codex)), "the explicit default equals an empty effort")
        assertNull(Selections.pending(chosen, admitted, emptyList()), "without a catalog the raw values compare")
    }

    @Test
    fun aComposerWithoutAChoiceFollowsTheCardWhileAPendingChoiceStays() {
        val remote = started.copy(model = "model-b", effort = "low")
        assertEquals(HarnessSelection("codex", "model-b", "low", mapOf("fast_mode" to "false", "sandbox" to "safe")), AgentControls.forComposer(null, remote, listOf(codex)).selection)
        val pending = HarnessSelection("codex", "model-a", "high", mapOf("fast_mode" to "false", "sandbox" to "safe"))
        assertEquals(pending, Selections.pending(pending, remote.copy(effort = "medium"), listOf(codex)), "a changed card does not replace a pending choice")
        assertNull(Selections.pending(HarnessSelection("claude", "opus"), started, listOf(codex, claude)), "a started conversation keeps its provider")
        assertEquals(HarnessSelection("claude", "opus"), Selections.pending(HarnessSelection("claude", "opus"), started.copy(initial_prompt_sent_at = ""), listOf(codex, claude)))
    }

    @Test
    fun aSendCarriesTheChoiceWithTheExplicitDefaultEffort() {
        // Without a catalog nothing but the provider is enforced.
        val draft = HarnessSelection("codex", "model-b", "", mapOf("fast_mode" to "true"))
        assertEquals(HarnessSelection("codex", "model-b", "default", mapOf("fast_mode" to "true")), Selections.forSend(draft, started))
        for (scope in listOf("board", "chat")) {
            val card = started.copy(scope = scope)
            assertEquals(
                HarnessSelection("codex", "model-b", "low", mapOf("fast_mode" to "true", "sandbox" to "safe")),
                Selections.forSend(HarnessSelection("codex", "model-b", "low", mapOf("fast_mode" to "true")), card, listOf(codex)),
                "a $scope message carries its settings, options validated",
            )
        }
        assertEquals(HarnessSelection("codex", "model-a", "high", started.provider_options), Selections.forSend(null, started, listOf(codex)), "no choice: the card's agent")
    }

    @Test
    fun aStartedConversationKeepsWhatItsHarnessDoesNotLetChange() {
        assertEquals(HarnessSelection("codex", "model-a", "high", started.provider_options), Selections.forSend(HarnessSelection("claude", "opus", "low"), started, listOf(codex, claude)), "another provider sends the card's agent")
        val older = codex.copy(capabilities = listOf(HarnessCapability("model-selection", "between-turns")))
        assertEquals(
            HarnessSelection("codex", "model-b", "high", mapOf("fast_mode" to "true", "sandbox" to "safe")),
            Selections.forSend(HarnessSelection("codex", "model-b", "low", mapOf("fast_mode" to "true", "sandbox" to "open")), started, listOf(older)),
            "the effort and the immutable sandbox stay as the card has them",
        )
        val creationOnly = codex.copy(capabilities = emptyList())
        assertEquals(
            HarnessSelection("codex", "model-a", "high", mapOf("fast_mode" to "true", "sandbox" to "safe")),
            Selections.forSend(HarnessSelection("codex", "model-b", "low", mapOf("fast_mode" to "true")), started, listOf(creationOnly)),
            "a mutable option still changes",
        )
        assertEquals(started.let { HarnessSelection(it.provider, it.model, it.effort, it.provider_options) }, Selections.forSend(HarnessSelection("codex", "model-b"), started, listOf(claude)), "a retired harness sends the card's agent")
        assertEquals(HarnessSelection("codex", "model-b", "default", mapOf("fast_mode" to "false", "sandbox" to "safe")), Selections.forSend(HarnessSelection("codex", "model-b", "medium"), started, listOf(codex)), "an effort the model rejects becomes the explicit default")
        val fresh = Card(provider = "codex", model = "model-a")
        assertEquals(HarnessSelection("claude", "opus", "default"), Selections.forSend(HarnessSelection("claude", "", ""), fresh, listOf(codex, claude)), "a never-started card may switch provider; the model is the new provider's default")
    }

    @Test
    fun choosingAModelDropsOptionsItLacksAndKeepsALockedEffort() {
        val modelOnly = codex.copy(capabilities = listOf(HarnessCapability("model-selection", "between-turns")))
        val chosen = HarnessSelection("codex", "model-a", "high", mapOf("fast_mode" to "true", "sandbox" to "safe"))
        val locked = AgentControls(chosen, listOf(modelOnly), locked = true)
        assertEquals(HarnessSelection("codex", "model-c", "high", mapOf("sandbox" to "safe")), locked.choosingModel("model-c"), "fast mode does not apply to model C; the effort may not change")
        val open = AgentControls(chosen, listOf(codex), locked = true)
        assertEquals("default", open.choosingModel("model-c").effort, "model C has no default effort; the Mac left it empty")
        assertEquals("medium", open.choosingModel("model-a").effort)
    }

    @Test
    fun editingAQueuedMessageRestoresItsSettingsUnlessItHasNone() {
        val queued = QueuedMessage(selection = HarnessSelection("codex", "queued-model", "low", mapOf("fast_mode" to "true")))
        assertEquals(HarnessSelection("codex", "queued-model", "low", mapOf("fast_mode" to "true")), RestoredMessage.from(queued).selection)
        assertNull(RestoredMessage.from(QueuedMessage()).selection, "no settings snapshot: the composer keeps its own")
    }

    @Test
    fun capabilitiesDecideWhatAStartedConversationMayChange() {
        val bare = Harness(id = "codex")
        assertTrue(Selections.canChange(bare, Selections.MODEL_SELECTION, locked = false))
        assertFalse(Selections.canChange(bare, Selections.MODEL_SELECTION, locked = true))
        val modelOnly = bare.copy(capabilities = listOf(HarnessCapability("model-selection", "between-turns")))
        assertTrue(Selections.canChange(modelOnly, Selections.MODEL_SELECTION, locked = true))
        assertFalse(Selections.canChange(modelOnly, Selections.EFFORT_SELECTION, locked = true))
        assertTrue(Selections.canChange(codex, Selections.EFFORT_SELECTION, locked = true))
        assertTrue(Selections.locked(started) && Selections.locked(Card(), hasMessages = true) && !Selections.locked(Card()))
        assertTrue(AgentControls.forComposer(null, Card(provider = "codex"), listOf(codex), hasMessages = true).locked, "a conversation with messages is started")
    }

    @Test
    fun aChosenSelectionIsValidatedAgainstItsHarness() {
        assertEquals(HarnessSelection("codex", "model-a", "low", mapOf("fast_mode" to "false", "sandbox" to "safe")), Selections.validated(HarnessSelection("codex", "", "low"), listOf(codex)))
        assertEquals(HarnessSelection("codex", "model-b", "default", mapOf("fast_mode" to "false", "sandbox" to "safe")), Selections.validated(HarnessSelection("codex", "model-b", "medium"), listOf(codex)))
        assertEquals(HarnessSelection("gone", "x", "low"), Selections.validated(HarnessSelection("gone", "x", "low"), listOf(codex)), "an unknown agent stays for supports() to report")
        assertEquals(
            HarnessSelection("available", "current", "medium"),
            Selections.resolve(
                HarnessSelection("removed", "retired", "xhigh"),
                listOf(Harness(id = "available", default_model = "current", models = listOf(HarnessModel(id = "current", default_effort = "medium", efforts = listOf("medium"))), effort = EffortConfig(options = listOf(EffortOption("medium"))))),
            ),
            "a stale remembered agent falls back to the catalog's first and its defaults",
        )
        assertEquals(mapOf("advisor" to "true"), Selections.resolvedOptions(Harness(options = listOf(ProviderOption(id = "advisor", default_value = "false"))), mapOf("advisor" to "true", "local-only" to "secret")), "options the harness does not advertise are dropped")
    }
}
