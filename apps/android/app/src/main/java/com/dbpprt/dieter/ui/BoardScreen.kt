@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.DragHandle
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
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
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import com.dbpprt.dieter.connection.ProjectHost
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
    if (state.boardOverviewVisible) {
        SpacesOverview(state, model, Modifier.fillMaxSize().padding(contentPadding))
        return
    }
    if (!expanded && state.selectedCardId != null) {
        CardDetailScreen(state, model, Modifier.padding(contentPadding))
        return
    }
    if (expanded) {
        Row(Modifier.fillMaxSize().padding(contentPadding)) {
            BoardList(state, model, Modifier.weight(0.43f))
            HorizontalPaneDivider()
            if (state.selectedCardId == null) {
                EmptyDetail("Select a card", "Its conversation and comments will stay beside the board.", Icons.Outlined.ViewKanban, Modifier.weight(0.57f))
            } else {
                CardDetailScreen(state, model, Modifier.weight(0.57f), showBack = false)
            }
        }
    } else {
        BoardList(state, model, Modifier.fillMaxSize().padding(contentPadding))
    }
}

@Composable
internal fun SpacesOverview(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    var searchOpen by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    val projectDragState = remember { ProjectDragState() }
    val haptic = LocalHapticFeedback.current
    val boardsByProject = remember(state.spaceBoards) { state.spaceBoards.groupBy(Board::getProjectId) }
    val cardsByProject = remember(state.spaceCards) { state.spaceCards.groupBy(BoardCard::getProjectId) }
    val visibleProjects = remember(state.projects, boardsByProject, query) {
        state.projects.filter { project ->
            query.isBlank() || project.name.contains(query, true) || project.path.contains(query, true) ||
                boardsByProject[project.id].orEmpty().any { it.name.contains(query, true) }
        }
    }
    val reviewCount = remember(state.spaceCards) { state.spaceCards.count { it.lane.contains("review", true) } }

    Column(modifier) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 10.dp, top = 18.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Spaces", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    "${state.projects.size} ${plural(state.projects.size, "project")} · ${state.spaceBoards.size} ${plural(state.spaceBoards.size, "board")} · $reviewCount ${if (reviewCount == 1) "needs" else "need"} you",
                    color = DieterMuted,
                    fontSize = 12.sp,
                )
            }
            IconButton(onClick = { searchOpen = !searchOpen }) { Icon(Icons.Outlined.Search, "Search spaces") }
            IconButton(onClick = { model.openSurface(AppSurface.APP_SETTINGS) }) {
                Icon(Icons.Outlined.Settings, "App settings", tint = DieterMuted)
            }
        }
        if (searchOpen) CompactSearchField(query, { query = it }, "Search projects and boards")
        val showProjectHosts = state.presentedProjectHosts.values.map { it.daemonId }.distinct().size > 1
        if (state.spacesLoading) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = DieterShell)
        SurfaceErrorBanner(state.error, model::clearError)
        if (!state.connected && state.projects.isEmpty()) {
            ConnectionEmptyState(state, model)
        } else if (state.loading && state.projects.isEmpty()) {
            LoadingState()
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().testTag("spaces-overview"),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(visibleProjects, key = { it.id }) { project ->
                    val dragged = projectDragState.projectId == project.id
                    var originInRoot by remember(project.id) { mutableStateOf(Offset.Zero) }
                    DisposableEffect(projectDragState, project.id) {
                        onDispose { projectDragState.unregister(project.id) }
                    }
                    ProjectSpaceCard(
                        project = project,
                        host = state.presentedProjectHosts[project.id]?.takeIf { showProjectHosts },
                        boards = boardsByProject[project.id].orEmpty(),
                        cards = cardsByProject[project.id].orEmpty(),
                        dragged = dragged,
                        dropTarget = projectDragState.targetProjectId == project.id,
                        onOpenBoard = { board -> model.openBoard(project.id, board.id) },
                        modifier = Modifier
                            .fillMaxWidth()
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
                item {
                    Surface(
                        onClick = { model.openSurface(AppSurface.NEW_PROJECT) },
                        color = Color.Transparent,
                        shape = RoundedCornerShape(18.dp),
                        modifier = Modifier.fillMaxWidth()
                            .dashedBorder(DieterOutline.copy(alpha = 0.9f), cornerRadius = 18.dp)
                            .testTag("add-git-project"),
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 15.dp),
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
}

@Composable
internal fun ProjectSpaceCard(
    project: Project,
    host: ProjectHost?,
    boards: List<Board>,
    cards: List<BoardCard>,
    dragged: Boolean,
    dropTarget: Boolean,
    onOpenBoard: (Board) -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = stableAccent(project.id)
    val reviewCount = cards.count { it.lane.contains("review", true) }
    Card(
        colors = CardDefaults.cardColors(containerColor = DieterSurface),
        border = androidx.compose.foundation.BorderStroke(
            if (dropTarget) 2.dp else 1.dp,
            when {
                dropTarget -> DieterShellDeep
                reviewCount > 0 -> DieterShell.copy(alpha = 0.24f)
                else -> DieterOutline.copy(alpha = 0.72f)
            },
        ),
        shape = RoundedCornerShape(20.dp),
        elevation = CardDefaults.cardElevation(defaultElevation = if (dragged) 10.dp else 0.dp),
        modifier = modifier,
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(shape = RoundedCornerShape(12.dp), color = accent, modifier = Modifier.size(40.dp)) {
                    Box(contentAlignment = Alignment.Center) {
                        Text(project.name.trim().take(1).lowercase().ifBlank { "·" }, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                    }
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(project.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(compactProjectPath(project.path), color = DieterMuted, fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        host?.let {
                            Spacer(Modifier.width(7.dp))
                            ProjectHostBadge(it)
                        }
                    }
                }
                if (reviewCount > 0) {
                    Surface(shape = RoundedCornerShape(50), color = DieterAmber.copy(alpha = 0.14f)) {
                        Text("$reviewCount review", color = DieterAmber, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
                    }
                } else {
                    Text("quiet", color = DieterMuted, fontSize = 11.sp)
                }
                Spacer(Modifier.width(8.dp))
                Icon(Icons.Outlined.DragHandle, null, tint = DieterMuted, modifier = Modifier.size(20.dp))
            }
            if (boards.isEmpty()) {
                Text("No boards yet", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp))
            }
            boards.forEach { board ->
                val boardCards = cards.filter { it.boardId == board.id }
                Surface(
                    onClick = { onOpenBoard(board) },
                    color = MaterialTheme.colorScheme.background.copy(alpha = 0.58f),
                    shape = RoundedCornerShape(17.dp),
                    modifier = Modifier.fillMaxWidth().testTag("space-board-${board.id}"),
                ) {
                    Row(Modifier.padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                        BoardMark(stableAccent(board.id), Modifier.size(22.dp))
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                            Text(board.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            BoardProgress(board, boardCards)
                        }
                        Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted, modifier = Modifier.size(18.dp))
                    }
                }
            }
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
internal fun ProjectHostBadge(host: ProjectHost) {
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
                    DropdownMenuItem(text = { Text("All spaces") }, onClick = { menuOpen = false; model.showBoardOverview() })
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
                            state.presentedProjectHosts[project.id]?.let { append("  ·  ").append(it.hostname) }
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
                Text("All spaces")
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
                val projectOnline = state.presentedProjectHosts[project.id]?.online != false
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
                                state.presentedProjectHosts[project.id]?.let { append(it.hostname).append("  ·  ") }
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
internal fun BoardList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    var switcherOpen by remember { mutableStateOf(false) }
    var quickTaskOpen by remember(state.selectedBoardId) { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    var query by remember(state.selectedBoardId) { mutableStateOf("") }
    var selectedLabelId by remember(state.selectedBoardId) { mutableStateOf("") }
    val labelDragState = remember(state.selectedBoardId) { BoardLabelDragState() }
    var boardListOrigin by remember { mutableStateOf(Offset.Zero) }
    val dragPreviewOffsetPx = with(LocalDensity.current) { 18.dp.roundToPx() }
    val boardCards = remember(state.cards, state.selectedBoardId, selectedLabelId, query) {
        state.cards.filter { card ->
            card.boardId == state.selectedBoardId &&
                (selectedLabelId.isBlank() || selectedLabelId in card.labelIdsList) &&
                (query.isBlank() || card.title.contains(query, ignoreCase = true) || card.summary.contains(query, ignoreCase = true))
        }
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
                dragState = labelDragState,
                onSelect = { selectedLabelId = it },
                onDrop = { cardId, labelId -> model.assignLabelToBoardCard(cardId, labelId) },
            )
            LaneTabs(state, model, boardCards)
            val lanes = state.board?.lanesList.orEmpty()
            if (state.loading && lanes.isEmpty()) {
                LoadingState()
            } else if (lanes.isEmpty()) {
                EmptyList("No workflow lanes", "This board does not have a configured workflow.", Icons.Outlined.ViewKanban)
            } else {
                BoardLanePager(state, model, lanes, boardCards, labelDragState, Modifier.weight(1f))
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
            defaults = resolveConversationCreationPreferences(model.conversationCreationPreferences, state.harnesses),
            onDismiss = { quickTaskOpen = false },
            onOpenFull = {
                quickTaskOpen = false
                model.openSurface(AppSurface.NEW_CARD)
            },
            onCreate = { story ->
                quickTaskOpen = false
                model.createQuickTask(story)
            },
        )
    }
}

@Composable
internal fun QuickTaskPopover(
    state: DieterUiState,
    defaults: ResolvedConversationCreationPreferences,
    onDismiss: () -> Unit,
    onOpenFull: () -> Unit,
    onCreate: (String) -> Unit,
) {
    var story by remember(state.selectedBoardId) { mutableStateOf("") }
    val cleanStory = story.trim()
    val harness = state.harnesses.firstOrNull { it.id == defaults.provider }
    val selectedModel = harness?.modelsList?.firstOrNull { it.id == defaults.model }
    val lane = state.board?.lanesList?.firstOrNull()
    val width = (LocalConfiguration.current.screenWidthDp.dp - 32.dp).coerceAtMost(380.dp)
    val summary = buildString {
        append(lane?.name ?: "Todo")
        append(" · ").append(defaults.workspaceMode.title)
        if (harness != null && selectedModel != null) {
            append(" · ").append(harness.name).append(" / ").append(selectedModel.name)
        } else {
            append(" · Agent defaults")
        }
    }

    Popup(
        alignment = Alignment.BottomEnd,
        offset = IntOffset(-20, -88),
        onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = true),
    ) {
        Surface(
            modifier = Modifier.width(width).testTag("quick-task-popover"),
            shape = RoundedCornerShape(20.dp),
            color = DieterSurfaceHigh,
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
            shadowElevation = 14.dp,
        ) {
            Column(
                Modifier.padding(16.dp),
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
                        Text("Enter the story. GPT Spark writes a 4–6 word title.", color = DieterMuted, fontSize = 11.sp)
                    }
                }
                OutlinedTextField(
                    value = story,
                    onValueChange = { story = it },
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
                        enabled = cleanStory.isNotEmpty() && !state.working && state.project != null && state.board != null,
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
}

@Composable
internal fun BoardLanePager(
    state: DieterUiState,
    model: DieterViewModel,
    lanes: List<com.dbpprt.dieter.v1.Lane>,
    boardCards: List<BoardCard>,
    labelDragState: BoardLabelDragState,
    modifier: Modifier = Modifier,
) {
    var revealedCardId by remember(state.selectedBoardId, state.selectedLane) { mutableStateOf<String?>(null) }
    var movingCard by remember(state.selectedBoardId) { mutableStateOf<BoardCard?>(null) }
    var editingCard by remember(state.selectedBoardId) { mutableStateOf<BoardCard?>(null) }
    val laneSortDirections = remember(state.selectedBoardId) { mutableStateMapOf<String, CardCreationSortDirection>() }
    var activityNow by remember { mutableStateOf(Instant.now()) }
    val laneIds = lanes.map { it.id }
    val selectedLane by rememberUpdatedState(state.selectedLane)
    val selectedPage = lanes.indexOfFirst { it.id == state.selectedLane }.coerceAtLeast(0)
    val pagerState = rememberPagerState(initialPage = selectedPage, pageCount = { lanes.size })

    LaunchedEffect(laneIds, state.selectedLane) {
        val page = lanes.indexOfFirst { it.id == state.selectedLane }.coerceAtLeast(0)
        if (pagerState.currentPage != page) pagerState.animateScrollToPage(page)
    }
    LaunchedEffect(pagerState, laneIds) {
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

    HorizontalPager(
        state = pagerState,
        modifier = modifier.fillMaxWidth(),
        key = { lanes[it].id },
    ) { page ->
        val lane = lanes[page]
        val sortDirection = laneSortDirections[lane.id] ?: CardCreationSortDirection.DESCENDING
        val visible = remember(boardCards, lane.id, sortDirection) {
            cardsByCreationTime(
                boardCards.filter { card -> card.lane == lane.id },
                direction = sortDirection,
            )
        }
        Column(Modifier.fillMaxSize()) {
            LaneSortButton(
                laneName = lane.name,
                direction = sortDirection,
                onToggle = { laneSortDirections[lane.id] = sortDirection.toggled() },
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
                            board = state.board,
                            selected = card.id == state.selectedCardId,
                            pending = card.id in state.pendingCardIds,
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
    direction: CardCreationSortDirection,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val descending = direction == CardCreationSortDirection.DESCENDING
    val currentLabel = if (descending) "newest first" else "oldest first"
    val nextLabel = if (descending) "oldest first" else "newest first"
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
        Text(if (descending) "Newest first" else "Oldest first", fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}
