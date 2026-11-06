@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.admin

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.admin.Labels
import com.getdieter.core.admin.PromptTemplates
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*

@Composable
internal fun BoardSettings(store: MobileStore, boardId: String, dismiss: () -> Unit) {
    val workspace by store.workspace.slice.collectAsState()
    val board = workspace.boards.firstOrNull { it.id == boardId } ?: return
    var name by remember(board.id) { mutableStateOf(board.name) }
    var remote by remember(board.id) { mutableStateOf(board.base_remote) }
    var publish by
        remember(board.id) { mutableStateOf(board.remote_publish_mode.ifEmpty { "manual" }) }
    var archive by
        remember(board.id) { mutableStateOf(board.done_archive_policy.ifEmpty { "never" }) }
    var prompt by remember(board.id) { mutableStateOf(board.prompt_template) }
    val promptProblem =
        prompt.takeIf { it.isNotBlank() }?.let { PromptTemplates.validate(it, context = true) }
    var editingLabel by remember { mutableStateOf<com.getdieter.api.v1.Label?>(null) }
    var newLabel by remember { mutableStateOf(false) }
    Sheet(
        "Board Settings",
        dismiss,
        confirm =
            ChromeAction(
                "save-board",
                "Save",
                Glyph.CHECK,
                enabled = name.isNotBlank() && promptProblem == null,
            ) {
                store.action {
                    store.core.dispatch(
                        Command(
                            admin = AdminCommand(rename_board = AdminRenameBoard(board.id, name))
                        )
                    )
                    store.core.dispatch(
                        Command(
                            admin =
                                AdminCommand(
                                    set_git_settings = AdminGitSettings(board.id, remote, publish)
                                )
                        )
                    )
                    store.core.dispatch(
                        Command(
                            admin =
                                AdminCommand(
                                    set_archive_policy = AdminArchivePolicy(board.id, archive)
                                )
                        )
                    )
                    if (prompt != board.prompt_template)
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        set_board_prompt =
                                            AdminScopedPrompt(
                                                board.id,
                                                prompt.takeIf { it.isNotBlank() },
                                            )
                                    )
                            )
                        )
                    dismiss()
                }
            },
    ) {
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth(),
                label = { Text("Name") },
                placeholder = { Text("Board name") },
                singleLine = true,
            )
        }
        SectionHeader("Labels")
        Group(board.labels + listOf<com.getdieter.api.v1.Label?>(null)) { label, position ->
            if (label == null)
                ListRow(
                    "New label…",
                    position = position,
                    glyph = Glyph.ADD,
                    onClick = { newLabel = true },
                )
            else
                ListRow(
                    label.name,
                    position = position,
                    subtitle = label.instructions.takeIf { it.isNotEmpty() },
                    leading = {
                        Box(Modifier.size(14.dp).background(labelColor(label.color), CircleShape))
                    },
                    accessory = Accessory.CHEVRON,
                    onClick = { editingLabel = label },
                )
        }
        SectionHeader("Git")
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Publish",
                mapOf(
                    "manual" to "Manual",
                    "push_base" to "Push base",
                    "pull_request" to "Pull request",
                )[publish] ?: publish,
                listOf(
                    "manual" to "Manual",
                    "push_base" to "Push base",
                    "pull_request" to "Pull request",
                ),
                publish,
                true,
                position,
                Glyph.PUSH,
            ) {
                publish = it
            }
        }
        FormColumn {
            MobileTextField(
                remote,
                { remote = it },
                Modifier.fillMaxWidth(),
                label = { Text("Base remote") },
                placeholder = { Text("Base remote") },
                singleLine = true,
            )
        }
        SectionHeader("Done cards")
        val policies =
            listOf(
                "never" to "Keep",
                "immediately" to "Archive immediately",
                "after_1_day" to "After 1 day",
                "after_7_days" to "After 7 days",
                "after_30_days" to "After 30 days",
                "after_90_days" to "After 90 days",
            )
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Archive",
                policies.firstOrNull { it.first == archive }?.second ?: archive,
                policies,
                archive,
                true,
                position,
                Glyph.ARCHIVE,
            ) {
                archive = it
            }
        }
        SectionHeader("Prompt template override")
        FormColumn {
            MobileTextField(
                prompt,
                { prompt = it },
                Modifier.fillMaxWidth(),
                label = { Text("Board template") },
                placeholder = { Text("Empty inherits the project and global template") },
                minLines = 3,
            )
        }
        SectionFooter(
            promptProblem
                ?: "Replaces the whole agent prompt for this board. It must place " +
                    "{{project.instructions_block}} and {{labels.instructions_block}} once.",
            Modifier.padding(horizontal = 20.dp),
        )
    }
    if (newLabel) LabelEditor(store, board.id, null) { newLabel = false }
    editingLabel?.let { label -> LabelEditor(store, board.id, label) { editingLabel = null } }
}

