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
}
