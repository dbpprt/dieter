package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.ProviderOption

/**
 * Builds the provider-defined configuration without teaching the Android app
 * about a particular harness or option ID. Saved values win over newly
 * advertised defaults so an existing conversation retains its configuration.
 */
internal fun providerOptionValues(
    harness: Harness?,
    saved: Map<String, String> = emptyMap(),
): Map<String, String> = buildMap {
    harness?.optionsList.orEmpty().forEach { option -> put(option.id, option.defaultValue) }
    putAll(saved)
}

internal fun providerOptionValue(
    option: ProviderOption,
    values: Map<String, String>,
): String = values[option.id] ?: option.defaultValue

@Composable
internal fun ProviderOptionControl(
    option: ProviderOption,
    values: Map<String, String>,
    enabled: Boolean,
    onValueChange: (String, String) -> Unit,
) {
    val current = providerOptionValue(option, values)
    val semantics = Modifier
        .testTag("provider-option-${option.id}")
        .semantics {
            contentDescription = buildString {
                append(option.name)
                if (option.description.isNotBlank()) append(". ${option.description}")
            }
        }
    when (option.type.lowercase()) {
        "boolean", "bool" -> {
            val selected = current.equals("true", ignoreCase = true)
            FilterChip(
                selected = selected,
                onClick = { onValueChange(option.id, (!selected).toString()) },
                enabled = enabled,
                label = { Text(option.name) },
                modifier = semantics,
            )
        }

        "enum", "select" -> {
            var expanded by remember(option.id) { mutableStateOf(false) }
            val label = option.choicesList.firstOrNull { it.value == current }
                ?.name?.ifBlank { current }
                ?: option.name
            Box(semantics) {
                AssistChip(
                    onClick = { expanded = true },
                    enabled = enabled,
                    label = { Text(label) },
                )
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    option.choicesList.forEach { choice ->
                        DropdownMenuItem(
                            text = { Text(choice.name.ifBlank { choice.value }) },
                            onClick = {
                                expanded = false
                                onValueChange(option.id, choice.value)
                            },
                        )
                    }
                }
            }
        }

        else -> OutlinedTextField(
            value = current,
            onValueChange = { onValueChange(option.id, it) },
            enabled = enabled,
            singleLine = true,
            label = { Text(option.name) },
            modifier = semantics.width(180.dp),
        )
    }
}
