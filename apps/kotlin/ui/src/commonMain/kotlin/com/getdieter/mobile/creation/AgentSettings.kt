@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.creation

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.design.*

/** Agent, model, effort and provider options as grouped rows with menus. */
@Composable
internal fun AgentSettings(agent: AgentControlsState?, onChoice: (AgentChoice) -> Unit) {
    if (agent == null) {
        Row(Modifier.fillMaxWidth().padding(24.dp), horizontalArrangement = Arrangement.Center) {
            Spinner()
        }
        return
    }
    val rows =
        buildList<@Composable (Position) -> Unit> {
            add { position ->
                PickerRow(
                    "Agent",
                    agent.provider_label,
                    agent.providers.map { it.id to it.name },
                    agent.selection?.provider.orEmpty(),
                    agent.provider_enabled,
                    position,
                    Glyph.SPARKLES,
                ) {
                    onChoice(AgentChoice(provider = it))
                }
            }
            add { position ->
                PickerRow(
                    "Model",
                    agent.model_label,
                    agent.models.map { it.id to it.name },
                    agent.selection?.model.orEmpty(),
                    agent.model_enabled,
                    position,
                    Glyph.CPU,
                ) {
                    onChoice(AgentChoice(model = it))
                }
            }
            if (agent.effort_choices.isNotEmpty())
                add { position ->
                    PickerRow(
                        "Effort",
                        agent.effort_label,
                        agent.effort_choices.map { it.id to it.name },
                        agent.effort_value,
                        agent.effort_enabled,
                        position,
                        Glyph.BOLT,
                    ) {
                        onChoice(AgentChoice(effort = it))
                    }
                }
            // Single choices cannot be disabled, so an account that is not ready says why and
            // the core blocks sending with it (AgentControlsState.account_blocked).
            if (agent.accounts.isNotEmpty())
                add { position ->
                    PickerRow(
                        "Account",
                        agent.account_label,
                        agent.accounts.map { it.id to it.label },
                        agent.selection?.account_id.orEmpty(),
                        agent.account_enabled,
                        position,
                        Glyph.KEY,
                        details =
                            agent.accounts.associate { account ->
                                account.id to
                                    listOf(
                                            if (account.is_default) "Default" else "",
                                            account.detail,
                                            account.reason,
                                        )
                                        .filter { it.isNotEmpty() }
                                        .joinToString(" · ")
                            },
                    ) {
                        onChoice(AgentChoice(account = it))
                    }
                }
            else if (agent.account_hint.isNotEmpty())
                add { position ->
                    ListRow(
                        "Account",
                        Modifier.testTag("agent-account-hint"),
                        position = position,
                        subtitle = agent.account_hint,
                        glyph = Glyph.KEY,
                        subtitleMaxLines = 3,
                    )
                }
        }
    Group(rows) { row, position -> row(position) }
    if (agent.options.isNotEmpty()) {
        SectionHeader("Options")
        Group(agent.options) { option, position ->
            val value = agent.option_values[option.id].orEmpty()
            val enabled = agent.option_enabled[option.id] == true
            when (agent.option_kinds[option.id]) {
                AgentOptionKind.AGENT_OPTION_KIND_TOGGLE ->
                    ListRow(
                        option.name,
                        position = position,
                        enabled = enabled,
                        trailing = {
                            DSwitch(
                                agent.option_on[option.id] == true,
                                {
                                    onChoice(
                                        AgentChoice(
                                            option = AgentOptionChoice(option.id, it.toString())
                                        )
                                    )
                                },
                                enabled = enabled,
                            )
                        },
                    )
                AgentOptionKind.AGENT_OPTION_KIND_CHOICE ->
                    PickerRow(
                        option.name,
                        option.choices.firstOrNull { it.value_ == value }?.name?.ifEmpty { value }
                            ?: value,
                        option.choices.map { it.value_ to it.name.ifEmpty { it.value_ } },
                        value,
                        enabled,
                        position,
                    ) {
                        onChoice(AgentChoice(option = AgentOptionChoice(option.id, it)))
                    }
                else ->
                    GroupItem(position) {
                        Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                            Text(option.name, style = type.footnote, color = palette.secondaryLabel)
                            BasicTextField(
                                value,
                                {
                                    onChoice(AgentChoice(option = AgentOptionChoice(option.id, it)))
                                },
                                Modifier.fillMaxWidth().padding(top = 4.dp),
                                enabled = enabled,
                                textStyle = type.body.copy(color = palette.label),
                                cursorBrush = SolidColor(palette.info),
                            )
                        }
                    }
            }
        }
    }
}
