package com.dbpprt.dieter.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.settings.NavigationFolder
import com.dbpprt.dieter.settings.NavigationFolderPreferences
import com.dbpprt.dieter.settings.NavigationFolderScope
import com.dbpprt.dieter.settings.NavigationFolderStore
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterShell

@Composable
internal fun NewNavigationFolderButton(
    scope: NavigationFolderScope,
    preferences: NavigationFolderPreferences,
    store: NavigationFolderStore,
) {
    var open by rememberSaveable { mutableStateOf(false) }
    IconButton(onClick = { open = true }, modifier = Modifier.testTag("new-${scope.name.lowercase()}-folder")) {
        Icon(Icons.Outlined.CreateNewFolder, if (scope == NavigationFolderScope.CHATS) "New chat folder" else "New project folder")
    }
    if (open) NavigationFolderNameDialog(scope, preferences, onDismiss = { open = false }) {
        store.create(scope, it)
        open = false
    }
}

@Composable
internal fun NavigationFolderHeader(
    folder: NavigationFolder,
    count: Int,
    scope: NavigationFolderScope,
    preferences: NavigationFolderPreferences,
    store: NavigationFolderStore,
    revealSearchResults: Boolean = false,
) {
    var options by remember { mutableStateOf(false) }
    var rename by rememberSaveable { mutableStateOf(false) }
    var delete by rememberSaveable { mutableStateOf(false) }
    val expanded = folder.isExpanded || revealSearchResults
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).heightIn(min = 48.dp)
                .clickable { store.update(scope) { it.toggling(folder.id) } }
                .testTag("folder-${folder.id}")
                .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Outlined.KeyboardArrowDown, if (expanded) "Collapse ${folder.name}" else "Expand ${folder.name}",
                tint = DieterMuted, modifier = Modifier.size(20.dp).rotate(if (expanded) 0f else -90f))
            Icon(Icons.Outlined.Folder, null, tint = DieterShell, modifier = Modifier.size(20.dp))
            Text(folder.name, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Text("$count", color = DieterMuted)
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
    if (rename) NavigationFolderNameDialog(scope, preferences, folder, { rename = false }) { name ->
        store.update(scope) { it.renaming(folder.id, name) }
        rename = false
    }
    if (delete) AlertDialog(
        onDismissRequest = { delete = false },
        title = { Text("Delete ${folder.name}?") },
        text = { Text(if (scope == NavigationFolderScope.CHATS) "Chats in this folder will return to their project groups. No chats will be deleted."
            else "Projects in this folder will return to the unfiled list. No projects will be deleted.") },
        dismissButton = { TextButton(onClick = { delete = false }) { Text("Cancel") } },
        confirmButton = { TextButton(onClick = { store.update(scope) { it.deleting(folder.id) }; delete = false },
            modifier = Modifier.testTag("delete-folder-confirm")) { Text("Delete folder") } },
    )
}

@Composable
internal fun NavigationFolderNameDialog(
    scope: NavigationFolderScope,
    preferences: NavigationFolderPreferences,
    folder: NavigationFolder? = null,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var name by rememberSaveable(folder?.id) { mutableStateOf(folder?.name.orEmpty()) }
    val available = preferences.nameIsAvailable(name, folder?.id)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (folder != null) "Rename folder" else if (scope == NavigationFolderScope.CHATS) "New chat folder" else "New project folder") },
        text = {
            OutlinedTextField(
                value = name, onValueChange = { name = it }, singleLine = true,
                label = { Text("Folder name") },
                isError = name.isNotBlank() && !available,
                supportingText = { if (name.isNotBlank() && !available) Text("A folder with this name already exists.") },
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
    scope: NavigationFolderScope,
    preferences: NavigationFolderPreferences,
    store: NavigationFolderStore,
    onDismiss: () -> Unit,
) {
    var creating by rememberSaveable { mutableStateOf(false) }
    if (creating) {
        NavigationFolderNameDialog(scope, preferences, onDismiss = { creating = false }) { name ->
            store.create(scope, name, itemID)
            onDismiss()
        }
    } else {
        val selected = preferences.folderContaining(itemID)?.id
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Move to folder") },
            text = {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
                    FolderDestination("No folder", selected == null, "move-no-folder") {
                        store.update(scope) { it.moving(itemID, null) }; onDismiss()
                    }
                    preferences.folders.forEach { folder ->
                        FolderDestination(folder.name, selected == folder.id, "move-folder-${folder.id}") {
                            store.update(scope) { it.moving(itemID, folder.id) }; onDismiss()
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
