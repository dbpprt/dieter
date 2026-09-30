package com.dbpprt.dieter.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.core.navigation.NavigationEditor
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterShell

/** Shared folder edits; the core queues each one durably and syncs it across the account. */
internal interface FolderEditor {
    fun createFolder(scope: FolderScope, name: String, itemId: String? = null)
    fun renameFolder(scope: FolderScope, id: String, name: String)
    fun deleteFolder(scope: FolderScope, id: String)
    fun setFolderExpanded(scope: FolderScope, id: String, expanded: Boolean)
    fun moveToFolder(scope: FolderScope, itemId: String, folderId: String?)
}

@Composable
internal fun NewNavigationFolderButton(
    scope: FolderScope,
    folders: List<NavigationFolder>,
    editor: FolderEditor,
) {
    var open by rememberSaveable { mutableStateOf(false) }
    IconButton(onClick = { open = true }, modifier = Modifier.testTag("new-${scope.name.lowercase()}-folder")) {
        Icon(Icons.Outlined.CreateNewFolder, if (scope == FolderScope.CHATS) "New chat folder" else "New project folder")
    }
    if (open) NavigationFolderNameDialog(scope, folders, onDismiss = { open = false }) {
        editor.createFolder(scope, it)
        open = false
    }
}

@Composable
internal fun NavigationFolderHeader(
    folder: NavigationFolder,
    count: Int,
    scope: FolderScope,
    folders: List<NavigationFolder>,
    editor: FolderEditor,
    revealSearchResults: Boolean = false,
    summary: String? = null,
) {
    var options by remember { mutableStateOf(false) }
    var rename by rememberSaveable { mutableStateOf(false) }
    var delete by rememberSaveable { mutableStateOf(false) }
    val expanded = folder.expanded || revealSearchResults
    val chatFolder = scope == FolderScope.CHATS
    val folderTint = if (chatFolder) DieterAmber else DieterShell
    Row(Modifier.fillMaxWidth().then(if (chatFolder) Modifier.padding(top = 4.dp)
        .background(folderTint.copy(alpha = 0.07f), RoundedCornerShape(12.dp)) else Modifier),
        verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).heightIn(min = 48.dp)
                .clickable { editor.setFolderExpanded(scope, folder.id, !folder.expanded) }
                .testTag("folder-${folder.id}")
                .semantics { heading(); stateDescription = if (expanded) "Expanded" else "Collapsed" }
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Outlined.KeyboardArrowDown, if (expanded) "Collapse ${folder.name}" else "Expand ${folder.name}",
                tint = DieterMuted, modifier = Modifier.size(20.dp).rotate(if (expanded) 0f else -90f))
            Icon(Icons.Outlined.Folder, null, tint = folderTint, modifier = Modifier.size(20.dp))
            if (summary == null) {
                if (chatFolder) {
                    Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                        Text(folder.name, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text("Folder · $count ${if (count == 1) "chat" else "chats"}", color = DieterMuted,
                            style = androidx.compose.material3.MaterialTheme.typography.labelSmall)
                    }
                } else {
                    Text(folder.name, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text("$count", color = DieterMuted)
                }
            } else {
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(folder.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.width(7.dp))
                        androidx.compose.material3.Surface(
                            shape = androidx.compose.foundation.shape.CircleShape,
                            color = DieterShell.copy(alpha = 0.16f),
                        ) {
                            Text("$count", color = DieterShell, modifier = Modifier.padding(horizontal = 7.dp, vertical = 1.dp))
                        }
                    }
                    Text(summary, color = DieterMuted, style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        Box {
            IconButton(onClick = { options = true }, modifier = Modifier.testTag("folder-options-${folder.id}")) {
                Icon(Icons.Outlined.MoreVert, "Options for ${folder.name}", tint = DieterMuted)
            }
            DropdownMenu(options, onDismissRequest = { options = false }) {
                DropdownMenuItem(text = { Text("Rename folder") }, onClick = { options = false; rename = true })
                DropdownMenuItem(text = { Text("Delete folder") }, onClick = { options = false; delete = true })
            }
        }
    }
    if (rename) NavigationFolderNameDialog(scope, folders, folder, { rename = false }) { name ->
        editor.renameFolder(scope, folder.id, name)
        rename = false
    }
    if (delete) AlertDialog(
        onDismissRequest = { delete = false },
        title = { Text("Delete ${folder.name}?") },
        text = { Text(if (scope == FolderScope.CHATS) "Chats in this folder will return to their project groups. No chats will be deleted."
            else "Projects in this folder will return to the unfiled list. No projects will be deleted.") },
        dismissButton = { TextButton(onClick = { delete = false }) { Text("Cancel") } },
        confirmButton = { TextButton(onClick = { editor.deleteFolder(scope, folder.id); delete = false },
            modifier = Modifier.testTag("delete-folder-confirm")) { Text("Delete folder") } },
    )
}

