@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.lazy.LazyListScope
import com.dbpprt.dieter.settings.NavigationFolderScope
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.DragHandle
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetValue
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.isSpecified
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.connection.ProjectReplica
import androidx.compose.ui.zIndex
import androidx.core.graphics.toColorInt
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellDeep
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterPane
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card as BoardCard
import com.dbpprt.dieter.v1.Project
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import java.time.Instant
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterRunning
import com.dbpprt.dieter.ui.theme.DieterAbyss

internal data class DraggedBoardLabel(val id: String, val name: String, val color: String)

internal class BoardLabelDragState {
    var label by mutableStateOf<DraggedBoardLabel?>(null)
        private set
    var pointerInRoot by mutableStateOf(Offset.Unspecified)
        private set
    private val cardBounds = mutableStateMapOf<String, Rect>()

    fun start(label: DraggedBoardLabel, pointerInRoot: Offset) {
        this.label = label
        this.pointerInRoot = pointerInRoot
    }

    fun moveBy(amount: Offset) {
        if (pointerInRoot.isSpecified) pointerInRoot += amount
    }

    fun registerCard(cardId: String, bounds: Rect) {
        cardBounds[cardId] = bounds
    }

    fun unregisterCard(cardId: String) {
        cardBounds.remove(cardId)
    }

    fun isTargeted(cardId: String): Boolean =
        label != null && cardBounds[cardId]?.contains(pointerInRoot) == true

    fun finish(): Pair<String, String>? {
        val labelId = label?.id
        val cardId = labelDropTargetAt(cardBounds, pointerInRoot)
        reset()
        return if (labelId != null && cardId != null) cardId to labelId else null
    }

    fun reset() {
        label = null
        pointerInRoot = Offset.Unspecified
    }
}

internal fun labelDropTargetAt(cardBounds: Map<String, Rect>, pointerInRoot: Offset): String? =
    if (!pointerInRoot.isSpecified) null
    else cardBounds.entries.firstOrNull { (_, bounds) -> bounds.contains(pointerInRoot) }?.key

@Composable
fun BoardScreen(
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    contentPadding: PaddingValues,
) {
    if (LocalTabletProjectWorkspaces.current) {
        ProjectWorkspacesContent(state, model, Modifier.fillMaxSize().padding(contentPadding))
        return
    }
    if (state.boardOverviewVisible) {
        SpacesOverview(state, model, Modifier.fillMaxSize().padding(contentPadding))
        return
    }
    if (!expanded && state.selectedCardId != null) {
        CardDetailScreen(state, model, Modifier.padding(contentPadding))
        return
    }
    if (LocalTabletWorkspace.current) {
        if (state.selectedCardId == null) {
            BoardList(state, model, Modifier.fillMaxSize().padding(contentPadding), showAllLanes = true)
        } else {
            // The project navigator remains beside this content pane. Back
            // returns to the board without squeezing a third pane into it.
            CardDetailScreen(state, model, Modifier.fillMaxSize().padding(contentPadding))
        }
    } else if (expanded) {
        ResizableHorizontalSplitPane(
            dividerTag = "board-pane-divider",
            modifier = Modifier.fillMaxSize().padding(contentPadding),
            initialLeadingFraction = state.boardPaneLeadingFraction,
            onLeadingFractionCommitted = model::setBoardPaneLeadingFraction,
            leading = { paneModifier -> BoardList(state, model, paneModifier) },
        ) { paneModifier ->
            if (state.selectedCardId == null) {
                EmptyDetail("Select a card", "Its conversation will stay beside the board.", Icons.Outlined.ViewKanban, paneModifier)
            } else {
                CardDetailScreen(state, model, paneModifier, showBack = false)
            }
        }
    } else {
        BoardList(state, model, Modifier.fillMaxSize().padding(contentPadding))
    }
}