@Composable
private fun LabelEditor(
    store: MobileStore,
    boardId: String,
    label: com.getdieter.api.v1.Label?,
    dismiss: () -> Unit,
) {
    var name by remember { mutableStateOf(label?.name.orEmpty()) }
    var color by remember { mutableStateOf(label?.color ?: Labels.PALETTE.first()) }
    var instructions by remember { mutableStateOf(label?.instructions.orEmpty()) }
    var deleting by remember { mutableStateOf(false) }
    Sheet(
        if (label == null) "New Label" else "Edit Label",
        dismiss,
        confirm =
            ChromeAction(
                "save-label",
                "Save",
                Glyph.CHECK,
                enabled = Labels.validate(name, color) == null,
            ) {
                val value =
                    AdminLabel(
                        boardId,
                        label?.id.orEmpty(),
                        name = name,
                        color = color,
                        instructions = instructions,
                    )
                store.command(
                    Command(
                        admin =
                            if (label == null) AdminCommand(create_label = value)
                            else AdminCommand(update_label = value)
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
                placeholder = { Text("Label name") },
                singleLine = true,
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Labels.COLORS.forEach { option ->
                    val selected = option.value.equals(color, true)
                    Box(
                        Modifier.size(36.dp)
                            .clip(CircleShape)
                            .border(
                                if (selected) 2.5.dp else 0.dp,
                                if (selected) palette.label else Color.Transparent,
                                CircleShape,
                            )
                            .padding(if (selected) 4.dp else 0.dp)
                            .clip(CircleShape)
                            .background(labelColor(option.value))
                            .pressable(onClick = { color = option.value })
                            .testTag("label-color-${option.name}")
                    )
                }
            }
            MobileTextField(
                instructions,
                { instructions = it },
                Modifier.fillMaxWidth(),
                label = { Text("Agent instructions") },
                placeholder = { Text("Instructions for cards with this label") },
                minLines = 2,
            )
            if (label != null)
                DButton(
                    "Delete label",
                    { deleting = true },
                    Modifier.fillMaxWidth(),
                    kind = ButtonKind.DESTRUCTIVE,
                    large = true,
                )
        }
    }
    if (deleting && label != null)
        ConfirmDialog(
            "Delete “${label.name}”?",
            "Cards keep working without this label.",
            "Delete",
            {
                store.command(
                    Command(admin = AdminCommand(delete_label = AdminLabel(boardId, label.id)))
                )
                deleting = false
                dismiss()
            },
            { deleting = false },
            destructive = true,
        )
}

@Composable
internal fun ArchivedCards(store: MobileStore, boardId: String, dismiss: () -> Unit) {
    var cards by remember { mutableStateOf<List<Card>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(boardId) {
        store.action {
            cards =
                store.core
                    .dispatch(Command(list_archived_cards = ListArchivedCards(boardId)))
                    .cards
                    ?.cards
                    .orEmpty()
            loading = false
        }
    }
    Sheet("Archived Cards", dismiss) {
        if (loading)
            Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                Spinner(Modifier.size(24.dp))
            }
        else if (cards.isEmpty())
            EmptyState(
                Glyph.ARCHIVE,
                "No archived cards",
                "Archived cards from this board appear here.",
            )
        Group(cards) { card, position ->
            ListRow(
                card.title.ifBlank { "Untitled card" },
                position = position,
                subtitle = card.summary.takeIf { it.isNotBlank() },
                trailing = {
                    DButton(
                        "Restore",
                        {
                            store.action {
                                store.core.dispatch(
                                    Command(restore_card = RestoreCard(card_id = card.id))
                                )
                                cards = cards.filter { it.id != card.id }
                            }
                        },
                        kind = ButtonKind.PLAIN,
                    )
                },
            )
        }
    }
}
