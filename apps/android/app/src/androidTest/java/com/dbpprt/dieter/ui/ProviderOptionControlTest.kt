package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.ProviderOption
import com.dbpprt.dieter.api.v1.ProviderOptionChoice
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ProviderOptionControlTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun rendersAndUpdatesEveryAdvertisedOptionType() {
        val advisor = option(id = "advisor", name = "Advisor", type = "boolean", defaultValue = "false")
        val mode = option(id = "mode", name = "Mode", type = "enum", defaultValue = "quick")
            .let { it.copy(choices = it.choices + listOf(choice("quick", "Quick"), choice("thorough", "Thorough"))) }
        val instructions = option(
            id = "instructions",
            name = "Instructions",
            type = "string",
            defaultValue = "Concise",
        )
        var observed = emptyMap<String, String>()

        composeRule.setContent {
            var values by remember { mutableStateOf(emptyMap<String, String>()) }
            observed = values
            DieterTheme {
                Column {
                    listOf(advisor, mode, instructions).forEach { advertised ->
                        ProviderOptionControl(
                            option = advertised,
                            value = values[advertised.id] ?: advertised.default_value,
                            enabled = true,
                            onValueChange = { id, value -> values = values + (id to value) },
                        )
                    }
                }
            }
        }

        composeRule.onNodeWithTag("provider-option-advisor").performClick()
        composeRule.onNodeWithText("Quick").performClick()
        composeRule.onNodeWithText("Thorough").performClick()
        composeRule.onNodeWithTag("provider-option-instructions").performTextReplacement("Detailed")

        composeRule.runOnIdle {
            assertEquals("true", observed["advisor"])
            assertEquals("thorough", observed["mode"])
            assertEquals("Detailed", observed["instructions"])
        }
    }

    private fun option(
        id: String,
        name: String,
        type: String,
        defaultValue: String,
    ): ProviderOption = ProviderOption(id = id, name = name, type = type, default_value = defaultValue)

    private fun choice(value: String, name: String): ProviderOptionChoice = ProviderOptionChoice(value_ = value, name = name)
}