@Composable
internal fun SpacesOverview(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    var moveProjectID by rememberSaveable { mutableStateOf<String?>(null) }
    var searchOpen by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var sort by rememberSaveable { mutableStateOf(ProjectOverviewSort.MANUAL) }
    var sortMenuOpen by remember { mutableStateOf(false) }
    var topSortMenuOpen by remember { mutableStateOf(false) }
    var expandedProjectIDs by remember { mutableStateOf(emptySet<String>()) }
    val projectDragState = remember { ProjectDragState() }
    val haptic = LocalHapticFeedback.current
    val boardsByProject = remember(state.spaceBoards) { state.spaceBoards.groupBy(Board::getProjectId) }
    val cardsByProject = remember(state.spaceCards) { state.spaceCards.groupBy(BoardCard::getProjectId) }
    val visibleProjects = remember(state.projects, boardsByProject, cardsByProject, query, sort) {
        val filtered = state.projects.filter { project ->
            query.isBlank() || project.name.contains(query, true) || project.path.contains(query, true) ||
                boardsByProject[project.id].orEmpty().any { it.name.contains(query, true) }
        }
        when (sort) {
            ProjectOverviewSort.MANUAL -> filtered
            ProjectOverviewSort.ATTENTION -> filtered.sortedWith(
                compareByDescending<Project> { projectAttentionCount(cardsByProject[it.id].orEmpty()) }
                    .thenBy { it.name.lowercase() },
            )
            ProjectOverviewSort.NAME -> filtered.sortedBy { it.name.lowercase() }
        }
    }
    val pinnedProjects = remember(state.projects, state.pinnedProjectOrder) {
        orderedPinnedProjects(state.projects, state.pinnedProjectOrder)
    }

    Column(modifier) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 10.dp, top = 17.dp, bottom = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Projects", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                ProjectOverviewStatus(state)
            }
            IconButton(onClick = { searchOpen = !searchOpen }) { Icon(Icons.Outlined.Search, "Search projects") }
            Box {
                IconButton(onClick = { topSortMenuOpen = true }) {
                    Icon(Icons.Outlined.Tune, "Sort projects", tint = DieterMuted)
                }
                ProjectOverviewSortMenu(
                    expanded = topSortMenuOpen,
                    selected = sort,
                    onSelect = { sort = it; topSortMenuOpen = false },
                    onDismiss = { topSortMenuOpen = false },
                    onSettings = { topSortMenuOpen = false; model.openSurface(AppSurface.APP_SETTINGS) },
                )
            }
        }
        NavigationSyncStatus(state)
        if (searchOpen) CompactSearchField(query, { query = it }, "Search projects and boards")
        if (state.spacesLoading) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = DieterShell)
        SurfaceErrorBanner(state.error, model::clearError)
        if (!state.connected && state.projects.isEmpty() && state.projectFolders.folders.isEmpty()) {
            ConnectionEmptyState(state, model)
        } else if (state.loading && state.projects.isEmpty()) {
            LoadingState()
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().testTag("spaces-overview"),
                contentPadding = PaddingValues(top = 4.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                if (query.isBlank() && pinnedProjects.isNotEmpty()) {
                    item(key = "project-pinned-label") {
                        ListSectionLabel("Pinned", Modifier.padding(horizontal = 20.dp))
                    }
                    item(key = "project-pinned") {
                        LazyRow(
                            contentPadding = PaddingValues(horizontal = 20.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxWidth().testTag("project-pinned"),
                        ) {
                            items(pinnedProjects, key = { it.id }) { project ->
                                PinnedProjectCard(
                                    project = project,
                                    host = state.presentedProjectReplicas[project.id],
                                    boards = boardsByProject[project.id].orEmpty(),
                                    cards = cardsByProject[project.id].orEmpty(),
                                    chatCount = state.chats.count { it.projectId == project.id && !it.archived },
                                    selected = project.id == state.selectedProjectId,
                                    onUnpin = { model.setProjectPinned(project.id, false) },
                                    onOpenBoard = { model.openBoard(project.id, it.id) },
                                    onCreateBoard = { model.openNewBoard(project.id) },
                                )
                            }
                        }
                    }
                    item(key = "project-overview-divider") {
                        Box(
                            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 5.dp).height(1.dp)
                                .background(DieterOutline.copy(alpha = 0.46f)),
                        )
                    }
                }
                item(key = "all-projects-header") {
                    Row(
                        Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 2.dp, bottom = 1.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "ALL PROJECTS  ·  ${state.projectFolders.folders.size} ${plural(state.projectFolders.folders.size, "folder")}".uppercase(),
                            color = DieterMuted,
                            fontSize = 10.sp,
                            letterSpacing = 1.15.sp,
                            modifier = Modifier.weight(1f),
                        )
                        NewNavigationFolderButton(NavigationFolderScope.PROJECTS, state.projectFolders, model.navigationFolders)
                        Box {
                            Surface(
                                onClick = { sortMenuOpen = true },
                                color = DieterSurface,
                                shape = RoundedCornerShape(9.dp),
                            ) {
                                Row(
                                    Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                                ) {
                                    Text(sort.label, fontSize = 10.sp, fontWeight = FontWeight.Medium)
                                    Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.size(14.dp), tint = DieterMuted)
                                }
                            }
                            ProjectOverviewSortMenu(
                                expanded = sortMenuOpen,
                                selected = sort,
                                onSelect = { sort = it; sortMenuOpen = false },
                                onDismiss = { sortMenuOpen = false },
                            )
                        }
                    }
                }
                fun LazyListScope.projectItems(projects: List<Project>, nested: Boolean = false) {
                    items(projects, key = { it.id }) { project ->
                        val dragged = projectDragState.projectId == project.id
                        var originInRoot by remember(project.id) { mutableStateOf(Offset.Zero) }
                        val projectBoards = boardsByProject[project.id].orEmpty()
                        DisposableEffect(projectDragState, project.id) {
                            onDispose { projectDragState.unregister(project.id) }
                        }
                        CompactProjectRow(
                            project = project,
                            pinned = project.id in state.pinnedProjectOrder,
                            onTogglePinned = {
                                model.setProjectPinned(project.id, project.id !in state.pinnedProjectOrder)
                            },
                            onMoveToFolder = { moveProjectID = project.id },
                            host = state.presentedProjectReplicas[project.id],
                            boards = projectBoards,
                            cards = cardsByProject[project.id].orEmpty(),
                            dragged = dragged,
                            dropTarget = projectDragState.targetProjectId == project.id,
                            nested = nested,
                            expanded = project.id in expandedProjectIDs,
                            onOpenBoard = { board -> model.openBoard(project.id, board.id) },
                            onCreateBoard = { model.openNewBoard(project.id) },
                            onToggle = {
                                when (projectBoards.size) {
                                    0 -> model.openNewBoard(project.id)
                                    1 -> model.openBoard(project.id, projectBoards.single().id)
                                    else -> expandedProjectIDs = if (project.id in expandedProjectIDs) {
                                        expandedProjectIDs - project.id
                                    } else {
                                        expandedProjectIDs + project.id
                                    }
                                }
                            },
                            modifier = Modifier
                                .fillMaxWidth().padding(horizontal = 20.dp)
                                .onGloballyPositioned {
                                    originInRoot = it.positionInRoot()
                                    projectDragState.register(project.id, it.boundsInRoot())
                                }
                                .offset { IntOffset(0, if (dragged) projectDragState.offsetY.toInt() else 0) }
                                .zIndex(if (dragged) 1f else 0f)
                                .testTag("space-project-${project.id}")
                                .semantics {
                                    contentDescription = "${project.name} project; long press and drag to reorder"
                                }
                                .pointerInput(project.id, projectDragState) {
                                    detectDragGesturesAfterLongPress(
                                        onDragStart = { offset ->
                                            projectDragState.start(project.id, originInRoot + offset)
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                        },
                                        onDrag = { change, dragAmount ->
                                            change.consume()
                                            projectDragState.moveBy(dragAmount)
                                        },
                                        onDragEnd = {
                                            projectDragState.finish()?.let { (projectId, targetProjectId) ->
                                                model.moveProject(projectId, targetProjectId)
                                            }
                                        },
                                        onDragCancel = projectDragState::reset,
                                    )
                                },
                        )
                    }
                }
                val projectsByID = visibleProjects.associateBy { it.id }
                state.projectFolders.folders.forEach { folder ->
                    val members = sortProjects(folder.itemIDs.mapNotNull(projectsByID::get), sort, cardsByProject)
                    if (query.isBlank() || members.isNotEmpty()) {
                        item(key = "project-folder-${folder.id}") {
                            val folderBoards = members.flatMap { boardsByProject[it.id].orEmpty() }
                            val attentionBoards = folderBoards.count { board ->
                                cardsByProject[board.projectId].orEmpty().any { it.boardId == board.id && it.lane.contains("review", true) }
                            }
                            Surface(
                                color = DieterSurface,
                                shape = RoundedCornerShape(11.dp),
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                            ) {
                                NavigationFolderHeader(
                                    folder,
                                    attentionBoards.takeIf { it > 0 } ?: members.size,
                                    NavigationFolderScope.PROJECTS,
                                    state.projectFolders,
                                    model.navigationFolders,
                                    revealSearchResults = query.isNotBlank(),
                                    summary = buildString {
                                        append(members.size).append(" ").append(plural(members.size, "project"))
                                        if (attentionBoards > 0) append(" · ").append(attentionBoards).append(" need review")
                                        else append(" · ").append(folderBoards.size).append(" ").append(plural(folderBoards.size, "board"))
                                    },
                                )
                            }
                        }
                        if (folder.isExpanded || query.isNotBlank()) {
                            if (members.isEmpty()) item(key = "project-folder-empty-${folder.id}") {
                                Text("No projects in this folder", color = DieterMuted, modifier = Modifier.padding(horizontal = 32.dp, vertical = 6.dp))
                            }
                            projectItems(members, nested = true)
                        }
                    }
                }
                val unfiled = state.projectFolders.unfiledIDs(visibleProjects.map { it.id }).mapNotNull(projectsByID::get)
                projectItems(unfiled)
                item {
                    Surface(
                        onClick = { model.openSurface(AppSurface.NEW_PROJECT) },
                        color = Color.Transparent,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp)
                            .dashedBorder(DieterOutline.copy(alpha = 0.9f), cornerRadius = 12.dp)
                            .testTag("add-git-project"),
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 12.dp),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Default.Add, null, tint = DieterShell, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Add a Git project", color = DieterShell, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }
    moveProjectID?.let { projectID ->
        MoveToNavigationFolderDialog(projectID, NavigationFolderScope.PROJECTS, state.projectFolders,
            model.navigationFolders, onDismiss = { moveProjectID = null })
    }
}

