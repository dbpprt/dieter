@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.ui.theme.DieterShellTint

@Composable
fun FilesScreen(
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    contentPadding: PaddingValues,
) {
    if (!expanded && state.fileDocument != null) {
        FilePreview(state, model, Modifier.padding(contentPadding))
        return
    }
    if (expanded) {
        Row(Modifier.fillMaxSize().padding(contentPadding)) {
            FileList(state, model, Modifier.weight(0.43f))
            HorizontalPaneDivider()
            val document = state.fileDocument
            if (document == null) {
                EmptyDetail("Select a file", "Text files open in a revision-safe editor.", Icons.Outlined.Description, Modifier.weight(0.57f))
            } else {
                FilePreview(state, model, Modifier.weight(0.57f), showBack = false)
            }
        }
    } else {
        FileList(state, model, Modifier.fillMaxSize().padding(contentPadding))
    }
}

@Composable
internal fun FileList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    var showCreate by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    Box(modifier) {
    Column(Modifier.fillMaxSize()) {
        SimpleScreenHeader("Files", "${state.project?.name?.lowercase() ?: "project"} · ${state.files.size} loaded") {
            IconButton(onClick = model::refresh) { Icon(Icons.Outlined.Refresh, "Refresh files") }
            Box {
                IconButton(onClick = { menuOpen = true }) { Icon(Icons.Outlined.MoreVert, "File options") }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("New file or folder") },
                        leadingIcon = { Icon(Icons.Default.Add, null) },
                        onClick = { menuOpen = false; showCreate = true },
                    )
                    DropdownMenuItem(
                        text = { Text(if (state.showHiddenFiles) "Hide hidden files" else "Show hidden files") },
                        onClick = { menuOpen = false; model.setShowHiddenFiles(!state.showHiddenFiles) },
                    )
                    DropdownMenuItem(
                        text = { Text("App settings") },
                        leadingIcon = { Icon(Icons.Outlined.Settings, null) },
                        onClick = { menuOpen = false; model.openSurface(AppSurface.APP_SETTINGS) },
                    )
                }
            }
        }
        SurfaceErrorBanner(state.error, model::clearError)
        CompactSearchField(query, { query = it }, "Filter loaded files")
        if (state.filePath.isNotBlank()) {
            TextButton(onClick = model::openParentDirectory, modifier = Modifier.padding(horizontal = 8.dp)) {
                Icon(Icons.Outlined.ArrowUpward, null)
                Spacer(Modifier.width(8.dp))
                Text(state.filePath)
            }
        }
        val entries = state.files.filter { query.isBlank() || it.name.contains(query, true) }
        if (!state.connected && state.projects.isEmpty()) {
            ConnectionEmptyState(state, model)
        } else if (entries.isEmpty()) {
            EmptyList("No files here", "Try another folder or clear the filter.", Icons.Outlined.Folder)
        } else {
            LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
                if (state.filePath.isBlank()) {
                    item(key = "project-root") {
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(13.dp)).background(DieterShellTint)
                                .padding(horizontal = 12.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Outlined.KeyboardArrowDown, null, tint = DieterShell, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(10.dp))
                            Icon(Icons.Outlined.Folder, null, tint = DieterShell)
                            Spacer(Modifier.width(12.dp))
                            Text(state.project?.name ?: "Project", fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
                items(entries, key = { it.path }) { entry ->
                    Row(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable {
                                if (entry.kind == "directory") model.openDirectory(entry.path) else model.openFile(entry.path)
                            }
                            .padding(start = if (state.filePath.isBlank()) 42.dp else 12.dp, end = 12.dp, top = 11.dp, bottom = 11.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            if (entry.kind == "directory") Icons.Outlined.Folder else Icons.Outlined.Description,
                            null,
                            tint = DieterShell,
                        )
                        Spacer(Modifier.width(14.dp))
                        Text(entry.name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (entry.kind == "directory") Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted)
                    }
                }
            }
        }
    }
    }
    if (showCreate) {
        FileCreateDialog(state.filePath, onDismiss = { showCreate = false }) { path, directory ->
            showCreate = false
            model.createFile(path, directory)
        }
    }
}

@Composable
internal fun FilePreview(
    state: DieterUiState,
    model: DieterViewModel,
    modifier: Modifier = Modifier,
    showBack: Boolean = true,
) {
    val document = state.fileDocument ?: return
    val syntaxTransformation = remember(document.path) {
        CodeSyntaxVisualTransformation(document.path, MaxEditableSyntaxHighlightCharacters)
    }
    var confirmClose by remember { mutableStateOf(false) }
    var showMove by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    fun close() {
        if (!model.closeFile()) confirmClose = true
    }
    Column(modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (showBack) IconButton(onClick = ::close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Column(Modifier.weight(1f)) {
                Text(document.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(document.path, color = DieterMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (!document.binary) {
                IconButton(onClick = { showMove = true }) { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, "Move or rename") }
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.DeleteOutline, "Delete") }
                Button(onClick = model::saveFile, enabled = state.fileDirty && !state.working) { Text("Save") }
            }
            if (!showBack) IconButton(onClick = ::close) { Icon(Icons.Outlined.Close, "Close") }
        }
        HorizontalDivider(color = DieterOutline)
        if (document.binary) {
            EmptyList("Binary file", "${document.mimeType} · ${document.size} bytes", Icons.Outlined.Description)
        } else {
            OutlinedTextField(
                value = state.fileDraft,
                onValueChange = model::updateFileDraft,
                modifier = Modifier.fillMaxSize().padding(12.dp),
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace, lineHeight = 20.sp),
                visualTransformation = syntaxTransformation,
                enabled = !state.working,
                label = {
                    val suffix = if (state.fileDraft.length > MaxEditableSyntaxHighlightCharacters) " · first 20k highlighted" else ""
                    Text("${syntaxTransformation.language.displayName}$suffix")
                },
            )
        }
    }
    if (confirmClose) {
        ConfirmDialog(
            title = "Discard unsaved changes?",
            body = document.path,
            confirmLabel = "Discard",
            onDismiss = { confirmClose = false },
        ) {
            confirmClose = false
            model.closeFile(force = true)
        }
    }
    if (showMove) {
        TextInputDialog(
            title = "Move or rename",
            label = "Destination path",
            initial = document.path,
            onDismiss = { showMove = false },
        ) { destination ->
            showMove = false
            model.moveFile(document.path, destination)
        }
    }
    if (confirmDelete) {
        ConfirmDialog(
            title = "Delete ${document.name}?",
            body = "This removes the file from the project working tree.",
            confirmLabel = "Delete",
            onDismiss = { confirmDelete = false },
        ) {
            confirmDelete = false
            model.deleteFile(document.path, recursive = false)
        }
    }
}
