package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.HarnessCapability
import com.dbpprt.dieter.v1.HarnessModel
import com.dbpprt.dieter.v1.ProviderOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationSelectionPolicyTest {
    private val harness = Harness.newBuilder()
        .setId("codex")
        .setDefaultModel("sol")
        .addModels(HarnessModel.newBuilder().setId("sol").setDefaultEffort("medium"))
        .addModels(HarnessModel.newBuilder().setId("spark"))
        .addCapabilities(HarnessCapability.newBuilder().setId("model-selection").setLevel("between-turns"))
        .addCapabilities(HarnessCapability.newBuilder().setId("effort-selection").setLevel("between-turns"))
        .addOptions(ProviderOption.newBuilder().setId("fast_mode").setType("boolean")
            .setDefaultValue("false").setMutable(true).addModels("sol"))
        .build()

    private fun runningCard(): Card = Card.newBuilder().setId("card").setProvider("codex")
        .setModel("sol").setEffort("high").setRuntime("running").setInitialPromptSentAt("2026-09-10T12:00:00Z")
        .putProviderOptions("fast_mode", "true").build()

    @Test fun startedProviderStaysLockedWhileAdvertisedNextTurnSettingsRemainAvailable() {
        assertTrue(conversationSelectionLocked(runningCard()))
        assertTrue(conversationSettingEnabled(harness, locked = true, capability = "model-selection"))
        assertTrue(conversationSettingEnabled(harness, locked = true, capability = "effort-selection"))
        assertFalse(conversationSettingEnabled(harness, locked = true, capability = "provider-selection"))
        assertTrue(conversationSelectionLocked(runningCard().toBuilder().setRuntime("idle").build()))
        assertTrue(conversationSelectionLocked(runningCard().toBuilder().clearInitialPromptSentAt().build()))
        assertFalse(conversationSelectionLocked(Card.newBuilder().setRuntime("idle").build()))
    }

    @Test fun oldOrUnsupportedCapabilitiesDoNotPromiseMidConversationChanges() {
        val older = harness.toBuilder().clearCapabilities()
            .addCapabilities(HarnessCapability.newBuilder().setId("model-selection").setLevel("creation-only"))
            .build()
        assertFalse(conversationSettingEnabled(older, locked = true, capability = "model-selection"))
        assertFalse(conversationSettingEnabled(older, locked = true, capability = "effort-selection"))
        assertFalse(conversationSettingEnabled(null, locked = true, capability = "model-selection"))
        assertTrue(conversationSettingEnabled(older, locked = false, capability = "model-selection"))
    }

    @Test fun liveCardAndCatalogUpdatesKeepLocallyChosenNextMessageSettings() {
        val selection = ConversationComposerSelection.initial(runningCard(), listOf(harness))
            .copy(effort = "low", providerOptions = mapOf("fast_mode" to "false"))
        val refreshed = selection.fillingMissingSelection(runningCard(), listOf(harness))
        assertEquals(selection, refreshed)
        assertEquals("high", runningCard().effort)
        assertEquals("true", runningCard().providerOptionsMap["fast_mode"])
    }

    @Test fun modelChangesExplicitlyResetEffortAndRemoveUnsupportedOptions() {
        val selection = ConversationComposerSelection.initial(runningCard(), listOf(harness))
        val changed = selection.selectingModel("spark", harness)
        assertEquals("codex", changed.provider)
        assertEquals("spark", changed.model)
        assertEquals("default", changed.effort)
        assertEquals(emptyMap<String, String>(), changed.providerOptions)
        val restoredModel = changed.selectingModel("sol", harness)
        assertEquals("default", restoredModel.effort)
        assertEquals(mapOf("fast_mode" to "false"), restoredModel.providerOptions)
    }

    @Test fun delayedCatalogDoesNotLoseSavedFastModeOrEffort() {
        val initial = ConversationComposerSelection.initial(runningCard(), emptyList())
        assertEquals(mapOf("fast_mode" to "true"), initial.providerOptions)
        val hydrated = initial.fillingMissingSelection(runningCard(), listOf(harness))
        assertEquals("high", hydrated.effort)
        assertEquals(mapOf("fast_mode" to "true"), hydrated.providerOptions)
        val empty = ConversationComposerSelection.initial(null, emptyList())
        assertEquals("sol", empty.fillingMissingSelection(null, listOf(harness)).model)
    }

    @Test fun changingDraftProviderUsesItsOwnDefaults() {
        val selected = ConversationComposerSelection.forProvider(harness)
        assertEquals("codex", selected.provider)
        assertEquals("sol", selected.model)
        assertEquals("default", selected.effort)
        assertEquals(mapOf("fast_mode" to "false"), selected.providerOptions)
    }
}