@Composable
private fun ProjectOverviewSortMenu(
    expanded: Boolean,
    selected: ProjectOverviewSort,
    onSelect: (ProjectOverviewSort) -> Unit,
    onDismiss: () -> Unit,
    onSettings: (() -> Unit)? = null,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        ProjectOverviewSort.entries.forEach { option ->
            DropdownMenuItem(
                text = { Text(option.label) },
                trailingIcon = { if (selected == option) Icon(Icons.Default.Check, "Selected") },
                onClick = { onSelect(option) },
            )
        }
        onSettings?.let { openSettings ->
            DropdownMenuItem(
                text = { Text("App settings") },
                leadingIcon = { Icon(Icons.Outlined.Settings, null) },
                onClick = openSettings,
            )
        }
    }
}

internal enum class ProjectOverviewSort(val label: String) {
    MANUAL("Manual"),
    ATTENTION("Needs you"),
    NAME("Name"),
}

internal fun projectAttentionCount(cards: List<BoardCard>): Int = cards.count {
    it.lane.contains("review", true) || it.runtime.contains("running", true)
}

internal fun sortProjects(
    projects: List<Project>,
    sort: ProjectOverviewSort,
    cardsByProject: Map<String, List<BoardCard>>,
): List<Project> = when (sort) {
    ProjectOverviewSort.MANUAL -> projects
    ProjectOverviewSort.ATTENTION -> projects.sortedWith(
        compareByDescending<Project> { projectAttentionCount(cardsByProject[it.id].orEmpty()) }.thenBy { it.name.lowercase() },
    )
    ProjectOverviewSort.NAME -> projects.sortedBy { it.name.lowercase() }
}

@Composable
private fun ProjectOverviewStatus(state: DieterUiState) {
    var now by remember(state.lastConnectedAtMillis) { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.lastConnectedAtMillis) {
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis()
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "${state.projects.size} ${plural(state.projects.size, "project")} · ${state.projectFolders.folders.size} ${plural(state.projectFolders.folders.size, "folder")} · ",
            color = DieterMuted,
            fontSize = 11.sp,
        )
        Box(Modifier.size(5.dp).background(if (state.connected) DieterEyes else DieterMuted, CircleShape))
        Spacer(Modifier.width(5.dp))
        Text(
            if (state.connected) "synced" else "cached",
            color = if (state.connected) DieterEyes else DieterMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
        )
        compactSyncAge(state.lastConnectedAtMillis, now)?.let {
            Text("  ·  $it", color = DieterMuted, fontSize = 11.sp)
        }
    }
}

internal fun compactSyncAge(lastConnectedAtMillis: Long?, nowMillis: Long): String? {
    if (lastConnectedAtMillis == null || lastConnectedAtMillis <= 0L) return null
    val elapsedSeconds = ((nowMillis - lastConnectedAtMillis).coerceAtLeast(0L) / 1_000L)
    return when {
        elapsedSeconds < 60L -> "now"
        elapsedSeconds < 3_600L -> "${elapsedSeconds / 60L}m"
        elapsedSeconds < 86_400L -> "${elapsedSeconds / 3_600L}h"
        else -> "${elapsedSeconds / 86_400L}d"
    }
}

@Composable
internal fun PinnedProjectCard(
    project: Project,
    host: ProjectReplica?,
    boards: List<Board>,
    cards: List<BoardCard>,
    chatCount: Int,
    selected: Boolean,
    onUnpin: () -> Unit,
    onOpenBoard: (Board) -> Unit,
    onCreateBoard: () -> Unit,
) {
    val accent = stableAccent(project.id)
    val reviewCount = cards.count { it.lane.contains("review", true) }
    Card(
        colors = CardDefaults.cardColors(containerColor = DieterSurface),
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (selected) DieterShell.copy(alpha = 0.78f) else DieterOutline.copy(alpha = 0.7f),
        ),
        shape = RoundedCornerShape(19.dp),
        modifier = Modifier.width(252.dp).testTag("project-pinned-${project.id}"),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(shape = RoundedCornerShape(11.dp), color = accent, modifier = Modifier.size(38.dp)) {
                    Box(contentAlignment = Alignment.Center) {
                        Text(project.name.trim().take(1).lowercase().ifBlank { "·" }, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    }
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(project.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    ProjectHostLine(host, project.path)
                }
                if (reviewCount > 0) {
                    Surface(shape = RoundedCornerShape(50), color = DieterAmber.copy(alpha = 0.14f)) {
                        Text("$reviewCount", color = DieterAmber, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp))
                    }
                }
                IconButton(
                    onClick = onUnpin,
                    modifier = Modifier.size(28.dp).testTag("project-unpin-${project.id}"),
                ) {
                    Icon(
                        Icons.Outlined.PushPin,
                        "Unpin ${project.name}",
                        tint = DieterShell,
                        modifier = Modifier.size(15.dp),
                    )
                }
            }
            if (boards.isEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("No boards yet", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.weight(1f))
                    TextButton(onClick = onCreateBoard, modifier = Modifier.testTag("space-create-board-${project.id}")) {
                        Icon(Icons.Default.Add, null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(5.dp))
                        Text("Create board")
                    }
                }
            }
            boards.take(2).forEach { board ->
                val boardCards = cards.filter { it.boardId == board.id }
                ProjectBoardRow(board, boardCards, onOpenBoard)
            }
            if (boards.size > 2 || chatCount > 0) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (boards.size > 2) "+${boards.size - 2} ${plural(boards.size - 2, "board")}" else "",
                        color = DieterMuted,
                        fontSize = 10.sp,
                        modifier = Modifier.weight(1f),
                    )
                    if (chatCount > 0) Text("$chatCount ${plural(chatCount, "chat")}", color = DieterMuted, fontSize = 10.sp)
                }
            }
        }
    }
}

