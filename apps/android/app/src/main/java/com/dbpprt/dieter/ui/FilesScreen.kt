@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Photo
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
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.core.files.FilePaths
import com.dbpprt.dieter.core.presentation.ByteSizes
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.settings.DEFAULT_PANE_LEADING_FRACTION
import com.dbpprt.dieter.ui.theme.DieterShellTint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun FilesScreen(
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    contentPadding: PaddingValues,
) {
    val tabs = ProjectFilesTab.entries
    val selectedTab = state.projectFilesMode
    val selectedIndex = tabs.indexOf(selectedTab)
    val pagerState = rememberPagerState(initialPage = selectedIndex, pageCount = { tabs.size })
    val scope = rememberCoroutineScope()
    val currentMode by rememberUpdatedState(state.projectFilesMode)
    var pendingTab by remember { mutableStateOf<ProjectFilesTab?>(null) }

    fun openTab(tab: ProjectFilesTab) {
        if (tab == selectedTab) return
        if (state.fileDirty && tab == ProjectFilesTab.CHANGES) {
            pendingTab = tab
            return
        }
        scope.launch { pagerState.animateScrollToPage(tabs.indexOf(tab)) }
    }

    LaunchedEffect(selectedIndex) {
        if (pagerState.settledPage != selectedIndex) pagerState.animateScrollToPage(selectedIndex)
    }
    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.settledPage }
            .distinctUntilChanged()
            .collect { page ->
                val mode = tabs[page]
                if (mode != currentMode) model.setProjectFilesMode(mode)
            }
    }
    BackHandler(
        enabled = state.projectFilesMode == ProjectFilesTab.CHANGES && (state.projectChanges.selection != null) ||
            state.projectFilesMode == ProjectFilesTab.FILES && state.fileDocument == null && state.filePath.isNotBlank(),
    ) {
        if (state.projectFilesMode == ProjectFilesTab.CHANGES) model.closeProjectDiff()
        else model.openParentDirectory()
    }

    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        ProjectCheckoutSelector(state, model)
        if (LocalTabletWorkspace.current) {
            ProjectFilesPage(selectedTab, state, model, expanded, Modifier.weight(1f))
        } else {
            ProjectFilesTabs(
                selected = selectedTab,
                changedFiles = state.projectChanges.changes?.files?.size ?: 0,
                onSelect = ::openTab,
            )
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                userScrollEnabled = !state.fileDirty && state.fileDocument == null && state.projectChanges.selection == null,
                beyondViewportPageCount = 1,
                key = { tabs[it] },
            ) { page ->
                ProjectFilesPage(tabs[page], state, model, expanded, Modifier.fillMaxSize())
            }
        }
    }
    pendingTab?.let { tab ->
        ConfirmDialog(
            title = "Discard unsaved file changes?",
            body = state.fileDocument?.path.orEmpty(),
            confirmLabel = "Discard",
            onDismiss = { pendingTab = null },
        ) {
            pendingTab = null
            model.closeFile(force = true)
            scope.launch { pagerState.animateScrollToPage(tabs.indexOf(tab)) }
        }
    }
}

@Composable
internal fun ProjectFilesTabs(
    selected: ProjectFilesTab,
    changedFiles: Int,
    onSelect: (ProjectFilesTab) -> Unit,
) {
    PrimaryTabRow(
        selectedTabIndex = ProjectFilesTab.entries.indexOf(selected),
        containerColor = MaterialTheme.colorScheme.background,
        contentColor = DieterShell,
    ) {
        ProjectFilesTab.entries.forEach { tab ->
            Tab(
                selected = selected == tab,
                onClick = { onSelect(tab) },
                text = {
                    Text(
                        if (tab == ProjectFilesTab.CHANGES && changedFiles > 0) "${tab.label} · $changedFiles" else tab.label,
                        fontWeight = if (selected == tab) FontWeight.SemiBold else FontWeight.Normal,
                    )
                },
                modifier = Modifier.testTag(if (tab == ProjectFilesTab.FILES) "project-files-browse" else "project-files-changes"),
            )
        }
    }
}

