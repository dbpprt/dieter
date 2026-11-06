package com.getdieter.mobile.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.DeleteInboxRule
import com.getdieter.client.v1.InboxRule
import com.getdieter.client.v1.NavigationCommand
import com.getdieter.core.activity.InboxRuleText
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*

/** The account's Inbox rules: which projects and labels the Inbox shows or hides. */
@Composable
internal fun InboxRulesSheet(store: MobileStore, dismiss: () -> Unit) {
    val navigation by store.workspace.navigation.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    var editing by remember { mutableStateOf<InboxRule?>(null) }
    val projectNames = workspace.projects.associate { it.id to it.name }
    val labelNames = workspace.boards.flatMap { it.labels }.associate { it.id to it.name }
    Sheet("Inbox Rules", dismiss, size = SheetSize.LARGE) {
        SectionHeader("Rules")
        Group(navigation.inbox_rules + listOf<InboxRule?>(null)) { rule, position ->
            if (rule == null)
                ListRow(
                    "New rule…",
                    position = position,
                    glyph = Glyph.ADD,
                    onClick = { editing = InboxRule(enabled = true, hide = true) },
                    modifier = Modifier.testTag("inbox-rule-new"),
                )
            else
                ListRow(
                    rule.name.ifBlank { if (rule.hide) "Hide" else "Show only" },
                    position = position,
                    subtitle = rule.summary(projectNames, labelNames),
                    subtitleMaxLines = 3,
                    onClick = { editing = rule },
                    trailing = {
                        DSwitch(rule.enabled, { store.saveInboxRule(rule.copy(enabled = it)) })
                    },
                    modifier = Modifier.testTag("inbox-rule-${rule.id}"),
                )
        }
        SectionFooter(
            "A conversation that matches a hiding rule is left out of the Inbox. While any " +
                "showing rule is on, the Inbox lists only conversations that match one. Rules sync " +
                "to all your devices.",
            Modifier.padding(horizontal = 20.dp),
        )
    }
    editing?.let { rule -> InboxRuleEditor(store, rule) { editing = null } }
}

private fun InboxRule.summary(projects: Map<String, String>, labels: Map<String, String>) =
    InboxRuleText.summary(
        hide,
        match_all,
        project_ids.map { projects[it] ?: "Unknown" },
        label_ids.map { labels[it] ?: "Unknown" },
    ) + if (enabled) "" else " (off)"

private fun MobileStore.saveInboxRule(rule: InboxRule) =
    command(Command(navigation = NavigationCommand(save_inbox_rule = rule)))

@Composable
private fun InboxRuleEditor(store: MobileStore, rule: InboxRule, dismiss: () -> Unit) {
    val workspace by store.workspace.slice.collectAsState()
    var name by remember(rule.id) { mutableStateOf(rule.name) }
    var hide by remember(rule.id) { mutableStateOf(rule.hide) }
    var matchAll by remember(rule.id) { mutableStateOf(rule.match_all) }
    var enabled by remember(rule.id) { mutableStateOf(rule.enabled) }
    var projects by remember(rule.id) { mutableStateOf(rule.project_ids.toSet()) }
    var labels by remember(rule.id) { mutableStateOf(rule.label_ids.toSet()) }
    var deleting by remember { mutableStateOf(false) }
    val projectNames = workspace.projects.associate { it.id to it.name }
    Sheet(
        if (rule.id.isEmpty()) "New Rule" else "Edit Rule",
        dismiss,
        confirm =
            ChromeAction(
                "save-inbox-rule",
                "Save",
                Glyph.CHECK,
                enabled = projects.isNotEmpty() || labels.isNotEmpty(),
            ) {
                store.saveInboxRule(
                    rule.copy(
                        name = name.trim(),
                        hide = hide,
                        match_all = matchAll,
                        enabled = enabled,
                        project_ids = projects.sorted(),
                        label_ids = labels.sorted(),
                    )
                )
                dismiss()
            },
    ) {
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth(),
                label = { Text("Name") },
                placeholder = { Text("Optional") },
                singleLine = true,
            )
            Segmented(listOf("Hide", "Show only"), if (hide) 0 else 1, { hide = it == 0 })
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("On", Modifier.weight(1f), style = type.body, color = palette.label)
                DSwitch(enabled, { enabled = it })
            }
        }
        SectionHeader("Projects")
        Group(workspace.projects.filterNot { it.archived }) { project, position ->
            ListRow(
                project.name,
                position = position,
                accessory = if (project.id in projects) Accessory.CHECK else Accessory.NONE,
                onClick = {
                    projects =
                        if (project.id in projects) projects - project.id else projects + project.id
                },
                modifier = Modifier.testTag("inbox-rule-project-${project.id}"),
            )
        }
        for (board in workspace.boards.filter { it.labels.isNotEmpty() }) {
            SectionHeader("Labels · ${projectNames[board.project_id].orEmpty()} · ${board.name}")
            Group(board.labels) { label, position ->
                ListRow(
                    label.name,
                    position = position,
                    leading = {
                        Box(Modifier.size(14.dp).background(labelColor(label.color), CircleShape))
                    },
                    accessory = if (label.id in labels) Accessory.CHECK else Accessory.NONE,
                    onClick = {
                        labels = if (label.id in labels) labels - label.id else labels + label.id
                    },
                    modifier = Modifier.testTag("inbox-rule-label-${label.id}"),
                )
            }
        }
        if (projects.isNotEmpty() && labels.isNotEmpty()) {
            SectionHeader("A conversation matches when")
            FormColumn {
                Segmented(
                    listOf("Either matches", "Both match"),
                    if (matchAll) 1 else 0,
                    { matchAll = it == 1 },
                )
            }
        }
        if (rule.id.isNotEmpty())
            FormColumn {
                DButton(
                    "Delete rule",
                    { deleting = true },
                    Modifier.fillMaxWidth(),
                    kind = ButtonKind.DESTRUCTIVE,
                    large = true,
                )
            }
    }
    if (deleting)
        ConfirmDialog(
            "Delete this rule?",
            "The Inbox shows its conversations again, on every device.",
            "Delete",
            {
                store.command(
                    Command(
                        navigation = NavigationCommand(delete_inbox_rule = DeleteInboxRule(rule.id))
                    )
                )
                deleting = false
                dismiss()
            },
            { deleting = false },
            destructive = true,
        )
}
