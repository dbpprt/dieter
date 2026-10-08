@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.mobile.icons.*

@Composable
internal fun CreationScreen(store: MobileStore) {
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val intent by store.creationIntent.collectAsState()
    val preview by store.creationPreview.collectAsState()
    val chat by store.creatingChat.collectAsState()
    val busy by store.busy.collectAsState()
    val pick =
        rememberAttachmentPicker(
            { added ->
                com.dbpprt.dieter.core.composition.Attachments.appending(
                        store.creationIntent.value.attachments,
                        added,
                    )
                    .fold(
                        { store.preview(store.creationIntent.value.copy(attachments = it)) },
                        { store.error.value = it.message.orEmpty() },
                    )
            },
            { store.error.value = it },
        )
    val defaults = intent
    val project = workspace.projects.firstOrNull { it.id == defaults.project_id }
    Column(Modifier.fillMaxSize().imePadding()) {
        PageHeader(if (chat) "New chat" else "New card", back = store::back) {
            IconButton(
                onClick = {
                    focus.clearFocus()
                    keyboard?.hide()
                }
            ) {
                Icon(Icons.Outlined.KeyboardHide, "Hide keyboard")
            }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                FormSection("Destination") {
                    ChoiceChip(
                        project?.name ?: "Choose a project",
                        workspace.projects.map { it.id to it.name },
                    ) { id ->
                        store.preview(intent.copy(project_id = id, board_id = "", checkout_id = ""))
                    }
                    if (!chat)
                        ChoiceChip(
                            workspace.boards.firstOrNull { it.id == defaults.board_id }?.name
                                ?: "Choose a board",
                            workspace.boards
                                .filter { it.project_id == defaults.project_id }
                                .map { it.id to it.name },
                        ) {
                            store.preview(defaults.copy(board_id = it))
                        }
                    Text("Run on", style = MaterialTheme.typography.labelLarge)
                    ChoiceChip(
                        project
                            ?.checkouts
                            ?.firstOrNull { it.id == defaults.checkout_id }
                            ?.let {
                                session.machines
                                    .firstOrNull { machine -> machine.id == it.daemon_id }
                                    ?.display_name ?: it.name
                            } ?: "Choose a checkout",
                        project?.checkouts.orEmpty().map { checkout ->
                            checkout.id to
                                ((session.machines
                                    .firstOrNull { it.id == checkout.daemon_id }
                                    ?.display_name ?: checkout.name) + " · " + checkout.name)
                        },
                    ) {
                        store.preview(defaults.copy(checkout_id = it))
                    }
                    if (preview.destination_status.isNotEmpty())
                        Text(
                            preview.destination_status,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                }
                MobileTextField(
                    intent.title,
                    { store.preview(defaults.copy(title = it)) },
                    label = { Text(if (chat) "Chat title" else "Task title") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                MobileTextField(
                    intent.prompt,
                    { store.preview(defaults.copy(prompt = it)) },
                    label = { Text("What should we do?") },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp),
                    minLines = 5,
                )
                AttachmentChips(
                    intent.attachments,
                    onRemove = { index ->
                        store.preview(
                            intent.copy(
                                attachments =
                                    intent.attachments.filterIndexed { i, _ -> i != index }
                            )
                        )
                    },
                )
                OutlinedButton(onClick = pick, enabled = intent.attachments.size < 4) {
                    Icon(Icons.Outlined.AttachFile, null)
                    Text("Attach images or files")
                }
                Text(
                    com.dbpprt.dieter.core.composition.Attachments.LIMITS,
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.onSurfaceVariant,
                )
                FormSection("Agent") {
                    AgentSettings(preview.agent) { choice -> store.preview(defaults, choice) }
                }
                FormSection("Workspace") {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("worktree" to "Worktree", "project" to "Project").forEach {
                            (key, title) ->
                            FilterChip(
                                defaults.workspace_mode == key,
                                { store.preview(defaults.copy(workspace_mode = key)) },
                                label = { Text(title) },
                                leadingIcon = {
                                    Icon(
                                        if (key == "worktree") Icons.Outlined.AccountTree
                                        else Icons.Outlined.Folder,
                                        null,
                                        Modifier.size(16.dp),
                                    )
                                },
                            )
                        }
                    }
                    Text(
                        preview.workspace_detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                    )
                    if (defaults.workspace_mode == "worktree") {
                        MobileTextField(
                            defaults.workspace_branch,
                            { store.preview(defaults.copy(workspace_branch = it)) },
                            label = { Text("Branch (automatic if empty)") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        MobileTextField(
                            defaults.workspace_base_branch,
                            { store.preview(defaults.copy(workspace_base_branch = it)) },
                            label = { Text("Base branch") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                if (!chat)
                    FormSection("Labels") {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            workspace.boards
                                .firstOrNull { it.id == defaults.board_id }
                                ?.labels
                                .orEmpty()
                                .forEach { label ->
                                    FilterChip(
                                        label.id in defaults.label_ids,
                                        {
                                            store.preview(
                                                defaults.copy(
                                                    label_ids =
                                                        if (label.id in defaults.label_ids)
                                                            defaults.label_ids - label.id
                                                        else defaults.label_ids + label.id
                                                )
                                            )
                                        },
                                        label = { Text(label.name) },
                                    )
                                }
                        }
                    }
                if (preview.offline_hint.isNotEmpty())
                    Text(preview.offline_hint, style = MaterialTheme.typography.bodySmall)
                if (preview.problem.isNotEmpty())
                    Text(
                        preview.problem,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                    )
                Text(
                    preview.summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant,
                )
                Button(
                    onClick = {
                        store.action {
                            store.openCard(
                                store.submitCreation(
                                    defaults.copy(
                                        title = intent.title,
                                        prompt = intent.prompt,
                                        lane = "running",
                                    )
                                )
                            )
                        }
                    },
                    enabled = preview.problem.isEmpty() && intent.prompt.isNotBlank() && !busy,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) {
                    Text(if (chat) "Start chat" else "Start working")
                }
                if (!chat)
                    OutlinedButton(
                        onClick = {
                            store.action {
                                store.openCard(
                                    store.submitCreation(
                                        defaults.copy(
                                            title = intent.title,
                                            prompt = intent.prompt,
                                            lane = "todo",
                                        )
                                    )
                                )
                            }
                        },
                        enabled = preview.problem.isEmpty() && intent.prompt.isNotBlank() && !busy,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    ) {
                        Text("Save to Todo")
                    }
            }
        }
    }
}

@Composable
internal fun FormSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(14.dp), color = colors.surface) {
        Column(
            Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            content()
        }
    }
}

@Composable
internal fun AgentSettings(agent: AgentControlsState?, onChoice: (AgentChoice) -> Unit) {
    if (agent == null) {
        Text("Loading agent models…", color = colors.onSurfaceVariant)
        return
    }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ChoiceChip(
            agent.provider_label,
            agent.providers.map { it.id to it.name },
            agent.provider_enabled,
        ) {
            onChoice(AgentChoice(provider = it))
        }
        ChoiceChip(agent.model_label, agent.models.map { it.id to it.name }, agent.model_enabled) {
            onChoice(AgentChoice(model = it))
        }
        ChoiceChip(
            agent.effort_label,
            agent.effort_choices.map { it.id to it.name },
            agent.effort_enabled,
        ) {
            onChoice(AgentChoice(effort = it))
        }
    }
    agent.options.forEach { option ->
        val value = agent.option_values[option.id].orEmpty()
        val enabled = agent.option_enabled[option.id] == true
        when (agent.option_kinds[option.id]) {
            AgentOptionKind.AGENT_OPTION_KIND_TOGGLE ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(option.name, Modifier.weight(1f))
                    Switch(
                        agent.option_on[option.id] == true,
                        {
                            onChoice(
                                AgentChoice(option = AgentOptionChoice(option.id, it.toString()))
                            )
                        },
                        enabled = enabled,
                    )
                }
            AgentOptionKind.AGENT_OPTION_KIND_CHOICE ->
                ChoiceChip(
                    option.name + ": " + value,
                    option.choices.map { it.value_ to it.name.ifEmpty { it.value_ } },
                    enabled,
                ) {
                    onChoice(AgentChoice(option = AgentOptionChoice(option.id, it)))
                }
            else ->
                MobileTextField(
                    value,
                    { onChoice(AgentChoice(option = AgentOptionChoice(option.id, it))) },
                    label = { Text(option.name) },
                    enabled = enabled,
                    modifier = Modifier.fillMaxWidth(),
                )
        }
    }
}
