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
import com.dbpprt.dieter.api.v1.ProviderOption
import com.dbpprt.dieter.core.selection.ProviderOptionKind
import com.dbpprt.dieter.core.selection.Selections

/** One provider-defined option; how it is edited, its value, and whether it may change come from the core. */
@Composable
internal fun ProviderOptionControl(
    option: ProviderOption,
    value: String,
    enabled: Boolean,
    onValueChange: (String, String) -> Unit,
) {
    val semantics = Modifier
        .testTag("provider-option-${option.id}")
        .semantics {
            contentDescription = buildString {
                append(option.name)
                if (option.description.isNotBlank()) append(". ${option.description}")
            }
        }
    when (Selections.optionKind(option)) {
        ProviderOptionKind.TOGGLE -> {
            val selected = Selections.isOn(value)
            FilterChip(
                selected = selected,
                onClick = { onValueChange(option.id, (!selected).toString()) },
                enabled = enabled,
                label = { Text(option.name) },
                modifier = semantics,
            )
        }

        ProviderOptionKind.CHOICE -> {
            var expanded by remember(option.id) { mutableStateOf(false) }
            Box(semantics) {
                AssistChip(
                    onClick = { expanded = true },
                    enabled = enabled,
                    label = { Text(Selections.optionLabel(option, value)) },
                )
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    option.choices.forEach { choice ->
                        DropdownMenuItem(
                            text = { Text(Selections.choiceName(choice)) },
                            onClick = {
                                expanded = false
                                onValueChange(option.id, choice.value_)
                            },
                        )
                    }
                }
            }
        }

        ProviderOptionKind.TEXT -> OutlinedTextField(
            value = value,
            onValueChange = { onValueChange(option.id, it) },
            enabled = enabled,
            singleLine = true,
            label = { Text(option.name) },
            modifier = semantics.width(180.dp),
        )
    }
}