@Composable
internal fun CompactProjectRow(
    project: Project,
    pinned: Boolean,
    onTogglePinned: () -> Unit,
    host: ProjectReplica?,
    boards: List<Board>,
    cards: List<BoardCard>,
    dragged: Boolean,
    dropTarget: Boolean,
    nested: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    onOpenBoard: (Board) -> Unit,
    onCreateBoard: () -> Unit,
    onMoveToFolder: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = stableAccent(project.id)
    val attention = projectAttentionCount(cards)
    var actionsOpen by remember { mutableStateOf(false) }
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        if (nested) {
            Box(
                Modifier.padding(start = 16.dp).width(1.dp).height(52.dp)
                    .background(DieterOutline.copy(alpha = 0.7f)),
            )
            Spacer(Modifier.width(8.dp))
        }
        Card(
            colors = CardDefaults.cardColors(containerColor = if (dropTarget) DieterShellTint else DieterSurface),
            border = androidx.compose.foundation.BorderStroke(
                if (dropTarget) 1.5.dp else 0.5.dp,
                if (dropTarget) DieterShell else DieterOutline.copy(alpha = 0.55f),
            ),
            shape = RoundedCornerShape(11.dp),
            elevation = CardDefaults.cardElevation(defaultElevation = if (dragged) 8.dp else 0.dp),
            modifier = Modifier.weight(1f),
        ) {
            Column {
                Row(
                    Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(start = 10.dp, end = 3.dp, top = 8.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.DragHandle, "Reorder ${project.name}", tint = DieterMuted.copy(alpha = 0.72f), modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(7.dp))
                    Surface(shape = RoundedCornerShape(10.dp), color = accent, modifier = Modifier.size(36.dp)) {
                        Box(contentAlignment = Alignment.Center) {
                            Text(project.name.trim().take(1).lowercase().ifBlank { "·" }, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(project.name, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                            if (attention > 0) {
                                Spacer(Modifier.width(6.dp))
                                Surface(shape = CircleShape, color = DieterShellTint) {
                                    Text("$attention", color = DieterShell, fontSize = 9.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp))
                                }
                            }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("${boards.size} ${plural(boards.size, "board")}", color = DieterMuted, fontSize = 10.sp)
                            host?.let {
                                Text("  ·  ", color = DieterMuted, fontSize = 10.sp)
                                Box(Modifier.size(4.dp).background(if (it.online) DieterEyes else DieterMuted, CircleShape))
                                Spacer(Modifier.width(4.dp))
                                Text(it.hostname, color = DieterMuted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                    ProjectActivityBars(cards)
                    Box {
                        IconButton(
                            onClick = { actionsOpen = true },
                            modifier = Modifier.size(32.dp).testTag("project-actions-${project.id}"),
                        ) {
                            Icon(Icons.Outlined.MoreVert, "Project actions for ${project.name}", tint = DieterMuted, modifier = Modifier.size(17.dp))
                        }
                        DropdownMenu(expanded = actionsOpen, onDismissRequest = { actionsOpen = false }) {
                            DropdownMenuItem(
                                text = { Text(if (pinned) "Unpin project" else "Pin project") },
                                leadingIcon = { Icon(Icons.Outlined.PushPin, null) },
                                modifier = Modifier.testTag("project-pin-${project.id}"),
                                onClick = { actionsOpen = false; onTogglePinned() },
                            )
                            DropdownMenuItem(
                                text = { Text("Move to folder") },
                                leadingIcon = { Icon(Icons.Outlined.FolderOpen, null) },
                                modifier = Modifier.testTag("project-folder-${project.id}"),
                                onClick = { actionsOpen = false; onMoveToFolder() },
                            )
                        }
                    }
                    Icon(
                        if (boards.size > 1 && expanded) Icons.Outlined.KeyboardArrowDown else Icons.Outlined.ChevronRight,
                        contentDescription = null,
                        tint = DieterMuted,
                        modifier = Modifier.size(17.dp),
                    )
                }
                if (expanded && boards.size > 1) {
                    Column(
                        Modifier.fillMaxWidth().padding(start = 46.dp, end = 8.dp, bottom = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        boards.forEach { board -> ProjectBoardRow(board, cards.filter { it.boardId == board.id }, onOpenBoard) }
                    }
                } else if (expanded && boards.isEmpty()) {
                    TextButton(onClick = onCreateBoard, modifier = Modifier.align(Alignment.End).padding(end = 8.dp, bottom = 5.dp)) {
                        Text("Create board")
                    }
                }
            }
        }
    }
}

@Composable
private fun ProjectHostLine(host: ProjectReplica?, fallback: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (host != null) {
            Box(Modifier.size(5.dp).background(if (host.online) DieterEyes else DieterMuted, CircleShape))
            Spacer(Modifier.width(5.dp))
            Text(host.hostname, color = DieterMuted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        } else {
            Text(compactProjectPath(fallback), color = DieterMuted, fontSize = 10.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun ProjectBoardRow(board: Board, cards: List<BoardCard>, onOpenBoard: (Board) -> Unit) {
    val review = cards.count { it.lane.contains("review", true) }
    val running = cards.count { it.runtime.contains("running", true) || it.lane.contains("running", true) }
    Surface(
        onClick = { onOpenBoard(board) },
        color = MaterialTheme.colorScheme.background.copy(alpha = 0.62f),
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth().testTag("space-board-${board.id}"),
    ) {
        Row(Modifier.padding(horizontal = 10.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            BoardMark(stableAccent(board.id), Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(board.name, fontWeight = FontWeight.SemiBold, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            when {
                review > 0 -> Text("$review review", color = DieterAmber, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                running > 0 -> Text("$running running", color = DieterRunning, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                else -> Text("${cards.size} ${plural(cards.size, "card")}", color = DieterMuted, fontSize = 10.sp)
            }
            Spacer(Modifier.width(5.dp))
            Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted, modifier = Modifier.size(15.dp))
        }
    }
}

@Composable
private fun ProjectActivityBars(cards: List<BoardCard>) {
    val active = cards.any { it.runtime.contains("running", true) || it.lane.contains("running", true) }
    val color = if (active) DieterShell else DieterMuted.copy(alpha = 0.48f)
    Row(
        Modifier.width(32.dp).height(18.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        listOf(4, 8, 5, 12, 7, 15).forEachIndexed { index, height ->
            Box(Modifier.width(3.dp).height(height.dp).background(color.copy(alpha = if (active && index >= 3) 1f else 0.48f), CircleShape))
        }
    }
}

internal class ProjectDragState {
    private val projectBounds = mutableStateMapOf<String, Rect>()

    var projectId by mutableStateOf<String?>(null)
        private set
    var targetProjectId by mutableStateOf<String?>(null)
        private set
    var offsetY by mutableFloatStateOf(0f)
        private set
    private var pointerInRoot by mutableStateOf(Offset.Unspecified)

    fun register(projectId: String, bounds: Rect) {
        projectBounds[projectId] = bounds
        updateTarget()
    }

    fun unregister(projectId: String) {
        projectBounds.remove(projectId)
        updateTarget()
    }

    fun start(projectId: String, pointerInRoot: Offset) {
        this.projectId = projectId
        this.pointerInRoot = pointerInRoot
        offsetY = 0f
        updateTarget()
    }

    fun moveBy(amount: Offset) {
        if (projectId == null || !pointerInRoot.isSpecified) return
        pointerInRoot += amount
        offsetY += amount.y
        updateTarget()
    }

    fun finish(): Pair<String, String>? {
        val result = projectId?.let { source -> targetProjectId?.let { target -> source to target } }
        reset()
        return result
    }

    fun reset() {
        projectId = null
        targetProjectId = null
        pointerInRoot = Offset.Unspecified
        offsetY = 0f
    }

    private fun updateTarget() {
        val source = projectId
        targetProjectId = if (source == null || !pointerInRoot.isSpecified) {
            null
        } else {
            projectBounds.entries.firstOrNull { (id, bounds) -> id != source && bounds.contains(pointerInRoot) }?.key
        }
    }
}

internal class PinnedChatDragState {
    private val chatBounds = mutableStateMapOf<String, Rect>()

    var chatId by mutableStateOf<String?>(null)
        private set
    var targetChatId by mutableStateOf<String?>(null)
        private set
    var offsetY by mutableFloatStateOf(0f)
        private set
    private var pointerInRoot by mutableStateOf(Offset.Unspecified)

    fun register(chatId: String, bounds: Rect) {
        chatBounds[chatId] = bounds
        updateTarget()
    }

    fun unregister(chatId: String) {
        chatBounds.remove(chatId)
        updateTarget()
    }

    fun start(chatId: String, pointerInRoot: Offset) {
        this.chatId = chatId
        this.pointerInRoot = pointerInRoot
        offsetY = 0f
        updateTarget()
    }

    fun moveBy(amount: Offset) {
        if (chatId == null || !pointerInRoot.isSpecified) return
        pointerInRoot += amount
        offsetY += amount.y
        updateTarget()
    }

    fun finish(): Pair<String, String>? {
        val result = chatId?.let { source -> targetChatId?.let { target -> source to target } }
        reset()
        return result
    }

    fun reset() {
        chatId = null
        targetChatId = null
        pointerInRoot = Offset.Unspecified
        offsetY = 0f
    }

    private fun updateTarget() {
        val source = chatId
        targetChatId = if (source == null || !pointerInRoot.isSpecified) {
            null
        } else {
            chatBounds.entries.firstOrNull { (id, bounds) -> id != source && bounds.contains(pointerInRoot) }?.key
        }
    }
}

@Composable
internal fun ProjectReplicaBadge(host: ProjectReplica) {
    Surface(shape = RoundedCornerShape(50), color = (if (host.online) DieterEyes else DieterMuted).copy(alpha = 0.1f)) {
        Row(Modifier.padding(horizontal = 7.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(5.dp).background(if (host.online) DieterEyes else DieterMuted, CircleShape))
            Spacer(Modifier.width(5.dp))
            Text(host.hostname, color = DieterMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

@Composable
internal fun BoardProgress(board: Board, cards: List<BoardCard>) {
    val counts = board.lanesList.map { lane -> lane.id to cards.count { it.lane == lane.id } }
    val nonZero = counts.filter { it.second > 0 }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.weight(1f).height(5.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (nonZero.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxHeight().clip(CircleShape).background(DieterOutline))
            } else {
                nonZero.forEach { (lane, count) ->
                    Box(
                        Modifier.weight(count.toFloat()).fillMaxHeight().clip(CircleShape)
                            .background(laneColor(lane)),
                    )
                }
            }
        }
        Text(
            nonZero.joinToString(" · ") { (lane, count) -> "$count ${lane.replace('_', ' ')}" }.ifBlank { "empty" },
            color = DieterMuted,
            fontSize = 10.sp,
            maxLines = 1,
        )
    }
}

@Composable
internal fun BoardDetailHeader(
    state: DieterUiState,
    model: DieterViewModel,
    onOpenSwitcher: () -> Unit,
    onToggleSearch: () -> Unit,
) {
    val board = state.board
    var menuOpen by remember { mutableStateOf(false) }
    val boardCards = state.cards.filter { it.boardId == state.selectedBoardId }
    val reviews = boardCards.count { it.lane.contains("review", true) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 4.dp, top = 12.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier.weight(1f).clip(RoundedCornerShape(14.dp)).clickable(onClick = onOpenSwitcher).padding(vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Surface(shape = RoundedCornerShape(13.dp), color = DieterShellDeep, modifier = Modifier.size(44.dp)) {
                    Box(contentAlignment = Alignment.Center) { BoardMark(Color.White, Modifier.size(25.dp)) }
                }
                Spacer(Modifier.width(11.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(board?.name ?: "Board", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Icon(Icons.Outlined.KeyboardArrowDown, null, tint = DieterMuted, modifier = Modifier.size(18.dp))
                    }
                    Text(
                        "${state.project?.name?.lowercase() ?: "project"} · ${boardCards.size} ${plural(boardCards.size, "conversation")} · $reviews ${if (reviews == 1) "needs" else "need"} you",
                        color = DieterMuted,
                        fontSize = 11.sp,
                        maxLines = 2,
                    )
                }
            }
            IconButton(onClick = onToggleSearch, modifier = Modifier.size(40.dp)) { Icon(Icons.Outlined.Search, "Search board") }
            Box {
                IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(40.dp)) { Icon(Icons.Outlined.MoreVert, "Board actions") }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text("Card notifications")
                                Text(
                                    if (state.boardNotificationsEnabled) "On for this board" else "Off for this board",
                                    color = DieterMuted,
                                    fontSize = 11.sp,
                                )
                            }
                        },
                        trailingIcon = {
                            Switch(
                                checked = state.boardNotificationsEnabled,
                                onCheckedChange = null,
                                modifier = Modifier.testTag("board-notifications-toggle"),
                            )
                        },
                        onClick = {
                            model.setSelectedBoardNotificationsEnabled(!state.boardNotificationsEnabled)
                        },
                        modifier = Modifier.testTag("board-notifications-setting"),
                    )
                    DropdownMenuItem(text = { Text("All projects") }, onClick = { menuOpen = false; model.showBoardOverview() })
                    DropdownMenuItem(text = { Text("Refresh") }, onClick = { menuOpen = false; model.refresh() })
                    DropdownMenuItem(text = { Text("Workspace settings") }, onClick = { menuOpen = false; model.openSurface(AppSurface.WORKSPACE) })
                    DropdownMenuItem(text = { Text("App settings") }, onClick = { menuOpen = false; model.openSurface(AppSurface.APP_SETTINGS) })
                }
            }
        }
        if (state.error != null) SurfaceErrorBanner(state.error, model::clearError)
    }
}

@Composable
internal fun BoardQuickSwitcher(state: DieterUiState, model: DieterViewModel, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 22.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Go to board", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                OutlinedButton(onClick = { onDismiss(); model.openSurface(AppSurface.NEW_BOARD) }) {
                    Icon(Icons.Default.Add, null, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("New board")
                }
            }
            state.projects.forEach { project ->
                val boards = state.spaceBoards.filter { it.projectId == project.id }
                if (boards.isNotEmpty()) {
                    Text(
                        buildString {
                            append(project.name)
                            state.presentedProjectReplicas[project.id]?.let { append("  ·  ").append(it.hostname) }
                            append("  ·  ").append(compactProjectPath(project.path))
                        }.uppercase(),
                        color = DieterMuted,
                        fontSize = 10.sp,
                        letterSpacing = 1.3.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(top = 8.dp, start = 4.dp),
                    )
                    boards.forEach { board ->
                        val selected = board.id == state.selectedBoardId && project.id == state.selectedProjectId
                        val cards = state.spaceCards.filter { it.boardId == board.id }
                        val reviews = cards.count { it.lane.contains("review", true) }
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                                .then(
                                    if (selected) {
                                        Modifier.background(DieterShellTint.copy(alpha = 0.55f))
                                            .border(1.dp, DieterShell.copy(alpha = 0.65f), RoundedCornerShape(16.dp))
                                    } else {
                                        Modifier
                                    },
                                )
                                .clickable {
                                    onDismiss()
                                    model.openBoard(project.id, board.id)
                                }
                                .padding(horizontal = 12.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            BoardMark(stableAccent(board.id), Modifier.size(24.dp))
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(board.name, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                                Text(
                                    "${cards.size} ${plural(cards.size, "card")} · ${if (reviews > 0) "$reviews ${if (reviews == 1) "needs" else "need"} review" else boardQuietSummary(cards)}",
                                    color = DieterMuted,
                                    fontSize = 11.sp,
                                )
                            }
                            if (selected) Icon(Icons.Default.Check, "Selected", tint = DieterShell)
                        }
                    }
                }
            }
            FilledTonalButton(onClick = { onDismiss(); model.showBoardOverview() }, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                Icon(Icons.Outlined.ViewKanban, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("All projects")
            }
        }
    }
}

@Composable
internal fun ProjectPickerSheet(
    state: DieterUiState,
    target: Destination,
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit,
) {
    val isFiles = target == Destination.FILES
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = 22.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (isFiles) Icons.Outlined.FolderOpen else Icons.Outlined.CalendarMonth,
                    contentDescription = null,
                    tint = DieterShell,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    if (isFiles) "Open files in" else "Open schedules in",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Text(
                "Choose a project to browse.",
                color = DieterMuted,
                fontSize = 12.sp,
                modifier = Modifier.padding(start = 2.dp, bottom = 4.dp),
            )
            state.projects.forEach { project ->
                val selected = project.id == state.selectedProjectId
                val projectOnline = state.presentedProjectReplicas[project.id]?.online != false
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                        .then(
                            if (selected) {
                                Modifier.background(DieterShellTint.copy(alpha = 0.55f))
                                    .border(1.dp, DieterShell.copy(alpha = 0.65f), RoundedCornerShape(16.dp))
                            } else {
                                Modifier
                            },
                        )
                        .clickable(enabled = projectOnline) { onSelect(project.id) }
                        .alpha(if (projectOnline) 1f else 0.42f)
                        .padding(horizontal = 12.dp, vertical = 12.dp)
                        .testTag("project-picker-${project.id}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BoardMark(stableAccent(project.id), Modifier.size(24.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(project.name, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                        Text(
                            buildString {
                                state.presentedProjectReplicas[project.id]?.let { append(it.hostname).append("  ·  ") }
                                append(compactProjectPath(project.path))
                                if (!projectOnline) append("  ·  Offline")
                            },
                            color = DieterMuted,
                            fontSize = 11.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    if (selected) Icon(Icons.Default.Check, "Current project", tint = DieterShell)
                }
            }
        }
    }
}

@Composable
internal fun BoardMark(color: Color, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(4.dp).height(18.dp).clip(CircleShape).background(color))
        Box(Modifier.width(4.dp).height(13.dp).clip(CircleShape).background(color.copy(alpha = 0.82f)))
        Box(Modifier.width(4.dp).height(8.dp).clip(CircleShape).background(color.copy(alpha = 0.68f)))
    }
}

internal fun stableAccent(id: String): Color {
    val option = LabelColorPalette[Math.floorMod(id.hashCode(), LabelColorPalette.size)]
    return runCatching { Color(option.value.toColorInt()) }.getOrDefault(DieterShellDeep)
}

internal fun laneColor(lane: String): Color = when {
    lane.contains("review", true) -> DieterAmber
    lane.contains("done", true) -> DieterEyes
    lane.contains("running", true) -> DieterRunning
    else -> DieterMuted.copy(alpha = 0.58f)
}

internal fun compactProjectPath(path: String): String {
    val marker = "/Development/"
    return if (marker in path) "~$marker${path.substringAfter(marker)}" else path
}

internal fun boardQuietSummary(cards: List<BoardCard>): String = when {
    cards.any { it.runtime.contains("running", true) || it.lane.contains("running", true) } -> "${cards.count { it.runtime.contains("running", true) || it.lane.contains("running", true) }} running"
    cards.isEmpty() -> "empty"
    else -> "quiet"
}

internal fun plural(count: Int, word: String): String = if (count == 1) word else "${word}s"

@Composable
internal fun BoardList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier, showAllLanes: Boolean = false) {
    var switcherOpen by remember { mutableStateOf(false) }
    var quickTaskOpen by remember(state.selectedBoardId) { mutableStateOf(false) }
    var quickTaskStory by rememberSaveable(state.selectedBoardId) { mutableStateOf("") }
    var searchOpen by remember { mutableStateOf(false) }
    var query by remember(state.selectedBoardId) { mutableStateOf("") }
    var selectedLabelId by remember(state.selectedBoardId) { mutableStateOf("") }
    var selectedMachineId by remember(state.selectedBoardId) { mutableStateOf<String?>(null) }
    val labelDragState = remember(state.selectedBoardId) { BoardLabelDragState() }
    var boardListOrigin by remember { mutableStateOf(Offset.Zero) }
    val dragPreviewOffsetPx = with(LocalDensity.current) { 18.dp.roundToPx() }
    val boardCards = remember(state.cards, state.selectedBoardId, selectedLabelId, selectedMachineId, query) {
        state.cards.filter { card ->
            card.boardId == state.selectedBoardId &&
                (selectedMachineId == null || selectedMachineId == card.ownerDaemonId) &&
                (selectedLabelId.isBlank() || selectedLabelId in card.labelIdsList) &&
                (query.isBlank() || card.title.contains(query, ignoreCase = true) || card.summary.contains(query, ignoreCase = true))
        }
    }
    if (!state.loading && state.project != null && state.board == null) {
        BoardlessProjectState(state, model, modifier)
        return
    }
    Box(modifier.onGloballyPositioned { boardListOrigin = it.positionInRoot() }) {
        Column(Modifier.fillMaxSize()) {
            BoardDetailHeader(
                state = state,
                model = model,
                onOpenSwitcher = {
                    model.refreshSpaces()
                    switcherOpen = true
                },
                onToggleSearch = { searchOpen = !searchOpen },
            )
            if (!state.connected && state.projects.isEmpty()) {
                ConnectionEmptyState(state, model)
                return@Column
            }
            if (searchOpen) CompactSearchField(query, { query = it }, "Search this board")
            BoardLabelFilters(
                state = state,
                selectedLabelId = selectedLabelId,
                selectedMachineId = selectedMachineId,
                onMachineSelect = { selectedMachineId = it },
                dragState = labelDragState,
                onSelect = { selectedLabelId = it },
                onDrop = { cardId, labelId -> model.assignLabelToBoardCard(cardId, labelId) },
            )
            if (!showAllLanes) LaneTabs(state, model, boardCards)
            val lanes = state.board?.lanesList.orEmpty()
            if (state.loading && lanes.isEmpty()) {
                LoadingState()
            } else if (lanes.isEmpty()) {
                EmptyList("No workflow lanes", "This board does not have a configured workflow.", Icons.Outlined.ViewKanban)
            } else {
                BoardLanePager(state, model, lanes, boardCards, labelDragState, Modifier.weight(1f), showAllLanes)
            }
        }
        FloatingActionButton(
            onClick = { quickTaskOpen = !quickTaskOpen },
            modifier = Modifier.align(Alignment.BottomEnd).padding(20.dp).testTag("new-card"),
            containerColor = DieterPane,
            contentColor = DieterAbyss,
            shape = RoundedCornerShape(24.dp),
        ) { Icon(Icons.Default.Add, contentDescription = "Quick task") }
        labelDragState.label?.let { label ->
            if (labelDragState.pointerInRoot.isSpecified) {
                Surface(
                    modifier = Modifier
                        .offset {
                            IntOffset(
                                (labelDragState.pointerInRoot.x - boardListOrigin.x + dragPreviewOffsetPx).toInt(),
                                (labelDragState.pointerInRoot.y - boardListOrigin.y + dragPreviewOffsetPx).toInt(),
                            )
                        }
                        .zIndex(3f),
                    shape = RoundedCornerShape(12.dp),
                    color = DieterSurfaceHigh,
                    border = androidx.compose.foundation.BorderStroke(1.dp, DieterEyes.copy(alpha = 0.7f)),
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        Modifier.padding(horizontal = 11.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        LabelPill(label.name, label.color)
                        Text("Drop onto a card", color = DieterMuted, fontSize = 11.sp)
                    }
                }
            }
        }
    }
    if (switcherOpen) {
        BoardQuickSwitcher(
            state = state,
            model = model,
            onDismiss = { switcherOpen = false },
        )
    }
    if (quickTaskOpen) {
        QuickTaskPopover(
            state = state,
            defaults = resolveConversationCreationPreferences(model.conversationCreationPreferences, if (state.creationCatalogReady) state.harnesses else emptyList()),
            onSelectCheckout = model::selectCreationCheckout,
            story = quickTaskStory,
            onStoryChange = { quickTaskStory = it },
            onDismiss = { quickTaskOpen = false },
            onOpenFull = {
                quickTaskOpen = false
                model.openSurface(AppSurface.NEW_CARD)
            },
            onCreate = { story ->
                model.createQuickTask(story) {
                    quickTaskOpen = false
                    quickTaskStory = ""
                }
            },
        )
    }
}

@Composable
private fun BoardlessProjectState(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(28.dp).testTag("board-empty"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Surface(shape = RoundedCornerShape(18.dp), color = DieterShellTint, modifier = Modifier.size(64.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.ViewKanban, null, Modifier.size(28.dp), tint = DieterShell)
            }
        }
        Spacer(Modifier.height(16.dp))
        Text("No boards yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(
            "Create a board for ${state.project?.name ?: "this project"} to organize conversations.",
            color = DieterMuted,
            fontSize = 13.sp,
            lineHeight = 19.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))
        Button(onClick = { model.openNewBoard(state.selectedProjectId) }, modifier = Modifier.testTag("board-empty-create")) {
            Icon(Icons.Default.Add, null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(7.dp))
            Text("Create board")
        }
    }
}

@Composable
internal fun QuickTaskPopover(
    state: DieterUiState,
    defaults: ResolvedConversationCreationPreferences,
    story: String,
    onStoryChange: (String) -> Unit,
    onDismiss: () -> Unit,
    onOpenFull: () -> Unit,
    onCreate: (String) -> Unit,
    onSelectCheckout: (String) -> Unit = {},
) {
    val checkout = state.creationCheckout
    LaunchedEffect(checkout?.id) {
        if (checkout != null && state.creationMachine?.online == true && !state.creationCatalogReady) {
            onSelectCheckout(checkout.id)
        }
    }
    val cleanStory = story.trim()
    val harness = state.harnesses.firstOrNull { it.id == defaults.provider }
    val selectedModel = harness?.modelsList?.firstOrNull { it.id == defaults.model }
    val lane = state.board?.lanesList?.firstOrNull()
    val density = LocalDensity.current
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val imeVisible = WindowInsets.ime.getBottom(density) > 0
    val currentImeVisible by rememberUpdatedState(imeVisible)
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { nextValue ->
            if (nextValue == SheetValue.Hidden && currentImeVisible) {
                focusManager.clearFocus()
                keyboardController?.hide()
                false
            } else {
                true
            }
        },
    )
    val summary = buildString {
        append(lane?.name ?: "Todo")
        append(" · ").append(defaults.workspaceMode.title)
        if (harness != null && selectedModel != null) {
            append(" · ").append(harness.name).append(" / ").append(selectedModel.name)
        } else {
            append(" · Agent defaults")
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = DieterSurfaceHigh,
    ) {
        Column(
            Modifier.fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .imePadding()
                .navigationBarsPadding()
                .padding(start = 18.dp, end = 18.dp, bottom = 22.dp)
                .testTag("quick-task-popover"),
            verticalArrangement = Arrangement.spacedBy(13.dp),
        ) {
            Row(verticalAlignment = Alignment.Top) {
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = DieterShellTint,
                ) {
                    Icon(
                        Icons.Outlined.Bolt,
                        contentDescription = null,
                        tint = DieterShell,
                        modifier = Modifier.padding(8.dp).size(18.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("Quick task", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    Text("Describe the task. A title is added automatically.", color = DieterMuted, fontSize = 11.sp)
                }
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close quick task", tint = DieterMuted)
                }
            }
            CreationDestinationPicker(state, onSelectCheckout)
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
            OutlinedTextField(
                value = story,
                onValueChange = onStoryChange,
                label = { Text("Task story") },
                placeholder = { Text("What should the agent accomplish?") },
                minLines = 3,
                maxLines = 6,
                modifier = Modifier.fillMaxWidth().testTag("quick-task-story"),
            )
            Text(summary, color = DieterMuted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onOpenFull) { Text("More options") }
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = { onCreate(cleanStory) },
                    enabled = cleanStory.isNotEmpty() && !state.working && state.creationCatalogReady &&
                        harnessCatalogSupportsSelection(state.harnesses, defaults.provider, defaults.model) && state.board != null,
                    modifier = Modifier.testTag("quick-task-create"),
                ) {
                    Icon(Icons.Outlined.Bolt, contentDescription = null, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Add task")
                }
            }
        }
    }
}

@Composable
internal fun BoardLanePager(
    state: DieterUiState,
    model: DieterViewModel,
    lanes: List<com.dbpprt.dieter.v1.Lane>,
    boardCards: List<BoardCard>,
    labelDragState: BoardLabelDragState,
    modifier: Modifier = Modifier,
    showAllLanes: Boolean = false,
) {
    var revealedCardId by remember(state.selectedBoardId, state.selectedLane) { mutableStateOf<String?>(null) }
    var movingCard by remember(state.selectedBoardId) { mutableStateOf<BoardCard?>(null) }
    var editingCard by remember(state.selectedBoardId) { mutableStateOf<BoardCard?>(null) }
    var activityNow by remember { mutableStateOf(Instant.now()) }
    val laneIds = lanes.map { it.id }
    val selectedLane by rememberUpdatedState(state.selectedLane)
    val selectedPage = lanes.indexOfFirst { it.id == state.selectedLane }.coerceAtLeast(0)
    val pagerState = rememberPagerState(initialPage = selectedPage, pageCount = { lanes.size })

    LaunchedEffect(laneIds, state.selectedLane, showAllLanes) {
        if (showAllLanes) return@LaunchedEffect
        val page = lanes.indexOfFirst { it.id == state.selectedLane }.coerceAtLeast(0)
        if (pagerState.currentPage != page) pagerState.animateScrollToPage(page)
    }
    LaunchedEffect(pagerState, laneIds, showAllLanes) {
        if (showAllLanes) return@LaunchedEffect
        snapshotFlow { pagerState.settledPage }
            .distinctUntilChanged()
            .collect { page ->
                val lane = lanes.getOrNull(page)?.id ?: return@collect
                if (lane != selectedLane) model.selectLane(lane)
            }
    }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            activityNow = Instant.now()
        }
    }

    val laneContent: @Composable (Int) -> Unit = { page ->
        val lane = lanes[page]
        val sortDirection = if (state.sharedLaneSortDirections["lane.${state.selectedBoardId}.${lane.id}.sort"] == "ascending") CardPlacementSortDirection.ASCENDING else CardPlacementSortDirection.DESCENDING
        val visible = remember(boardCards, lane.id, sortDirection, state.pendingCardMoves) {
            cardsByPlacement(
                boardCards.filter { card -> card.lane == lane.id },
                direction = sortDirection,
                moves = state.pendingCardMoves,
            )
        }
        Column(Modifier.fillMaxSize()) {
            if (showAllLanes) {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 16.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).background(laneColor(lane.id), CircleShape))
                    Text(lane.name, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f).padding(start = 8.dp))
                    Text(visible.size.toString(), style = MaterialTheme.typography.labelMedium, color = DieterMuted)
                }
            }
            LaneSortButton(
                laneName = lane.name,
                direction = sortDirection,
                onToggle = { model.toggleLaneSort(state.selectedBoardId, lane.id) },
                modifier = Modifier.align(Alignment.End),
            )
            if (state.loading && visible.isEmpty()) {
                LoadingState(Modifier.weight(1f))
            } else if (visible.isEmpty()) {
                EmptyList(
                    "Nothing in this lane",
                    "Create a local-agent card to get work moving.",
                    Icons.Outlined.ViewKanban,
                    Modifier.weight(1f),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().weight(1f).testTag("board-card-list-${lane.id}"),
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 96.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    items(visible, key = { it.id }) { card ->
                        SwipeableWorkCard(
                            card = card,
                            machineName = state.machineLabel(card.ownerDaemonId),
                            board = state.board,
                            selected = card.id == state.selectedCardId,
                            pending = card.id in state.pendingCardIds ||
                                state.cardOperations[card.id] == CardOperation.MOVING,
                            operation = state.cardOperations[card.id],
                            operationError = state.cardOperationErrors[card.id],
                            activityNow = activityNow,
                            revealed = revealedCardId == card.id,
                            onReveal = { revealedCardId = card.id },
                            onCloseActions = { if (revealedCardId == card.id) revealedCardId = null },
                            onMove = {
                                revealedCardId = null
                                movingCard = card
                            },
                            onEdit = {
                                revealedCardId = null
                                editingCard = card
                            },
                            onArchive = {
                                revealedCardId = null
                                model.archiveBoardCard(card.id)
                            },
                            onStart = { model.startBoardCard(card.id) },
                            labelDragState = labelDragState,
                            onClick = { model.openCard(card, Destination.BOARD) },
                        )
                    }
                }
            }
        }
    }

    if (showAllLanes) {
        BoxWithConstraints(modifier.fillMaxWidth().testTag("tablet-board-lanes")) {
            val laneWidth = (maxWidth / lanes.size.coerceAtLeast(1)).coerceIn(220.dp * LocalDensity.current.fontScale.coerceAtLeast(1f), 360.dp * LocalDensity.current.fontScale.coerceAtLeast(1f))
            LazyRow(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 8.dp)) {
                items(lanes.size, key = { lanes[it].id }) { page ->
                    Box(Modifier.width(laneWidth).fillMaxHeight().testTag("tablet-lane-${lanes[page].id}")) { laneContent(page) }
                }
            }
        }
    } else {
        HorizontalPager(state = pagerState, modifier = modifier.fillMaxWidth(), key = { lanes[it].id }) { laneContent(it) }
    }

    movingCard?.let { card ->
        MoveCardSheet(
            card = card,
            lanes = lanes,
            onDismiss = { movingCard = null },
            onMove = { lane ->
                movingCard = null
                model.moveBoardCard(card.id, lane)
            },
        )
    }
    editingCard?.let { card ->
        EditCardSheet(
            card = card,
            working = state.working,
            onDismiss = { editingCard = null },
            onSave = { title, task ->
                editingCard = null
                model.editBoardCard(card.id, title, task)
            },
        )
    }
}

@Composable
internal fun LaneSortButton(
    laneName: String,
    direction: CardPlacementSortDirection,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val descending = direction == CardPlacementSortDirection.DESCENDING
    val currentLabel = if (descending) "reverse board order" else "board order"
    val nextLabel = if (descending) "board order" else "reverse board order"
    TextButton(
        onClick = onToggle,
        modifier = modifier
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .testTag("lane-sort-${laneName.lowercase().replace(' ', '-')}")
            .semantics {
                contentDescription = "$laneName lane sorted $currentLabel; sort $nextLabel"
            },
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
    ) {
        Icon(
            if (descending) Icons.Outlined.ArrowDownward else Icons.Outlined.ArrowUpward,
            contentDescription = null,
            modifier = Modifier.size(17.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(if (descending) "Reverse board order" else "Board order", fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}