@Composable
internal fun NavigationFolderNameDialog(
    scope: FolderScope,
    folders: List<NavigationFolder>,
    folder: NavigationFolder? = null,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var name by rememberSaveable(folder?.id) { mutableStateOf(folder?.name.orEmpty()) }
    val problem = NavigationEditor.nameProblem(name, folders, folder?.id)
    val available = problem == null
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (folder != null) "Rename folder" else if (scope == FolderScope.CHATS) "New chat folder" else "New project folder") },
        text = {
            OutlinedTextField(
                value = name, onValueChange = { name = it }, singleLine = true,
                label = { Text("Folder name") },
                isError = name.isNotBlank() && !available,
                supportingText = { if (name.isNotBlank()) problem?.let { Text(it) } },
                modifier = Modifier.fillMaxWidth().testTag("folder-name"),
            )
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        confirmButton = { TextButton(onClick = { onSave(name.trim()) }, enabled = available,
            modifier = Modifier.testTag("save-folder")) { Text(if (folder == null) "Create" else "Save") } },
    )
}

@Composable
internal fun MoveToNavigationFolderDialog(
    itemID: String,
    scope: FolderScope,
    folders: List<NavigationFolder>,
    editor: FolderEditor,
    onDismiss: () -> Unit,
) {
    var creating by rememberSaveable { mutableStateOf(false) }
    if (creating) {
        NavigationFolderNameDialog(scope, folders, onDismiss = { creating = false }) { name ->
            editor.createFolder(scope, name, itemID)
            onDismiss()
        }
    } else {
        val selected = folders.firstOrNull { itemID in it.itemIds }?.id
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Move to folder") },
            text = {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
                    FolderDestination("No folder", selected == null, "move-no-folder") {
                        editor.moveToFolder(scope, itemID, null); onDismiss()
                    }
                    folders.forEach { folder ->
                        FolderDestination(folder.name, selected == folder.id, "move-folder-${folder.id}") {
                            editor.moveToFolder(scope, itemID, folder.id); onDismiss()
                        }
                    }
                    TextButton(onClick = { creating = true }, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.Outlined.CreateNewFolder, null)
                        Spacer(Modifier.width(8.dp))
                        Text("New folder")
                    }
                }
            },
            confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        )
    }
}

@Composable
private fun FolderDestination(name: String, selected: Boolean, tag: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag)) {
        Text(name, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
        if (selected) Icon(Icons.Outlined.Check, "Current folder")
    }
}

@androidx.compose.runtime.Composable
internal fun NavigationSyncStatus(state: DieterUiState) {
    state.peerSyncWarnings.forEach { warning ->
        androidx.compose.material3.Text(warning,
            modifier = androidx.compose.ui.Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
            style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
            color = androidx.compose.material3.MaterialTheme.colorScheme.error)
    }
    if (state.navigationPendingCount > 0 || state.navigationSyncError != null) {
        androidx.compose.material3.Text(
            text = listOfNotNull(
                "${state.navigationPendingCount} navigation edits pending sync".takeIf { state.navigationPendingCount > 0 },
                state.navigationSyncError,
            ).joinToString(". "),
            modifier = androidx.compose.ui.Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
            style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

internal fun List<NavigationFolder>.folderContaining(itemId: String): NavigationFolder? = firstOrNull { itemId in it.itemIds }
