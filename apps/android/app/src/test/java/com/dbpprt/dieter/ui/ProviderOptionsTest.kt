package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.ProviderOption
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderOptionsTest {
    @Test
    fun advertisedDefaultsRemainGenericAndSavedValuesWin() {
        val advisor = ProviderOption.newBuilder()
            .setId("advisor")
            .setName("Advisor mode")
            .setType("boolean")
            .setDefaultValue("false")
            .build()
        val mode = ProviderOption.newBuilder()
            .setId("mode")
            .setName("Mode")
            .setType("enum")
            .setDefaultValue("quick")
            .build()
        val harness = Harness.newBuilder().addOptions(advisor).addOptions(mode).build()

        assertEquals(
            mapOf("advisor" to "true", "mode" to "quick"),
            providerOptionValues(harness, mapOf("advisor" to "true")),
        )
    }

    @Test
    fun missingValueFallsBackToAdvertisedDefault() {
        val option = ProviderOption.newBuilder()
            .setId("instructions")
            .setDefaultValue("Be concise")
            .build()

        assertEquals("Be concise", providerOptionValue(option, emptyMap()))
    }

    @Test
    fun modelScopedOptionsOnlyAppearForSupportedModels() {
        val fastMode = ProviderOption.newBuilder()
            .setId("fast_mode")
            .setDefaultValue("false")
            .addModels("gpt-5.6-sol")
            .build()
        val harness = Harness.newBuilder()
            .setDefaultModel("gpt-5.6-sol")
            .addOptions(fastMode)
            .build()

        assertEquals(
            mapOf("fast_mode" to "true"),
            providerOptionValues(harness, mapOf("fast_mode" to "true"), "gpt-5.6-sol"),
        )
        assertEquals(emptyMap<String, String>(), providerOptionValues(harness, mapOf("fast_mode" to "true"), "gpt-5.3-codex-spark"))
        assertEquals(emptyList<ProviderOption>(), providerOptionsForModel(harness, "gpt-5.3-codex-spark"))
    }

    @Test
    fun onlyMutableOptionsRemainEnabledAfterConversationStarts() {
        val fastMode = ProviderOption.newBuilder().setId("fast_mode").setMutable(true).build()
        val sessionMode = ProviderOption.newBuilder().setId("session_mode").build()

        assertEquals(true, providerOptionEnabled(fastMode, conversationLocked = true))
        assertEquals(false, providerOptionEnabled(sessionMode, conversationLocked = true))
        assertEquals(true, providerOptionEnabled(sessionMode, conversationLocked = false))
    }
}
