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
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AgentControlsTest {
    private val fastMode = ProviderOption(id = "fast_mode", type = "boolean", default_value = "false", mutable = true, models = listOf("sol"))
    private val codex = Harness(
        id = "codex", name = "Codex", default_model = "sol",
        models = listOf(HarnessModel(id = "sol", name = "Sol", default_effort = "medium", efforts = listOf("low", "medium", "high")), HarnessModel(id = "spark")),
        effort = EffortConfig(options = listOf(EffortOption(id = "low", name = "Low"), EffortOption(id = "medium", name = "Medium"), EffortOption(id = "high", name = "High"), EffortOption(id = "xhigh", name = "Extra high"))),
        capabilities = listOf(HarnessCapability(id = "model-selection", level = "between-turns"), HarnessCapability(id = "effort-selection", level = "between-turns")),
        options = listOf(fastMode),
    )
    private val runningCard = Card(
        id = "card", provider = "codex", model = "sol", effort = "high", runtime = "running",
        initial_prompt_sent_at = "2026-09-10T12:00:00Z", provider_options = mapOf("fast_mode" to "true"),
    )

    @Test
    fun startedConversationsFixTheProviderWhileAdvertisedSettingsStayAvailable() {
        val controls = AgentControls.forConversation(null, runningCard, listOf(codex))
        assertEquals(HarnessSelection(provider = "codex", model = "sol", effort = "high", provider_options = mapOf("fast_mode" to "true")), controls.selection)
        assertTrue(controls.locked)
        assertFalse(controls.providerEnabled)
        assertTrue(controls.modelEnabled)
        assertTrue(controls.effortEnabled)
        assertTrue(Selections.locked(Card(runtime = "idle"), hasMessages = true))
        assertFalse(AgentControls.forConversation(null, null, listOf(codex)).locked)
        assertTrue(AgentControls.forConversation(null, Card(provider = "codex"), listOf(codex)).providerEnabled)
    }

    @Test
    fun olderOrUnknownHarnessesDoNotPromiseMidConversationChanges() {
        val older = codex.copy(capabilities = listOf(HarnessCapability(id = "model-selection", level = "creation-only")))
        val locked = AgentControls.forConversation(null, runningCard, listOf(older))
        assertFalse(locked.modelEnabled)
        assertFalse(locked.effortEnabled)
        val unknown = AgentControls.forConversation(null, runningCard.copy(provider = "retired"), listOf(codex))
        assertNull(unknown.harness)
        assertFalse(unknown.modelEnabled)
        assertEquals("retired", unknown.providerLabel)
        assertTrue(AgentControls.forConversation(null, Card(provider = "codex"), listOf(older)).modelEnabled, "a new conversation may choose anything")
        val disabled = AgentControls.forConversation(null, Card(provider = "codex"), listOf(codex), enabled = false)
        assertFalse(disabled.providerEnabled || disabled.modelEnabled || disabled.effortEnabled || disabled.optionEnabled(fastMode))
    }

    @Test
    fun effortsAndLabelsFollowTheSelectedModel() {
        val controls = AgentControls(HarnessSelection(provider = "codex", model = "sol"), listOf(codex))
        assertEquals("Codex", controls.providerLabel)
        assertEquals("Sol", controls.modelLabel)
        assertEquals(listOf("low", "medium", "high"), controls.efforts.map { it.id })
        assertEquals("Medium", controls.effortLabel, "an unset effort shows the model's default")
        assertEquals("High", controls.copy(selection = controls.choosingEffort("high")).effortLabel)
        assertEquals("Default", controls.copy(selection = controls.choosingEffort(Selections.DEFAULT_EFFORT)).effortLabel)
        assertEquals("Turbo", controls.copy(selection = controls.choosingEffort("turbo")).effortLabel, "an effort the catalog does not name is still shown")
        val spark = controls.copy(selection = controls.choosingModel("spark"))
        assertEquals(listOf("low", "medium", "high", "xhigh"), spark.efforts.map { it.id }, "a model without its own list accepts every harness effort")
        assertEquals("Default", spark.effortLabel)
        val unnamed = AgentControls(HarnessSelection(provider = "codex", model = "sol"), listOf(codex.copy(name = "", models = codex.models.map { it.copy(name = "") })))
        assertEquals(listOf("codex", "sol"), listOf(unnamed.providerLabel, unnamed.modelLabel), "an unnamed harness or model shows its ID")
        val empty = AgentControls(HarnessSelection(), emptyList())
        assertEquals(listOf("Agent", "Default model", "Default"), listOf(empty.providerLabel, empty.modelLabel, empty.effortLabel))
        assertTrue(empty.efforts.isEmpty())
    }

    @Test
    fun modelChangesResetEffortAndRevalidateOptions() {
        val controls = AgentControls.forConversation(null, runningCard, listOf(codex))
        val spark = controls.choosingModel("spark")
        assertEquals(HarnessSelection(provider = "codex", model = "spark", effort = "default"), spark, "the Sol-only option is dropped")
        val restored = controls.copy(selection = spark).choosingModel("sol")
        assertEquals("default", restored.effort)
        assertEquals(mapOf("fast_mode" to "false"), restored.provider_options, "the option returns at its default")
        assertEquals(
            HarnessSelection(provider = "codex", model = "sol", effort = "default", provider_options = mapOf("fast_mode" to "false")),
            controls.choosingProvider(codex),
            "another provider starts from its own defaults",
        )
    }

    @Test
    fun locallyChosenSettingsSurviveCardAndCatalogRefreshes() {
        val chosen = Selections.initial(runningCard, listOf(codex)).copy(effort = "low", provider_options = mapOf("fast_mode" to "false"))
        assertEquals(chosen, Selections.filled(chosen, runningCard, listOf(codex)))
        assertEquals(chosen, AgentControls.forConversation(chosen, runningCard, listOf(codex)).selection)

        val beforeCatalog = Selections.initial(runningCard, emptyList())
        assertEquals(
            HarnessSelection(provider = "codex", model = "sol", effort = "high", provider_options = mapOf("fast_mode" to "true")),
            beforeCatalog,
            "saved options are kept until the catalog can validate them",
        )
        assertEquals(beforeCatalog, Selections.filled(beforeCatalog, runningCard, listOf(codex)))
        assertEquals(
            HarnessSelection(provider = "codex", model = "sol", provider_options = mapOf("fast_mode" to "false")),
            Selections.filled(Selections.initial(null, emptyList()), null, listOf(codex)),
            "an empty selection takes the catalog's defaults once it arrives",
        )
    }

    @Test
    fun optionsAreModelScopedValidatedAndEditableOnlyWhenAllowed() {
        val instructions = ProviderOption(id = "instructions", type = "text", default_value = "Be concise")
        val mode = ProviderOption(id = "mode", type = "enum", default_value = "quick", choices = listOf(ProviderOptionChoice(value_ = "quick"), ProviderOptionChoice(value_ = "deep")))
        val harness = codex.copy(options = listOf(fastMode, instructions, mode))
        assertEquals(listOf("fast_mode", "instructions", "mode"), Selections.options(harness, "sol").map { it.id })
        assertEquals(listOf("fast_mode", "instructions", "mode"), Selections.options(harness, "").map { it.id }, "a blank model means the default model")
        assertEquals(listOf("instructions", "mode"), Selections.options(harness, "spark").map { it.id })
        assertTrue(Selections.options(null, "sol").isEmpty())
        assertEquals(
            mapOf("fast_mode" to "false", "instructions" to "Be concise", "mode" to "quick"),
            Selections.normalizedOptions(harness, "sol", mapOf("fast_mode" to "yes", "mode" to "turbo")),
            "invalid saved values fall back to the advertised defaults",
        )
        val saved = mapOf("fast_mode" to "true", "instructions" to "Be terse", "mode" to "deep")
        assertEquals(saved, Selections.normalizedOptions(harness, "sol", saved))

        val controls = AgentControls(HarnessSelection(provider = "codex", model = "spark"), listOf(harness), locked = true)
        assertEquals(listOf("instructions", "mode"), controls.options.map { it.id })
        assertEquals("Be concise", controls.optionValue(instructions))
        assertEquals("deep", controls.copy(selection = controls.settingOption("mode", "deep")).optionValue(mode))
        assertTrue(controls.optionEnabled(fastMode))
        assertFalse(controls.optionEnabled(instructions))
        assertTrue(controls.copy(locked = false).optionEnabled(instructions))
    }
}
