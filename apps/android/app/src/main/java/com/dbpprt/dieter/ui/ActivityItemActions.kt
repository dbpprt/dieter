package com.dbpprt.dieter.ui

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.v1.Card

internal data class ActivityItemActions(
    val onRename: (Card, String) -> Unit,
    val onArchive: (Card) -> Unit,
    val onTogglePin: (Card) -> Unit,
    val onMoveToFolder: ((Card) -> Unit)? = null,
    val enabled: Boolean = true,
)

/** One action surface for feed rows and both timeline layouts. */
@Composable
internal fun ActivityItem(
    card: Card,
    onOpen: (Card) -> Unit,
    actions: ActivityItemActions?,
    modifier: Modifier = Modifier,
    color: Color = DieterSurface,
    shape: Shape = RoundedCornerShape(16.dp),
    content: @Composable () -> Unit,
) {
    var menuOpen by remember(card.id) { mutableStateOf(false) }
    var renameOpen by remember(card.id) { mutableStateOf(false) }
    var title by remember(card.id) { mutableStateOf(card.title) }
    val enabled = actions?.enabled == true
    Surface(color = color, shape = shape, modifier = modifier.clip(shape).combinedClickable(
        role = Role.Button,
        onClickLabel = "Open conversation",
        onClick = { onOpen(card) },
        onLongClickLabel = "Conversation actions",
        onLongClick = actions?.let { { menuOpen = true } },
    )) {
        Box {
            Column(Modifier.fillMaxWidth()) { content() }
            if (actions != null) DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(text = { Text("Open") }, leadingIcon = { Icon(Icons.AutoMirrored.Outlined.OpenInNew, null) },
                    modifier = Modifier.testTag("activity-open-${card.id}"),
                    onClick = { menuOpen = false; onOpen(card) })
                DropdownMenuItem(text = { Text("Rename") }, leadingIcon = { Icon(Icons.Outlined.Edit, null) },
                    enabled = enabled, modifier = Modifier.testTag("activity-rename-${card.id}"),
                    onClick = { menuOpen = false; title = card.title; renameOpen = true })
                if (card.scope == "chat") {
                    DropdownMenuItem(text = { Text(if (card.pinned) "Unpin" else "Pin") },
                        leadingIcon = { Icon(Icons.Outlined.PushPin, null) }, enabled = enabled,
                        modifier = Modifier.testTag("activity-pin-${card.id}"),
                        onClick = { menuOpen = false; actions.onTogglePin(card) })
                    actions.onMoveToFolder?.let { move ->
                        DropdownMenuItem(text = { Text("Move to folder") }, leadingIcon = { Icon(Icons.Outlined.Folder, null) },
                            enabled = enabled, modifier = Modifier.testTag("activity-folder-${card.id}"),
                            onClick = { menuOpen = false; move(card) })
                    }
                }
                DropdownMenuItem(text = { Text("Archive") }, leadingIcon = { Icon(Icons.Outlined.Archive, null) },
                    enabled = enabled, modifier = Modifier.testTag("activity-archive-${card.id}"),
                    onClick = { menuOpen = false; actions.onArchive(card) })
            }
        }
    }
    if (renameOpen && actions != null) AlertDialog(
        onDismissRequest = { renameOpen = false },
        title = { Text(if (card.scope == "chat") "Rename chat" else "Rename card") },
        text = {
            OutlinedTextField(title, { title = it }, label = { Text("Title") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("activity-rename-title-${card.id}"))
        },
        dismissButton = { TextButton(onClick = { renameOpen = false }) { Text("Cancel") } },
        confirmButton = {
            TextButton(enabled = enabled && title.isNotBlank(), modifier = Modifier.testTag("activity-rename-confirm-${card.id}"),
                onClick = { renameOpen = false; actions.onRename(card, title.trim()) }) { Text("Save") }
        },
    )
}