@Composable
private fun ProjectFilesPage(
    tab: ProjectFilesTab,
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    modifier: Modifier,
) {
    if (tab == ProjectFilesTab.CHANGES) {
        ProjectChangesScreen(
            state = state,
            model = model,
            expanded = expanded,
            active = state.projectFilesMode == ProjectFilesTab.CHANGES,
            modifier = modifier,
        )
    } else if (!expanded && state.fileDocument != null) {
        FilePreview(state, model, modifier)
    } else if (expanded) {
        ResizableHorizontalSplitPane(
            dividerTag = "files-pane-divider",
            initialLeadingFraction = if (LocalTabletWorkspace.current) .28f else DEFAULT_PANE_LEADING_FRACTION,
            modifier = modifier.fillMaxWidth(),
            leading = { paneModifier -> FileList(state, model, paneModifier) },
        ) { paneModifier ->
            val document = state.fileDocument
            if (document == null) {
                EmptyDetail("Select a file", "Text files open in a revision-safe editor.", Icons.Outlined.Description, paneModifier)
            } else {
                FilePreview(state, model, paneModifier, showBack = false)
            }
        }
    } else {
        FileList(state, model, modifier)
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
                    val directory = FilePaths.isDirectory(entry)
                    Row(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable {
                                if (directory) model.openDirectory(entry.path) else model.openFile(entry.path)
                            }
                            .padding(start = if (state.filePath.isBlank()) 42.dp else 12.dp, end = 12.dp, top = 11.dp, bottom = 11.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(fileIcon(FilePaths.icon(entry)), null, tint = DieterShell)
                        Spacer(Modifier.width(14.dp))
                        Text(entry.name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (directory) Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted)
                    }
                }
            }
        }
    }
    }
    if (showCreate) {
        FileCreateDialog(state.filePath, onDismiss = { showCreate = false }) { name, directory ->
            showCreate = false
            model.createFile(name, directory)
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
    val renderer = FilePaths.renderer(document)
    val editable = renderer == FilePaths.Renderer.TEXT || renderer == FilePaths.Renderer.MARKDOWN
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
            if (editable) {
                IconButton(onClick = { showMove = true }) { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, "Move or rename") }
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.DeleteOutline, "Delete") }
                if (state.fileConflict) TextButton(onClick = model::reloadFile, enabled = !state.working) { Text("Reload") }
                Button(onClick = model::saveFile, enabled = state.fileDirty && !state.working) { Text("Save") }
            }
            if (!showBack) IconButton(onClick = ::close) { Icon(Icons.Outlined.Close, "Close") }
        }
        HorizontalDivider(color = DieterOutline)
        if (!editable) {
            FileWithoutEditor(document, renderer)
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

/** A file the editor does not open: an image it can decode, else its type and size. */
@Composable
private fun FileWithoutEditor(document: FileDocument, renderer: FilePaths.Renderer) {
    var decoding by remember(document.path, document.revision) { mutableStateOf(renderer == FilePaths.Renderer.IMAGE) }
    var image by remember(document.path, document.revision) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(document.path, document.revision, renderer) {
        if (renderer == FilePaths.Renderer.IMAGE) {
            image = withContext(Dispatchers.Default) { decodeImage(FilePaths.bytes(document).toByteArray(), maxDimension = 2400) }?.asImageBitmap()
        }
        decoding = false
    }
    val bitmap = image
    when {
        decoding -> LoadingState()
        bitmap != null -> Image(
            bitmap = bitmap,
            contentDescription = document.name,
            contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize().padding(12.dp).testTag("file-image"),
        )
        else -> EmptyList(
            if (document.binary) "Binary file" else "No preview",
            "${FilePaths.typeLabel(document.name, document.mime_type)} · ${ByteSizes.format(document.size)}",
            Icons.Outlined.Description,
        )
    }
}

/** The listing glyph for each of the core's file icons. */
private fun fileIcon(icon: FilePaths.Icon): ImageVector = when (icon) {
    FilePaths.Icon.DIRECTORY -> Icons.Outlined.Folder
    FilePaths.Icon.IMAGE -> Icons.Outlined.Photo
    FilePaths.Icon.MARKDOWN -> Icons.AutoMirrored.Outlined.Article
    FilePaths.Icon.CODE -> Icons.Outlined.Code
    FilePaths.Icon.TEXT -> Icons.Outlined.Description
}
