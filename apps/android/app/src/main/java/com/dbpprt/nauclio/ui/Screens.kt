@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.nauclio.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.DragHandle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.LocalOffer
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.isSpecified
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import com.dbpprt.nauclio.connection.ProjectHost
import androidx.compose.ui.zIndex
import androidx.core.graphics.toColorInt
import com.dbpprt.nauclio.ui.theme.NauclioAmber
import com.dbpprt.nauclio.ui.theme.NauclioSeafoam
import com.dbpprt.nauclio.ui.theme.NauclioAegean
import com.dbpprt.nauclio.ui.theme.NauclioCobalt
import com.dbpprt.nauclio.ui.theme.NauclioMuted
import com.dbpprt.nauclio.ui.theme.NauclioOutline
import com.dbpprt.nauclio.ui.theme.NauclioSurface
import com.dbpprt.nauclio.ui.theme.NauclioSurfaceHigh
import com.dbpprt.nauclio.v1.Board
import com.dbpprt.nauclio.v1.Card as BoardCard
import com.dbpprt.nauclio.v1.FileDocument
import com.dbpprt.nauclio.v1.Project
import com.dbpprt.nauclio.v1.QueuedMessage
import com.dbpprt.nauclio.v1.Schedule
import com.dbpprt.nauclio.v1.MessagePart
import com.dbpprt.nauclio.v1.Harness
import com.dbpprt.nauclio.v1.Subagent
import com.dbpprt.nauclio.v1.TaskPlan
import com.dbpprt.nauclio.v1.UiMessage
import com.dbpprt.nauclio.v1.ToolOutput
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private const val PROJECT_CHAT_PREVIEW_COUNT = 5

private data class DraggedBoardLabel(val id: String, val name: String, val color: String)

private class BoardLabelDragState {
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
    state: NauclioUiState,
    model: NauclioViewModel,
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
private fun SpacesOverview(state: NauclioUiState, model: NauclioViewModel, modifier: Modifier = Modifier) {
    var searchOpen by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    val projectDragState = remember { ProjectDragState() }
    val haptic = LocalHapticFeedback.current
    val visibleProjects = state.projects.filter { project ->
        query.isBlank() || project.name.contains(query, true) || project.path.contains(query, true) ||
            state.spaceBoards.any { it.projectId == project.id && it.name.contains(query, true) }
    }
    val reviewCount = state.spaceCards.count { it.lane.contains("review", true) }

    Column(modifier) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 10.dp, top = 18.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Spaces", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    "${state.projects.size} ${plural(state.projects.size, "project")} · ${state.spaceBoards.size} ${plural(state.spaceBoards.size, "board")} · $reviewCount ${if (reviewCount == 1) "needs" else "need"} you",
                    color = NauclioMuted,
                    fontSize = 12.sp,
                )
            }
            IconButton(onClick = { searchOpen = !searchOpen }) { Icon(Icons.Outlined.Search, "Search spaces") }
        }
        if (searchOpen) CompactSearchField(query, { query = it }, "Search projects and boards")
        val machines = state.endpointConnections.filter { it.daemonId != null }
        if (machines.size > 1) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 7.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                machines.forEach { machine ->
                    val selected = machine.phase == com.dbpprt.nauclio.connection.EndpointPhase.CONNECTED
                    Surface(
                        onClick = { if (machine.online) model.selectDaemon(machine.id) },
                        enabled = machine.online,
                        shape = RoundedCornerShape(50),
                        color = if (selected) NauclioAegean.copy(alpha = 0.13f) else NauclioSurfaceHigh,
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (selected) NauclioCobalt else NauclioOutline),
                    ) {
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(7.dp).background(if (machine.online) NauclioSeafoam else NauclioMuted, CircleShape))
                            Spacer(Modifier.width(7.dp))
                            Text(machine.label, fontSize = 11.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium)
                        }
                    }
                }
            }
        }
        if (state.spacesLoading) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = NauclioAegean)
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
                        host = state.projectHosts[project.id]?.takeIf { machines.size > 1 },
                        boards = state.spaceBoards.filter { it.projectId == project.id },
                        cards = state.spaceCards.filter { it.projectId == project.id },
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
                        border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline.copy(alpha = 0.72f)),
                        modifier = Modifier.fillMaxWidth().testTag("add-git-project"),
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 14.dp),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Default.Add, null, tint = NauclioMuted, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Add a Git project", color = NauclioMuted, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProjectSpaceCard(
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
        colors = CardDefaults.cardColors(containerColor = NauclioSurface),
        border = androidx.compose.foundation.BorderStroke(
            if (dropTarget) 2.dp else 1.dp,
            when {
                dropTarget -> NauclioCobalt
                reviewCount > 0 -> NauclioAegean.copy(alpha = 0.24f)
                else -> NauclioOutline.copy(alpha = 0.72f)
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
                        Text(compactProjectPath(project.path), color = NauclioMuted, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        host?.let {
                            Spacer(Modifier.width(7.dp))
                            ProjectHostBadge(it)
                        }
                    }
                }
                if (reviewCount > 0) {
                    Surface(shape = RoundedCornerShape(50), color = NauclioAmber.copy(alpha = 0.14f)) {
                        Text("$reviewCount review", color = NauclioAmber, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
                    }
                } else {
                    Text("quiet", color = NauclioMuted, fontSize = 11.sp)
                }
                Spacer(Modifier.width(8.dp))
                Icon(Icons.Outlined.DragHandle, null, tint = NauclioMuted, modifier = Modifier.size(20.dp))
            }
            if (boards.isEmpty()) {
                Text("No boards yet", color = NauclioMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp))
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
                        Icon(Icons.Outlined.ChevronRight, null, tint = NauclioMuted, modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
    }
}

private class ProjectDragState {
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

@Composable
private fun ProjectHostBadge(host: ProjectHost) {
    Surface(shape = RoundedCornerShape(50), color = (if (host.online) NauclioSeafoam else NauclioMuted).copy(alpha = 0.1f)) {
        Row(Modifier.padding(horizontal = 7.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(5.dp).background(if (host.online) NauclioSeafoam else NauclioMuted, CircleShape))
            Spacer(Modifier.width(5.dp))
            Text(host.hostname, color = NauclioMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

@Composable
private fun BoardProgress(board: Board, cards: List<BoardCard>) {
    val counts = board.lanesList.map { lane -> lane.id to cards.count { it.lane == lane.id } }
    val nonZero = counts.filter { it.second > 0 }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.weight(1f).height(5.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (nonZero.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxHeight().clip(CircleShape).background(NauclioOutline))
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
            color = NauclioMuted,
            fontSize = 10.sp,
            maxLines = 1,
        )
    }
}

@Composable
private fun BoardDetailHeader(
    state: NauclioUiState,
    model: NauclioViewModel,
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
                Surface(shape = RoundedCornerShape(13.dp), color = NauclioCobalt, modifier = Modifier.size(44.dp)) {
                    Box(contentAlignment = Alignment.Center) { BoardMark(Color.White, Modifier.size(25.dp)) }
                }
                Spacer(Modifier.width(11.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(board?.name ?: "Board", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Icon(Icons.Outlined.KeyboardArrowDown, null, tint = NauclioMuted, modifier = Modifier.size(18.dp))
                    }
                    Text(
                        "${state.project?.name?.lowercase() ?: "project"} · ${boardCards.size} ${plural(boardCards.size, "conversation")} · $reviews ${if (reviews == 1) "needs" else "need"} you",
                        color = NauclioMuted,
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
                                    color = NauclioMuted,
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
private fun BoardQuickSwitcher(state: NauclioUiState, model: NauclioViewModel, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = NauclioSurfaceHigh) {
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
                            state.projectHosts[project.id]?.let { append("  ·  ").append(it.hostname) }
                            append("  ·  ").append(compactProjectPath(project.path))
                        }.uppercase(),
                        color = NauclioMuted,
                        fontSize = 10.sp,
                        letterSpacing = 1.3.sp,
                        modifier = Modifier.padding(top = 8.dp, start = 4.dp),
                    )
                    boards.forEach { board ->
                        val selected = board.id == state.selectedBoardId && project.id == state.selectedProjectId
                        val cards = state.spaceCards.filter { it.boardId == board.id }
                        val reviews = cards.count { it.lane.contains("review", true) }
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                                .then(if (selected) Modifier.border(1.dp, NauclioCobalt, RoundedCornerShape(16.dp)) else Modifier)
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
                                    color = NauclioMuted,
                                    fontSize = 11.sp,
                                )
                            }
                            if (selected) Icon(Icons.Default.Check, "Selected", tint = NauclioAegean)
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
private fun BoardMark(color: Color, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(4.dp).height(18.dp).clip(CircleShape).background(color))
        Box(Modifier.width(4.dp).height(13.dp).clip(CircleShape).background(color.copy(alpha = 0.82f)))
        Box(Modifier.width(4.dp).height(8.dp).clip(CircleShape).background(color.copy(alpha = 0.68f)))
    }
}

private fun stableAccent(id: String): Color {
    val option = LabelColorPalette[Math.floorMod(id.hashCode(), LabelColorPalette.size)]
    return runCatching { Color(option.value.toColorInt()) }.getOrDefault(NauclioCobalt)
}

private fun laneColor(lane: String): Color = when {
    lane.contains("review", true) -> NauclioAmber
    lane.contains("done", true) -> NauclioSeafoam
    lane.contains("running", true) -> Color(0xFF22D3EE)
    else -> NauclioMuted.copy(alpha = 0.58f)
}

private fun compactProjectPath(path: String): String {
    val marker = "/Development/"
    return if (marker in path) "~$marker${path.substringAfter(marker)}" else path
}

private fun boardQuietSummary(cards: List<BoardCard>): String = when {
    cards.any { it.runtime.contains("running", true) || it.lane.contains("running", true) } -> "${cards.count { it.runtime.contains("running", true) || it.lane.contains("running", true) }} running"
    cards.isEmpty() -> "empty"
    else -> "quiet"
}

private fun plural(count: Int, word: String): String = if (count == 1) word else "${word}s"

@Composable
private fun BoardList(state: NauclioUiState, model: NauclioViewModel, modifier: Modifier = Modifier) {
    var switcherOpen by remember { mutableStateOf(false) }
    var searchOpen by remember { mutableStateOf(false) }
    var query by remember(state.selectedBoardId) { mutableStateOf("") }
    var selectedLabelId by remember(state.selectedBoardId) { mutableStateOf("") }
    val labelDragState = remember(state.selectedBoardId) { BoardLabelDragState() }
    var boardListOrigin by remember { mutableStateOf(Offset.Zero) }
    val dragPreviewOffsetPx = with(LocalDensity.current) { 18.dp.roundToPx() }
    val boardCards = state.cards.filter { card ->
        card.boardId == state.selectedBoardId &&
            (selectedLabelId.isBlank() || selectedLabelId in card.labelIdsList) &&
            (query.isBlank() || card.title.contains(query, ignoreCase = true) || card.summary.contains(query, ignoreCase = true))
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
            onClick = { model.openSurface(AppSurface.NEW_CARD) },
            modifier = Modifier.align(Alignment.BottomEnd).padding(20.dp).testTag("new-card"),
            containerColor = NauclioAegean,
            contentColor = Color(0xFF071426),
        ) { Icon(Icons.Default.Add, contentDescription = "New card") }
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
                    color = NauclioSurfaceHigh,
                    border = androidx.compose.foundation.BorderStroke(1.dp, NauclioSeafoam.copy(alpha = 0.7f)),
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        Modifier.padding(horizontal = 11.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        LabelPill(label.name, label.color)
                        Text("Drop onto a card", color = NauclioMuted, fontSize = 11.sp)
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
}

@Composable
private fun BoardLanePager(
    state: NauclioUiState,
    model: NauclioViewModel,
    lanes: List<com.dbpprt.nauclio.v1.Lane>,
    boardCards: List<BoardCard>,
    labelDragState: BoardLabelDragState,
    modifier: Modifier = Modifier,
) {
    var revealedCardId by remember(state.selectedBoardId, state.selectedLane) { mutableStateOf<String?>(null) }
    var movingCard by remember(state.selectedBoardId) { mutableStateOf<BoardCard?>(null) }
    var editingCard by remember(state.selectedBoardId) { mutableStateOf<BoardCard?>(null) }
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

    HorizontalPager(
        state = pagerState,
        modifier = modifier.fillMaxWidth(),
        key = { lanes[it].id },
    ) { page ->
        val lane = lanes[page]
        val visible = newestCardsFirst(boardCards.filter { card -> card.lane == lane.id })
        if (state.loading && visible.isEmpty()) {
            LoadingState()
        } else if (visible.isEmpty()) {
            EmptyList("Nothing in this lane", "Create a local-agent card to get work moving.", Icons.Outlined.ViewKanban)
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().testTag("board-card-list-${lane.id}"),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 96.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(visible, key = { it.id }) { card ->
                    SwipeableWorkCard(
                        card = card,
                        board = state.board,
                        selected = card.id == state.selectedCardId,
                        pending = card.id in state.pendingCardIds,
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
fun ChatsScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    expanded: Boolean,
    contentPadding: PaddingValues,
) {
    if (!expanded && state.selectedCardId != null) {
        CardDetailScreen(state, model, Modifier.padding(contentPadding))
        return
    }
    if (expanded) {
        Row(Modifier.fillMaxSize().padding(contentPadding)) {
            ChatsList(state, model, Modifier.weight(0.43f))
            HorizontalPaneDivider()
            if (state.selectedCardId == null) {
                EmptyDetail("Select a chat", "Open a durable conversation or start a new one.", Icons.Outlined.ChatBubbleOutline, Modifier.weight(0.57f))
            } else {
                CardDetailScreen(state, model, Modifier.weight(0.57f), showBack = false)
            }
        }
    } else {
        ChatsList(state, model, Modifier.fillMaxSize().padding(contentPadding))
    }
}

@Composable
private fun ChatsList(state: NauclioUiState, model: NauclioViewModel, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    var expandedProjects by remember { mutableStateOf(emptySet<String>()) }
    Box(modifier) {
        Column(Modifier.fillMaxSize()) {
            SimpleScreenHeader("Chats")
            SurfaceErrorBanner(state.error, model::clearError)
            CompactSearchField(query, { query = it }, "Search chats")
            val chats = state.chats
                .filter { query.isBlank() || it.title.contains(query, ignoreCase = true) }
                .sortedWith(compareByDescending<BoardCard> { it.pinned }.thenByDescending { it.lastActivityAt })
            if (!state.connected && state.projects.isEmpty()) {
                ConnectionEmptyState(state, model)
            } else if (chats.isEmpty() && state.projects.isEmpty()) {
                EmptyList("No chats yet", "Start a standalone conversation with a local agent.", Icons.Outlined.ChatBubbleOutline)
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 96.dp),
                ) {
                    val pinned = chats.filter { it.pinned }
                    if (pinned.isNotEmpty()) {
                        item { ListSectionLabel("Pinned") }
                        items(pinned, key = { it.id }) { chat -> ChatRow(chat, model) }
                    }
                    chatProjectsForQuery(state.projects, chats, query).forEach { project ->
                        val projectChats = chats.filter { !it.pinned && it.projectId == project.id }
                        val expanded = project.id in expandedProjects
                        val visibleProjectChats = if (expanded) projectChats else projectChats.take(PROJECT_CHAT_PREVIEW_COUNT)
                        item(key = "project-chat-header-${project.id}") {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                ListSectionLabel(
                                    buildString {
                                        append(project.name)
                                        state.projectHosts[project.id]?.let { append(" · ").append(it.hostname) }
                                        append(" · ").append(projectChats.size)
                                    },
                                    Modifier.weight(1f),
                                )
                                IconButton(onClick = { model.selectProject(project.id); model.openSurface(AppSurface.NEW_CHAT) }, modifier = Modifier.size(36.dp)) {
                                    Icon(Icons.Default.Add, "New chat in ${project.name}", tint = NauclioMuted, modifier = Modifier.size(18.dp))
                                }
                            }
                        }
                        if (projectChats.isEmpty() && query.isBlank()) {
                            item(key = "project-chat-empty-${project.id}") {
                                Text(
                                    "No chats yet",
                                    color = NauclioMuted,
                                    fontSize = 12.sp,
                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                                )
                            }
                        } else {
                            items(visibleProjectChats, key = { it.id }) { chat -> ChatRow(chat, model) }
                            if (projectChats.size > PROJECT_CHAT_PREVIEW_COUNT) {
                                item(key = "project-chat-more-${project.id}") {
                                    TextButton(
                                        onClick = {
                                            expandedProjects = if (expanded) {
                                                expandedProjects - project.id
                                            } else {
                                                expandedProjects + project.id
                                            }
                                        },
                                        modifier = Modifier.fillMaxWidth().testTag("project-chat-more-${project.id}"),
                                    ) {
                                        Text(
                                            if (expanded) "Show less" else "Show ${projectChats.size - PROJECT_CHAT_PREVIEW_COUNT} more",
                                            color = NauclioAegean,
                                            fontWeight = FontWeight.SemiBold,
                                        )
                                        Spacer(Modifier.width(4.dp))
                                        Icon(
                                            Icons.Outlined.KeyboardArrowDown,
                                            contentDescription = null,
                                            tint = NauclioAegean,
                                            modifier = Modifier.size(18.dp).rotate(if (expanded) 180f else 0f),
                                        )
                                    }
                                }
                            }
                        }
                    }
                    val otherChats = chats.filter { chat -> !chat.pinned && state.projects.none { it.id == chat.projectId } }
                    items(otherChats, key = { it.id }) { chat ->
                        ChatRow(chat, model)
                    }
                }
            }
        }
        ExtendedFloatingActionButton(
            onClick = { model.openSurface(AppSurface.NEW_CHAT) },
            icon = { Icon(Icons.Default.Add, null) },
            text = { Text("New chat") },
            modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).height(48.dp),
            containerColor = NauclioAegean,
            contentColor = Color(0xFF071426),
            shape = RoundedCornerShape(18.dp),
        )
    }
}

@Composable
private fun ChatRow(chat: BoardCard, model: NauclioViewModel) {
    Surface(
        color = if (chat.pinned) NauclioSurface else Color.Transparent,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp).alpha(if (model.isPendingCard(chat.id)) 0.52f else 1f),
    ) {
        Row(
            Modifier.fillMaxWidth().clickable { model.openCard(chat, Destination.CHATS) }
                .padding(horizontal = 12.dp, vertical = if (chat.pinned) 13.dp else 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (chat.pinned) {
                Surface(shape = CircleShape, color = Color(0xFF10223A), modifier = Modifier.size(36.dp)) {
                    Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.PushPin, null, tint = NauclioAegean, modifier = Modifier.size(17.dp)) }
                }
            } else {
                Box(
                    Modifier.size(10.dp).border(1.dp, if (chat.runtime.contains("running", true)) NauclioAegean else NauclioMuted, CircleShape)
                        .then(if (chat.runtime.contains("running", true)) Modifier.background(NauclioAegean, CircleShape) else Modifier),
                )
            }
            Spacer(Modifier.width(14.dp))
            Text(
                chat.title.ifBlank { "Untitled chat" },
                fontSize = 14.sp,
                fontWeight = if (chat.runtime.contains("running", true)) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(shortTimestamp(chat.lastActivityAt.ifBlank { chat.updatedAt }), color = NauclioMuted, fontSize = 11.sp)
        }
    }
}

@Composable
private fun ListSectionLabel(value: String, modifier: Modifier = Modifier) {
    Text(
        value.uppercase(),
        color = NauclioMuted,
        fontSize = 10.sp,
        letterSpacing = 1.2.sp,
        modifier = modifier.padding(start = 8.dp, top = 10.dp, bottom = 3.dp),
    )
}

@Composable
private fun SimpleScreenHeader(
    title: String,
    subtitle: String? = null,
    actions: (@Composable RowScope.() -> Unit)? = null,
) {
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp, top = 14.dp, bottom = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
            if (!subtitle.isNullOrBlank()) Text(subtitle, color = NauclioMuted, fontSize = 11.sp)
        }
        actions?.invoke(this)
    }
}

@Composable
private fun CompactSearchField(value: String, onValueChange: (String) -> Unit, placeholder: String) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            .height(42.dp).clip(RoundedCornerShape(22.dp)).background(NauclioSurfaceHigh)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.Search, null, tint = NauclioMuted, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(8.dp))
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onBackground),
            cursorBrush = SolidColor(NauclioAegean),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                if (value.isBlank()) Text(placeholder, color = NauclioMuted, fontSize = 13.sp)
                inner()
            }
        )
    }
}

@Composable
fun FilesScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
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
private fun FileList(state: NauclioUiState, model: NauclioViewModel, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    var showCreate by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    Box(modifier) {
    Column(Modifier.fillMaxSize()) {
        SimpleScreenHeader("Files", "${state.project?.name ?: "Project"} · ${state.files.size} loaded") {
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
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(13.dp)).background(Color(0xFF152B45))
                                .padding(horizontal = 12.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Outlined.KeyboardArrowDown, null, tint = NauclioAegean, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(10.dp))
                            Icon(Icons.Outlined.Folder, null, tint = NauclioAegean)
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
                            tint = NauclioAegean,
                        )
                        Spacer(Modifier.width(14.dp))
                        Text(entry.name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (entry.kind == "directory") Icon(Icons.Outlined.ChevronRight, null, tint = NauclioMuted)
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
private fun FilePreview(
    state: NauclioUiState,
    model: NauclioViewModel,
    modifier: Modifier = Modifier,
    showBack: Boolean = true,
) {
    val document = state.fileDocument ?: return
    val syntaxTransformation = remember(document.path) { CodeSyntaxVisualTransformation(document.path) }
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
                Text(document.path, color = NauclioMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (!document.binary) {
                IconButton(onClick = { showMove = true }) { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, "Move or rename") }
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Outlined.DeleteOutline, "Delete") }
                Button(onClick = model::saveFile, enabled = state.fileDirty && !state.working) { Text("Save") }
            }
            if (!showBack) IconButton(onClick = ::close) { Icon(Icons.Outlined.Close, "Close") }
        }
        HorizontalDivider(color = NauclioOutline)
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
                    val suffix = if (state.fileDraft.length > MaxSyntaxHighlightCharacters) " · first 200k highlighted" else ""
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

@Composable
fun SchedulesScreen(state: NauclioUiState, model: NauclioViewModel, contentPadding: PaddingValues) {
    Box(Modifier.fillMaxSize().padding(contentPadding)) {
        Column(Modifier.fillMaxSize()) {
            SimpleScreenHeader(
                "Schedules",
                "${state.project?.name ?: "Project"} · ${state.schedules.count { it.enabled }} active · ${state.schedules.size} configured",
            ) {
                IconButton(onClick = model::refresh) { Icon(Icons.Outlined.Refresh, "Refresh schedules") }
            }
            SurfaceErrorBanner(state.error, model::clearError)
            if (!state.connected && state.projects.isEmpty()) {
                ConnectionEmptyState(state, model)
            } else if (state.schedules.isEmpty()) {
                ScheduleEmptyState { model.openSurface(AppSurface.SCHEDULE_EDITOR) }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 96.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(state.schedules, key = { it.id }) { schedule ->
                        ScheduleCard(schedule, state, model, onEdit = { model.openSurface(AppSurface.SCHEDULE_EDITOR, schedule) })
                    }
                }
            }
        }
        if (state.schedules.isNotEmpty()) {
            ExtendedFloatingActionButton(
                onClick = { model.openSurface(AppSurface.SCHEDULE_EDITOR) },
                icon = { Icon(Icons.Default.Add, null) },
                text = { Text("New schedule") },
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).height(48.dp),
            )
        }
    }
}

@Composable
private fun ScheduleEmptyState(onCreate: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Card(
            colors = CardDefaults.cardColors(containerColor = Color.Transparent),
            border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
            shape = RoundedCornerShape(20.dp),
        ) {
            Column(
                Modifier.padding(horizontal = 26.dp, vertical = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Surface(shape = RoundedCornerShape(14.dp), color = NauclioSurfaceHigh, modifier = Modifier.size(48.dp)) {
                    Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.CalendarMonth, null, tint = NauclioAegean) }
                }
                Spacer(Modifier.height(14.dp))
                Text("Automate recurring work", fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(6.dp))
                Text(
                    "Create cards on a project calendar, then optionally start their local agents when capacity is available.",
                    color = NauclioMuted,
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(14.dp))
                Button(onClick = onCreate) {
                    Icon(Icons.Default.Add, null, Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Create the first schedule")
                }
            }
        }
    }
}

@Composable
private fun ScheduleCard(
    schedule: Schedule,
    state: NauclioUiState,
    model: NauclioViewModel,
    onEdit: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    Card(
        onClick = { model.selectSchedule(if (state.selectedScheduleId == schedule.id) null else schedule) },
        colors = CardDefaults.cardColors(containerColor = NauclioSurfaceHigh),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(schedule.name, fontWeight = FontWeight.SemiBold)
                    Text(schedule.cron + " · " + schedule.timezone, color = NauclioMuted, fontSize = 13.sp)
                }
                Switch(checked = schedule.enabled, onCheckedChange = { model.toggleSchedule(schedule) })
            }
            if (schedule.description.isNotBlank()) Text(schedule.description, color = NauclioMuted)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = { model.runSchedule(schedule) }) {
                    Icon(Icons.Outlined.Sync, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Run now")
                }
                TextButton(onClick = { confirmDelete = true }) {
                    Icon(Icons.Outlined.DeleteOutline, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Delete")
                }
                TextButton(onClick = onEdit) {
                    Icon(Icons.Outlined.Edit, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Edit")
                }
            }
            if (schedule.nextRunAt.isNotBlank()) {
                Text("Next · ${shortTimestamp(schedule.nextRunAt)}", color = NauclioAegean, fontSize = 12.sp)
            }
            if (state.selectedScheduleId == schedule.id) {
                HorizontalDivider(color = NauclioOutline)
                Text("Recent runs", fontWeight = FontWeight.SemiBold)
                if (state.scheduleRuns.isEmpty()) {
                    Text("No occurrences yet", color = NauclioMuted, fontSize = 12.sp)
                } else {
                    state.scheduleRuns.forEach { run ->
                        Text(
                            "${run.status.ifBlank { "unknown" }} · ${shortTimestamp(run.scheduledFor.ifBlank { run.createdAt })}${run.message.takeIf { it.isNotBlank() }?.let { " · $it" }.orEmpty()}",
                            color = if (run.status == "failed") MaterialTheme.colorScheme.error else NauclioMuted,
                            fontSize = 12.sp,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
    if (confirmDelete) {
        ConfirmDialog("Delete schedule?", schedule.name, "Delete", { confirmDelete = false }) {
            confirmDelete = false
            model.deleteSchedule(schedule)
        }
    }
}

@Composable
private fun CardDetailScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    modifier: Modifier = Modifier,
    showBack: Boolean = true,
) {
    val snapshot = state.conversation
    val card = snapshot?.detail?.card ?: state.selectedCard
    var renameOpen by remember { mutableStateOf(false) }
    var labelsOpen by remember { mutableStateOf(false) }
    var actionsOpen by remember { mutableStateOf(false) }
    if (card == null) {
        LoadingState(modifier)
        return
    }
    val standalone = card.scope == "chat"
    val detailSections = detailSectionsFor(standalone)
    val detailPageCount = detailSections.size
    val commentCount = snapshot?.detail?.commentsCount ?: card.commentCount
    val subagents = snapshot?.conversation?.subagentsList.orEmpty()
    val activeSubagents = subagents.count { it.status == "running" || it.status == "pending" }
    val showDetailTabs = !standalone || subagents.isNotEmpty() || commentCount > 0
    val detailTab by rememberUpdatedState(state.detailTab)
    val detailPagerState = rememberPagerState(
        initialPage = state.detailTab.coerceIn(0, detailPageCount - 1),
        pageCount = { detailPageCount },
    )
    LaunchedEffect(state.detailTab) {
        val page = state.detailTab.coerceIn(0, detailPageCount - 1)
        if (detailPagerState.currentPage != page) detailPagerState.animateScrollToPage(page)
    }
    LaunchedEffect(detailPagerState) {
        snapshotFlow { detailPagerState.settledPage }
            .distinctUntilChanged()
            .collect { page ->
                if (page != detailTab) model.selectDetailTab(page)
            }
    }
    Column(modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (showBack) IconButton(onClick = model::closeDetail) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Column(Modifier.weight(1f)) {
                Text(card.title, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    if (card.scope == "chat") {
                        "${snapshot?.detail?.project?.name ?: state.project?.name ?: "Project"} · Standalone chat"
                    } else {
                        "${snapshot?.detail?.project?.name ?: state.project?.name ?: "Project"} / ${snapshot?.detail?.board?.name ?: state.board?.name ?: "Board"}"
                    },
                    color = NauclioMuted,
                    fontSize = 11.sp,
                )
            }
            StatusPill(card.runtime.ifBlank { snapshot?.conversation?.status ?: "idle" })
            if (card.runtime == "running" || card.runtime == "starting") {
                IconButton(onClick = model::cancelSelected, enabled = !state.working) {
                    Icon(Icons.Outlined.Cancel, "Cancel active turn")
                }
            }
            Box {
                IconButton(onClick = { actionsOpen = true }) { Icon(Icons.Outlined.MoreVert, "Conversation actions") }
                DropdownMenu(expanded = actionsOpen, onDismissRequest = { actionsOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(if (state.conversationRefreshing) "Refreshing…" else "Force refresh") },
                        leadingIcon = {
                            if (state.conversationRefreshing) {
                                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Outlined.Refresh, null)
                            }
                        },
                        enabled = !state.conversationRefreshing,
                        modifier = Modifier.testTag("force-refresh-conversation"),
                        onClick = { actionsOpen = false; model.forceRefreshConversation() },
                    )
                    DropdownMenuItem(
                        text = { Text("Rename") },
                        leadingIcon = { Icon(Icons.Outlined.Edit, null) },
                        onClick = { actionsOpen = false; renameOpen = true },
                    )
                    if (card.scope == "board") {
                        DropdownMenuItem(
                            text = { Text("Labels") },
                            leadingIcon = { Icon(Icons.Outlined.LocalOffer, null) },
                            onClick = { actionsOpen = false; labelsOpen = true },
                        )
                    } else {
                        DropdownMenuItem(
                            text = { Text(if (card.pinned) "Unpin chat" else "Pin chat") },
                            leadingIcon = { Icon(Icons.Outlined.PushPin, null) },
                            onClick = { actionsOpen = false; model.togglePin(card) },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("Archive") },
                        leadingIcon = { Icon(Icons.Outlined.Archive, null) },
                        onClick = { actionsOpen = false; model.archiveSelected() },
                    )
                }
            }
        }
        if (showDetailTabs) {
            PrimaryTabRow(selectedTabIndex = state.detailTab, containerColor = MaterialTheme.colorScheme.background) {
                detailSections.forEachIndexed { index, section ->
                    Tab(
                        selected = state.detailTab == index,
                        onClick = { model.selectDetailTab(index) },
                        selectedContentColor = NauclioAegean,
                        unselectedContentColor = NauclioMuted,
                        text = {
                            DetailTabLabel(
                                section.label,
                                count = when (section) {
                                    DetailSection.CONVERSATION -> 0
                                    DetailSection.COMMENTS -> commentCount
                                    DetailSection.SUBAGENTS -> activeSubagents
                                },
                                selected = state.detailTab == index,
                            )
                        },
                    )
                }
            }
            HorizontalPager(
                state = detailPagerState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                beyondViewportPageCount = 1,
            ) { page ->
                when (detailSections[page]) {
                    DetailSection.CONVERSATION -> ConversationBody(state, model, Modifier.fillMaxSize())
                    DetailSection.COMMENTS -> CommentsBody(state, model, Modifier.fillMaxSize())
                    DetailSection.SUBAGENTS -> SubagentsBody(state, model, Modifier.fillMaxSize())
                }
            }
        } else {
            HorizontalDivider(color = NauclioOutline.copy(alpha = 0.52f))
            ConversationBody(state, model, Modifier.weight(1f).fillMaxWidth())
        }
    }
    if (renameOpen) {
        TextInputDialog("Rename conversation", "Title", card.title, { renameOpen = false }) { title ->
            renameOpen = false
            model.renameSelected(title)
        }
    }
    if (labelsOpen) {
        CardLabelsDialog(state, onDismiss = { labelsOpen = false }) { labelIds ->
            labelsOpen = false
            model.setSelectedCardLabels(labelIds)
        }
    }
}

internal enum class DetailSection(val label: String) {
    CONVERSATION("Conversation"),
    COMMENTS("Comments"),
    SUBAGENTS("Subagents"),
}

internal fun detailSectionsFor(standalone: Boolean): List<DetailSection> = if (standalone) {
    listOf(DetailSection.CONVERSATION, DetailSection.SUBAGENTS, DetailSection.COMMENTS)
} else {
    listOf(DetailSection.CONVERSATION, DetailSection.COMMENTS, DetailSection.SUBAGENTS)
}

@Composable
private fun DetailTabLabel(label: String, count: Int = 0, selected: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
        if (count > 0) {
            Surface(
                color = if (selected) NauclioAegean.copy(alpha = 0.18f) else NauclioSurfaceHigh,
                shape = CircleShape,
            ) {
                Text(
                    count.toString(),
                    color = if (selected) NauclioAegean else NauclioMuted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
                )
            }
        } else if (label == "Comments") {
            Text("0", color = NauclioMuted, fontSize = 12.sp)
        }
    }
}

@Composable
private fun SubagentsBody(state: NauclioUiState, model: NauclioViewModel, modifier: Modifier = Modifier) {
    val subagents = state.conversation?.conversation?.subagentsList.orEmpty()
    val active = subagents.count { it.status == "running" || it.status == "pending" }
    var text by remember(state.selectedCardId) { mutableStateOf("") }
    Column(modifier) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("${subagents.size} ${plural(subagents.size, "subagent")}", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            if (active > 0) {
                Spacer(Modifier.width(8.dp))
                Text("● $active running", color = Color(0xFF56C7FF), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.weight(1f))
            if (active > 0) {
                OutlinedButton(onClick = model::cancelSelected, enabled = !state.working) {
                    Text("■  Stop all", color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
                }
            }
        }
        if (subagents.isEmpty()) {
            EmptyList(
                "No subagents yet",
                "Delegated work from this conversation appears here live.",
                Icons.Outlined.AccountTree,
                Modifier.weight(1f),
            )
        } else {
            LazyColumn(
                Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(subagents, key = { it.id }) { subagent ->
                    SubagentStatusCard(subagent)
                }
                item {
                    Text(
                        "Polling continues in the background while connected",
                        color = NauclioMuted,
                        fontSize = 11.sp,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        MessageComposer(
            value = text,
            placeholder = "Message the local agent…",
            enabled = !state.working,
            harnesses = state.harnesses,
            card = state.selectedCard,
            contextUsage = latestContextUsage(state.conversationMessages),
            onValueChange = { text = it },
            onSend = { provider, selectedModel, effort ->
                val message = text.trim()
                if (message.isNotBlank()) {
                    text = ""
                    model.sendMessage(message, emptyList(), provider, selectedModel, effort)
                }
            },
        )
    }
}

@Composable
private fun SubagentStatusCard(subagent: Subagent) {
    val running = subagent.status == "running" || subagent.status == "pending"
    val completed = subagent.status == "completed"
    val title = subagentDisplayTitle(subagent)
    val elapsed = subagentElapsed(subagent)
    val tint = when {
        running -> Color(0xFF56C7FF)
        completed -> NauclioSeafoam
        else -> MaterialTheme.colorScheme.error
    }
    Surface(
        color = NauclioSurfaceHigh,
        shape = RoundedCornerShape(15.dp),
        border = if (running) androidx.compose.foundation.BorderStroke(1.dp, tint.copy(alpha = 0.55f)) else null,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().padding(start = 13.dp, end = 13.dp, top = 12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                if (running) CircularProgressIndicator(Modifier.size(17.dp), strokeWidth = 2.dp, color = tint)
                else Icon(
                    if (completed) Icons.Outlined.CheckCircle else Icons.Outlined.Cancel,
                    null,
                    tint = tint,
                    modifier = Modifier.size(17.dp),
                )
                Spacer(Modifier.width(9.dp))
                Text(
                    title,
                    Modifier.weight(1f),
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (elapsed.isNotBlank()) {
                    Text(elapsed, color = if (running) tint else NauclioMuted, fontSize = 10.sp)
                }
            }
            val activity = subagent.activity.ifBlank {
                subagent.currentTool.ifBlank { subagent.description.ifBlank { subagent.assignment } }
            }
            if (activity.isNotBlank() && cleanSubagentTitle(activity) != title) {
                Text(
                    activity,
                    color = NauclioMuted,
                    fontSize = 11.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 13.dp, vertical = 8.dp),
                )
            }
            if (running) {
                LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 13.dp).height(3.dp),
                    color = tint,
                    trackColor = NauclioOutline,
                )
            }
            HorizontalDivider(color = NauclioOutline.copy(alpha = 0.52f), modifier = Modifier.padding(top = 10.dp))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 13.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    subagentAgentLabel(subagent.name, subagent.agentType),
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 10.sp,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    listOf(subagent.provider, subagent.model).filter(String::isNotBlank).joinToString("/").ifBlank { "local" },
                    color = NauclioMuted,
                    fontSize = 10.sp,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(subagent.status.ifBlank { "pending" }, color = tint, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

private val subagentSuffixPattern = Regex("""\s*\((agent\s+\d+)\)\s*$""", RegexOption.IGNORE_CASE)

internal fun cleanSubagentTitle(value: String): String =
    value.replace(subagentSuffixPattern, "").trim().ifBlank { "Subagent" }

internal fun subagentDisplayTitle(subagent: Subagent): String = cleanSubagentTitle(
    subagent.name.ifBlank {
        subagent.assignment.ifBlank { subagent.task.ifBlank { subagent.agentType.ifBlank { "Subagent" } } }
    },
)

internal fun subagentAgentLabel(name: String, fallback: String): String =
    subagentSuffixPattern.find(name)?.groupValues?.getOrNull(1)?.lowercase()
        ?: fallback.ifBlank { "agent" }

private fun subagentElapsed(subagent: Subagent): String {
    val durationMs = subagent.durationMs.takeIf { it > 0 } ?: runCatching {
        val start = Instant.parse(subagent.startedAt)
        val end = subagent.endedAt.takeIf(String::isNotBlank)?.let(Instant::parse) ?: Instant.now()
        Duration.between(start, end).toMillis()
    }.getOrDefault(0L)
    val seconds = (durationMs / 1_000).coerceAtLeast(0)
    if (seconds <= 0L) return ""
    return if (seconds < 60) "${seconds}s" else "${seconds / 60}m ${seconds % 60}s"
}

@Composable
private fun ConversationBody(state: NauclioUiState, model: NauclioViewModel, modifier: Modifier = Modifier) {
    val allMessages = state.conversationMessages
    val listState = remember(state.selectedCardId) { LazyListState() }
    var initialScrollComplete by remember(state.selectedCardId) { mutableStateOf(false) }
    var followingLatest by remember(state.selectedCardId) { mutableStateOf(true) }
    var text by remember { mutableStateOf("") }
    var composerError by remember { mutableStateOf<String?>(null) }
    var awaitingAgent by remember(state.selectedCardId) { mutableStateOf(false) }
    var assistantCountAtSend by remember(state.selectedCardId) { mutableStateOf(0) }
    var observedActiveTurn by remember(state.selectedCardId) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val attachments = remember(state.selectedCardId) { mutableStateListOf<MessagePart>() }
    var attachmentPickerVisible by remember(state.selectedCardId) { mutableStateOf(false) }
    val conversation = state.conversation?.conversation
    val queuedMessages = conversation?.queueList.orEmpty()
    val card = state.conversation?.detail?.card ?: state.selectedCard
    val unsentTask = card?.unsentTaskText()
    val draftAttachments = conversation?.draftAttachmentsList.orEmpty()
    val hasUnsentDraft = card?.initialPromptSentAt?.isBlank() == true &&
        (unsentTask != null || draftAttachments.isNotEmpty())
    val plansByMessage = conversation?.taskPlansList.orEmpty()
        .groupBy(TaskPlan::getMessageId)
        .mapValues { (_, plans) -> plans.maxBy(TaskPlan::getRevision) }
    val subagentsByMessage = conversation?.subagentsList.orEmpty().groupBy(Subagent::getMessageId)
    val messages = allMessages.filter { message ->
        message.hasRenderableConversationContent(
            taskPlan = plansByMessage[message.id],
            subagents = subagentsByMessage[message.id].orEmpty(),
            includeReasoning = state.showReasoningTraces,
        )
    }
    val runtime = card?.runtime.orEmpty().ifBlank { conversation?.status.orEmpty() }.lowercase()
    val activeTurn = runtime in setOf("running", "starting", "working", "streaming")
    val assistantCount = messages.count { it.role.equals("assistant", true) || it.role.equals("agent", true) }
    val latestMessage = allMessages.lastOrNull()
    val latestPlan = latestMessage?.let { plansByMessage[it.id] }
    val latestSubagents = latestMessage?.let { subagentsByMessage[it.id] }.orEmpty()
    val latestIsRenderableAssistant = latestMessage != null &&
        (latestMessage.role.equals("assistant", true) || latestMessage.role.equals("agent", true)) &&
        latestMessage.hasRenderableConversationContent(latestPlan, latestSubagents, state.showReasoningTraces)
    val showAgentWorking = (activeTurn || awaitingAgent) && !latestIsRenderableAssistant
    fun addPickedAttachments(uris: List<android.net.Uri>, imagesOnly: Boolean) {
        if (uris.isEmpty()) return
        scope.launch {
            composerError = null
            val results = withContext(Dispatchers.IO) {
                uris.map { uri -> runCatching { readAttachmentPart(context, uri, imagesOnly) } }
            }
            val incoming = results.mapNotNull(Result<MessagePart>::getOrNull)
            val limitError = attachmentLimitError(attachments, incoming)
            if (limitError == null) attachments += incoming
            composerError = limitError ?: results.firstNotNullOfOrNull { result ->
                result.exceptionOrNull()?.message
            }
        }
    }
    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(MAX_COMPOSER_ATTACHMENTS),
    ) { uris -> addPickedAttachments(uris, imagesOnly = true) }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris -> addPickedAttachments(uris, imagesOnly = false) }
    LaunchedEffect(activeTurn, assistantCount, state.error) {
        if (activeTurn) observedActiveTurn = true
        if (state.error != null || assistantCount > assistantCountAtSend || (observedActiveTurn && !activeTurn)) {
            awaitingAgent = false
        }
    }
    var consumedScrollRequest by remember(state.selectedCardId) { mutableStateOf(Long.MIN_VALUE) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collect { scrolling ->
                if (scrolling) {
                    followingLatest = false
                } else if (initialScrollComplete) {
                    followingLatest = listState.isAtConversationEnd()
                }
            }
    }
    LaunchedEffect(
        state.conversationScrollRequest,
        messages.size,
        messages.lastOrNull()?.hashCode(),
        unsentTask,
        draftAttachments.hashCode(),
        showAgentWorking,
        queuedMessages.size,
        queuedMessages.lastOrNull()?.id,
    ) {
        val historyItems = if (state.historyHasMore || state.historyLoading) 1 else 0
        val unsentTaskItems = if (hasUnsentDraft) 1 else 0
        val endIndex = historyItems + unsentTaskItems + messages.size +
            (if (showAgentWorking) 1 else 0) + queuedMessages.size
        val explicitOpenScroll = consumedScrollRequest != state.conversationScrollRequest
        if ((hasUnsentDraft || messages.isNotEmpty() || showAgentWorking || queuedMessages.isNotEmpty()) &&
            shouldFollowConversationUpdate(explicitOpenScroll, initialScrollComplete, followingLatest)
        ) {
            listState.scrollToItem(endIndex)
            consumedScrollRequest = state.conversationScrollRequest
            initialScrollComplete = true
            followingLatest = true
        }
    }
    Column(modifier) {
        if (!hasUnsentDraft && messages.isEmpty() && !showAgentWorking && queuedMessages.isEmpty()) {
            if (state.conversation == null) LoadingState(Modifier.weight(1f))
            else EmptyList("Conversation is ready", "Send a message to resume the same durable harness session.", Icons.Outlined.ChatBubbleOutline, Modifier.weight(1f))
        } else {
            Box(Modifier.weight(1f)) {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize().alpha(if (initialScrollComplete) 1f else 0f),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (state.historyHasMore || state.historyLoading) {
                        item(key = "history") {
                            OutlinedButton(
                                onClick = model::loadOlderMessages,
                                enabled = !state.historyLoading,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                if (state.historyLoading) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                else Text("Load earlier messages · ${allMessages.size} of ${state.historyTotal}")
                            }
                        }
                    }
                    if (hasUnsentDraft) {
                        item(key = "unsent-agent-task") {
                            UnsentTaskMessage(unsentTask.orEmpty(), draftAttachments)
                        }
                    }
                    itemsIndexed(messages, key = { index, message -> "${message.id}:$index" }) { _, message ->
                        val plan = plansByMessage[message.id]
                        val subagents = subagentsByMessage[message.id].orEmpty()
                        MessageBlock(
                            message,
                            model,
                            showAgentAvatar = card?.scope == "chat",
                            showReasoningTraces = state.showReasoningTraces,
                            plan = plan,
                            subagents = subagents,
                        )
                    }
                    if (showAgentWorking) {
                        item(key = "agent-working") {
                            AgentWorkingIndicator(conversation?.pendingToolsList?.lastOrNull()?.toolName.orEmpty())
                        }
                    }
                    items(queuedMessages, key = { "queued-${it.id}" }) { queued ->
                        QueuedMessageBlock(
                            queued = queued,
                            showInterrupt = queued.id == queuedMessages.lastOrNull()?.id && activeTurn,
                            working = state.working,
                            onInterrupt = model::cancelSelected,
                        )
                    }
                    item(key = "conversation-end") { Spacer(Modifier.height(1.dp)) }
                }
                if (initialScrollComplete && !followingLatest && listState.canScrollForward) {
                    FilledTonalButton(
                        onClick = {
                            scope.launch {
                                val endIndex = listState.layoutInfo.totalItemsCount - 1
                                if (endIndex >= 0) listState.scrollToItem(endIndex)
                                followingLatest = true
                            }
                        },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 12.dp)
                            .height(36.dp)
                            .testTag("jump-to-latest"),
                        shape = CircleShape,
                        colors = ButtonDefaults.filledTonalButtonColors(
                            containerColor = NauclioSurfaceHigh,
                            contentColor = MaterialTheme.colorScheme.onSurface,
                        ),
                        contentPadding = PaddingValues(horizontal = 13.dp),
                    ) {
                        Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Jump to latest", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        if (state.selectedCard?.lane?.contains("review", ignoreCase = true) == true) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(16.dp)).background(Color(0xFF3A2906)).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Schedule, null, tint = NauclioAmber)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("Ready for review", fontWeight = FontWeight.SemiBold, color = NauclioAmber)
                    Text("Send feedback or mark it done.", fontSize = 12.sp, color = NauclioMuted)
                }
                Button(
                    onClick = model::markDone,
                    colors = ButtonDefaults.buttonColors(containerColor = NauclioAmber, contentColor = Color(0xFF071426)),
                ) { Text("Mark done") }
            }
        }
        if (card?.canStartFromTodo(draftAttachments.isNotEmpty()) == true) {
            StartCardBanner(
                working = state.working,
                onStart = model::startSelectedCard,
            )
        }
        MessageComposer(
            value = text,
            placeholder = "Message the local agent…",
            enabled = !state.working,
            harnesses = state.harnesses,
            card = state.selectedCard,
            contextUsage = latestContextUsage(allMessages),
            attachments = attachments,
            error = composerError,
            onValueChange = { text = it },
            onAttach = { attachmentPickerVisible = true },
            onRemoveAttachment = { attachments.removeAt(it) },
            onSend = { provider, selectedModel, effort ->
                val message = text.trim()
                if (message.isNotBlank() || attachments.isNotEmpty()) {
                    assistantCountAtSend = assistantCount
                    observedActiveTurn = false
                    awaitingAgent = true
                    val parts = attachments.toList()
                    model.sendMessage(message, parts, provider, selectedModel, effort) {
                        if (text.trim() == message) text = ""
                        if (attachments.toList() == parts) attachments.clear()
                    }
                }
            },
        )
    }
    if (attachmentPickerVisible) {
        AttachmentPickerSheet(
            onDismiss = { attachmentPickerVisible = false },
            onImages = {
                attachmentPickerVisible = false
                imagePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            onFiles = {
                attachmentPickerVisible = false
                filePicker.launch(arrayOf("*/*"))
            },
        )
    }
}

@Composable
internal fun QueuedMessageBlock(
    queued: QueuedMessage,
    showInterrupt: Boolean,
    working: Boolean,
    onInterrupt: () -> Unit,
) {
    val parts = queued.partsList.ifEmpty {
        listOf(MessagePart.newBuilder().setType("text").setText(queued.text).build())
    }
    Column(
        Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Surface(
            color = NauclioSurfaceHigh.copy(alpha = 0.72f),
            contentColor = NauclioMuted,
            shape = RoundedCornerShape(17.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
            modifier = Modifier.widthIn(max = 340.dp).testTag("queued-message-${queued.id}"),
        ) {
            Column(Modifier.padding(horizontal = 13.dp, vertical = 8.dp)) {
                parts.forEach { part ->
                    when {
                        part.type == "text" && part.text.isNotBlank() -> SelectionContainer {
                            MessageMarkdown(part.text, compact = true)
                        }
                        part.type == "file" -> AttachmentPart(part)
                        part.text.isNotBlank() -> MessageMarkdown(part.text, compact = true)
                    }
                }
            }
        }
        if (showInterrupt) {
            TextButton(
                onClick = onInterrupt,
                enabled = !working,
                modifier = Modifier.testTag("interrupt-queued-message"),
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) {
                if (working) {
                    CircularProgressIndicator(Modifier.size(15.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Outlined.Cancel, null, Modifier.size(17.dp))
                }
                Spacer(Modifier.width(6.dp))
                Text(if (working) "Interrupting…" else "Interrupt")
            }
        }
    }
}

@Composable
private fun UnsentTaskMessage(task: String, attachments: List<MessagePart> = emptyList()) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Surface(
            color = NauclioSurfaceHigh.copy(alpha = 0.72f),
            contentColor = NauclioMuted,
            shape = RoundedCornerShape(17.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
            modifier = Modifier.widthIn(max = 340.dp).testTag("unsent-agent-task"),
        ) {
            Column(
                Modifier.padding(horizontal = 13.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Schedule, null, Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("NOT SENT", fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)
                }
                if (task.isNotBlank()) SelectionContainer { MessageMarkdown(task, compact = true) }
                attachments.forEach { part -> AttachmentPart(part) }
            }
        }
    }
}

@Composable
private fun StartCardBanner(working: Boolean, onStart: () -> Unit) {
    Surface(
        color = NauclioAegean.copy(alpha = 0.12f),
        shape = RoundedCornerShape(16.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, NauclioAegean.copy(alpha = 0.34f)),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text("Ready to start", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    "Run the saved task and move this card to Running.",
                    color = NauclioMuted,
                    fontSize = 12.sp,
                    lineHeight = 17.sp,
                )
            }
            Button(
                onClick = onStart,
                enabled = !working,
                modifier = Modifier.testTag("start-card"),
                colors = ButtonDefaults.buttonColors(
                    containerColor = NauclioAegean,
                    contentColor = Color(0xFF071426),
                ),
            ) {
                if (working) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Default.PlayArrow, null, Modifier.size(18.dp))
                }
                Spacer(Modifier.width(6.dp))
                Text("Start card")
            }
        }
    }
}

private fun LazyListState.isAtConversationEnd(): Boolean {
    val layout = layoutInfo
    if (layout.totalItemsCount == 0) return true
    return layout.visibleItemsInfo.lastOrNull()?.index == layout.totalItemsCount - 1
}

@Composable
private fun MessageBlock(
    message: UiMessage,
    model: NauclioViewModel,
    showAgentAvatar: Boolean,
    showReasoningTraces: Boolean,
    plan: TaskPlan? = null,
    subagents: List<Subagent> = emptyList(),
) {
    val fromUser = message.role.equals("user", true) || message.role.equals("human", true)
    val pendingAlpha = if (model.isPendingMessage(message.id)) 0.52f else 1f
    if (fromUser) {
        Row(Modifier.fillMaxWidth().alpha(pendingAlpha), horizontalArrangement = Arrangement.End) {
            Surface(
                color = NauclioCobalt,
                contentColor = Color.White,
                shape = RoundedCornerShape(17.dp),
                modifier = Modifier.widthIn(max = 340.dp),
            ) {
                Box {
                    Column(Modifier.padding(start = 13.dp, top = 8.dp, end = 18.dp, bottom = 8.dp)) {
                        MessageParts(
                            message,
                            model,
                            compact = true,
                            showReasoningTraces = showReasoningTraces,
                            plan = plan,
                            subagents = subagents,
                        )
                    }
                    MessageDeliveryReceipt(
                        messageDeliveryState(
                            pending = model.isPendingMessage(message.id),
                            accepted = model.isAcceptedOutboxItem(message.id),
                            failed = model.isFailedOutboxItem(message.id),
                        ),
                        Modifier.align(Alignment.BottomEnd).offset(x = (-4).dp, y = (-4).dp),
                    )
                }
            }
        }
    } else if (showAgentAvatar) {
        Row(Modifier.fillMaxWidth().alpha(pendingAlpha), verticalAlignment = Alignment.Top) {
            AgentAvatar()
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                MessageParts(message, model, showReasoningTraces = showReasoningTraces, plan = plan, subagents = subagents)
            }
        }
    } else {
        Column(Modifier.fillMaxWidth().alpha(pendingAlpha)) {
            MessageParts(message, model, showReasoningTraces = showReasoningTraces, plan = plan, subagents = subagents)
        }
    }
}

enum class MessageDeliveryState { LOCAL, ACCEPTED, SYNCED, FAILED }

fun messageDeliveryState(pending: Boolean, accepted: Boolean, failed: Boolean): MessageDeliveryState = when {
    failed -> MessageDeliveryState.FAILED
    !pending -> MessageDeliveryState.SYNCED
    accepted -> MessageDeliveryState.ACCEPTED
    else -> MessageDeliveryState.LOCAL
}

@Composable
private fun MessageDeliveryReceipt(state: MessageDeliveryState, modifier: Modifier = Modifier) {
    val tint = if (state == MessageDeliveryState.FAILED) MaterialTheme.colorScheme.error else Color.White.copy(alpha = 0.72f)
    val description = when (state) {
        MessageDeliveryState.LOCAL -> "Waiting to send"
        MessageDeliveryState.ACCEPTED -> "Accepted by daemon"
        MessageDeliveryState.SYNCED -> "Synced"
        MessageDeliveryState.FAILED -> "Send failed; retrying"
    }
    Box(modifier.width(14.dp).height(10.dp)) {
        when (state) {
            MessageDeliveryState.LOCAL -> Icon(Icons.Outlined.Schedule, description, tint = tint, modifier = Modifier.size(10.dp))
            MessageDeliveryState.ACCEPTED -> Icon(Icons.Default.Check, description, tint = tint, modifier = Modifier.size(11.dp))
            MessageDeliveryState.SYNCED -> {
                Icon(Icons.Default.Check, description, tint = tint, modifier = Modifier.offset(x = (-1).dp).size(11.dp))
                Icon(Icons.Default.Check, null, tint = tint, modifier = Modifier.offset(x = 3.dp).size(11.dp))
            }
            MessageDeliveryState.FAILED -> Text("!", color = tint, fontSize = 10.sp)
        }
    }
}

@Composable
private fun MessageParts(
    message: UiMessage,
    model: NauclioViewModel,
    compact: Boolean = false,
    showReasoningTraces: Boolean,
    plan: TaskPlan? = null,
    subagents: List<Subagent> = emptyList(),
) {
    val timeline = buildConversationTimeline(
        parts = message.partsList,
        subagents = subagents,
        hasTaskPlan = plan != null,
        showReasoning = showReasoningTraces,
    )
    if (plan != null) TaskPlanBlock(plan)
    timeline.forEachIndexed { index, item ->
        when (item) {
            is ConversationTimelineItem.Tools -> ToolGroup(
                messageId = message.id,
                groupKey = item.parts.firstOrNull()?.toolCallId.orEmpty().ifBlank { index.toString() },
                parts = item.parts,
                model = model,
            )
            ConversationTimelineItem.Subagents -> SubagentBlock(subagents)
            is ConversationTimelineItem.Part -> when (
                item.part.conversationPartPresentation(showReasoningTraces)
            ) {
                ConversationPartPresentation.TEXT -> SelectionContainer {
                    MessageMarkdown(item.part.text, compact)
                }
                ConversationPartPresentation.REASONING -> ReasoningPart(item.part.text)
                ConversationPartPresentation.FILE -> AttachmentPart(item.part)
                ConversationPartPresentation.FALLBACK_TEXT -> MessageMarkdown(item.part.text, compact)
                ConversationPartPresentation.TOOL,
                ConversationPartPresentation.HIDDEN -> Unit
            }
        }
    }
}

internal data class MessageMarkdownBlock(
    val text: String,
    val code: Boolean = false,
    val headingLevel: Int = 0,
)

internal fun parseMessageMarkdown(value: String): List<MessageMarkdownBlock> {
    val blocks = mutableListOf<MessageMarkdownBlock>()
    val pending = mutableListOf<String>()
    var inCode = false

    fun flush() {
        if (pending.isEmpty()) return
        val raw = pending.joinToString("\n").trimEnd()
        pending.clear()
        if (raw.isBlank()) return
        val heading = if (!inCode) raw.takeWhile { it == '#' }.length.takeIf { it in 1..4 } ?: 0 else 0
        val text = if (heading > 0 && raw.getOrNull(heading) == ' ') raw.drop(heading + 1) else raw
        blocks += MessageMarkdownBlock(text = text, code = inCode, headingLevel = heading)
    }

    value.lineSequence().forEach { line ->
        if (line.trimStart().startsWith("```")) {
            flush()
            inCode = !inCode
        } else if (!inCode && line.isBlank()) {
            flush()
        } else if (!inCode && line.trimStart().matches(Regex("^[-*]\\s+.*"))) {
            flush()
            blocks += MessageMarkdownBlock("• " + line.trimStart().drop(2))
        } else {
            pending += line
        }
    }
    flush()
    return blocks
}

@Composable
private fun MessageMarkdown(value: String, compact: Boolean) {
    val blocks = remember(value) { parseMessageMarkdown(value) }
    Column(verticalArrangement = Arrangement.spacedBy(if (compact) 2.dp else 7.dp)) {
        blocks.forEach { block ->
            if (block.code) {
                Surface(color = NauclioSurfaceHigh, shape = RoundedCornerShape(9.dp), modifier = Modifier.fillMaxWidth()) {
                    Text(
                        block.text,
                        color = NauclioMuted,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        lineHeight = 17.sp,
                        modifier = Modifier.padding(horizontal = 11.dp, vertical = 9.dp),
                    )
                }
            } else {
                Text(
                    markdownInlineText(block.text),
                    fontSize = if (block.headingLevel > 0) 15.sp else 14.sp,
                    fontWeight = if (block.headingLevel > 0) FontWeight.SemiBold else FontWeight.Normal,
                    lineHeight = if (compact) 20.sp else 21.sp,
                )
            }
        }
    }
}

private val inlineMarkdownPattern = Regex("(\\*\\*([^*]+)\\*\\*|`([^`]+)`|\\[([^]]+)]\\(([^)]+)\\))")

internal fun markdownInlineText(value: String): AnnotatedString = buildAnnotatedString {
    var cursor = 0
    inlineMarkdownPattern.findAll(value).forEach { match ->
        append(value.substring(cursor, match.range.first))
        when {
            match.groupValues[2].isNotEmpty() -> pushStyle(SpanStyle(fontWeight = FontWeight.SemiBold))
            match.groupValues[3].isNotEmpty() -> pushStyle(
                SpanStyle(color = NauclioAegean, background = NauclioSurfaceHigh, fontFamily = FontFamily.Monospace),
            )
            else -> pushStyle(SpanStyle(color = NauclioAegean, textDecoration = TextDecoration.Underline))
        }
        append(match.groupValues[2].ifEmpty { match.groupValues[3].ifEmpty { match.groupValues[4] } })
        pop()
        cursor = match.range.last + 1
    }
    append(value.substring(cursor))
}

@Composable
private fun TaskPlanBlock(plan: TaskPlan) {
    val tasks = plan.phasesList.flatMap { it.tasksList }
    val active = plan.state == "active" && tasks.any { it.status == "in_progress" }
    var expanded by remember(plan.id, plan.revision) { mutableStateOf(active) }
    val completed = tasks.count { it.status == "completed" || it.status == "abandoned" }
    Surface(
        shape = RoundedCornerShape(9.dp),
        color = NauclioSurfaceHigh,
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)
            .border(1.dp, NauclioOutline.copy(alpha = 0.55f), RoundedCornerShape(9.dp)),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(horizontal = 9.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.ChevronRight, null, tint = NauclioMuted, modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f))
                Spacer(Modifier.width(6.dp))
                if (active) CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 1.5.dp, color = NauclioAegean)
                else Icon(Icons.Outlined.CheckCircle, null, tint = NauclioSeafoam, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(7.dp))
                Text("Task progress", Modifier.weight(1f), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                Text("$completed/${tasks.size}", color = NauclioMuted, fontSize = 10.sp)
            }
            if (expanded) {
                Column(Modifier.padding(start = 31.dp, end = 9.dp, bottom = 9.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (plan.explanation.isNotBlank()) Text(plan.explanation, color = NauclioMuted, fontSize = 10.sp, lineHeight = 14.sp)
                    plan.phasesList.forEach { phase ->
                        if (phase.name.isNotBlank()) Text(phase.name.uppercase(), color = NauclioMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
                        phase.tasksList.forEach { task ->
                            Row(verticalAlignment = Alignment.Top) {
                                when (task.status) {
                                    "in_progress" -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = NauclioAegean)
                                    "completed" -> Icon(Icons.Filled.Check, null, tint = NauclioSeafoam, modifier = Modifier.size(13.dp))
                                    "blocked" -> Icon(Icons.Outlined.Cancel, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(13.dp))
                                    else -> Icon(Icons.Outlined.Schedule, null, tint = NauclioMuted, modifier = Modifier.size(13.dp))
                                }
                                Spacer(Modifier.width(7.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        if (task.status == "in_progress" && task.activeForm.isNotBlank()) task.activeForm else task.content,
                                        color = if (task.status == "completed" || task.status == "abandoned") NauclioMuted else MaterialTheme.colorScheme.onSurface,
                                        fontSize = 10.sp,
                                        lineHeight = 14.sp,
                                    )
                                    if (task.blocker.isNotBlank()) Text(task.blocker, color = MaterialTheme.colorScheme.error, fontSize = 9.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SubagentBlock(subagents: List<Subagent>) {
    val active = subagents.any { it.status == "running" || it.status == "pending" }
    var expanded by remember(subagents.map { "${it.id}:${it.status}" }) { mutableStateOf(active) }
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Row(
            Modifier.clip(RoundedCornerShape(7.dp)).clickable { expanded = !expanded }.padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.ChevronRight, null, tint = NauclioMuted, modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f))
            Spacer(Modifier.width(5.dp))
            Text("${subagents.size} ${if (subagents.size == 1) "subagent" else "subagents"}", color = NauclioMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            if (active) {
                Spacer(Modifier.width(7.dp))
                CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.4.dp, color = NauclioAegean)
                Spacer(Modifier.width(4.dp))
                Text("Working", color = NauclioAegean, fontSize = 9.sp)
            }
        }
        if (expanded) {
            Column(Modifier.padding(start = 20.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                subagents.forEach { subagent ->
                    Surface(shape = RoundedCornerShape(8.dp), color = NauclioSurfaceHigh, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(horizontal = 9.dp, vertical = 7.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (subagent.status == "running") CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.4.dp, color = NauclioAegean)
                                else Icon(if (subagent.status == "completed") Icons.Outlined.CheckCircle else Icons.Outlined.Cancel, null, tint = if (subagent.status == "completed") NauclioSeafoam else NauclioMuted, modifier = Modifier.size(12.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    cleanSubagentTitle(subagent.task.ifBlank { subagent.name.ifBlank { subagent.agentType } }),
                                    Modifier.weight(1f),
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(subagent.status, color = NauclioMuted, fontSize = 8.sp)
                            }
                            val activity = subagent.activity.ifBlank { subagent.description }
                            if (activity.isNotBlank()) Text(activity, color = NauclioMuted, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            val metrics = listOfNotNull(
                                subagent.model.takeIf(String::isNotBlank),
                                subagent.toolCount.takeIf { it > 0 }?.let { "$it tools" },
                                subagent.tokens.takeIf { it > 0 }?.let { "$it tokens" },
                                if (subagent.contextTokens > 0 && subagent.contextWindow > 0) "${(subagent.contextTokens * 100 / subagent.contextWindow)}% context" else null,
                            )
                            if (metrics.isNotEmpty()) Text(metrics.joinToString(" · "), color = NauclioMuted, fontSize = 8.sp)
                            if (subagent.error.isNotBlank()) Text(subagent.error, color = MaterialTheme.colorScheme.error, fontSize = 9.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ReasoningPart(text: String) {
    if (text.isBlank()) return
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable { expanded = !expanded }
                .padding(horizontal = 4.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = NauclioMuted,
                modifier = Modifier.size(14.dp).rotate(if (expanded) 90f else 0f),
            )
            Spacer(Modifier.width(5.dp))
            Text("Reasoning", color = NauclioMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            if (!expanded) {
                Spacer(Modifier.width(6.dp))
                Text(
                    text.lineSequence().firstOrNull { it.isNotBlank() }.orEmpty().replace("**", ""),
                    color = NauclioMuted.copy(alpha = 0.72f),
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (expanded) {
            SelectionContainer {
                Text(
                    text,
                    modifier = Modifier.padding(start = 23.dp, top = 3.dp, bottom = 5.dp),
                    color = NauclioMuted,
                    fontSize = 12.sp,
                    lineHeight = 18.sp,
                )
            }
        }
    }
}

@Composable
private fun AgentAvatar() {
    Surface(
        color = NauclioSurfaceHigh,
        contentColor = NauclioAegean,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.size(32.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Row(
                Modifier.size(width = 17.dp, height = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Box(Modifier.width(3.dp).height(16.dp).clip(RoundedCornerShape(2.dp)).background(NauclioAegean))
                Box(Modifier.width(3.dp).height(11.dp).clip(RoundedCornerShape(2.dp)).background(NauclioAegean))
                Box(Modifier.width(3.dp).height(8.dp).clip(RoundedCornerShape(2.dp)).background(NauclioAegean))
                Box(Modifier.width(3.dp).height(5.dp).clip(RoundedCornerShape(2.dp)).background(NauclioAegean))
            }
        }
    }
}

@Composable
private fun AgentWorkingIndicator(toolName: String) {
    val transition = rememberInfiniteTransition(label = "agent-working")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 3f,
        animationSpec = infiniteRepeatable(tween(900, easing = LinearEasing)),
        label = "typing-phase",
    )
    Row(
        Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AgentAvatar()
        Spacer(Modifier.width(10.dp))
        Surface(color = NauclioSurfaceHigh, shape = RoundedCornerShape(17.dp)) {
            Row(
                Modifier.padding(horizontal = 11.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    if (toolName.isBlank()) "Working" else "Working · ${displayToolName(toolName)}",
                    color = NauclioMuted,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                repeat(3) { index ->
                    val active = phase.toInt().coerceIn(0, 2) == index
                    Box(
                        Modifier.size(if (active) 5.dp else 4.dp)
                            .clip(CircleShape)
                            .background(NauclioAegean.copy(alpha = if (active) 1f else 0.35f)),
                    )
                }
            }
        }
    }
}

@Composable
private fun AttachmentPart(part: MessagePart) {
    val bitmap = remember(part.url, part.data) { decodeAttachmentBitmap(part)?.asImageBitmap() }
    if (bitmap != null) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(
                bitmap = bitmap,
                contentDescription = part.filename.ifBlank { "Attached image" },
                contentScale = ContentScale.FillWidth,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)),
            )
            if (part.filename.isNotBlank()) {
                Text(
                    part.filename,
                    color = NauclioMuted,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        return
    }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = NauclioSurfaceHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
        modifier = Modifier.widthIn(max = 340.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(38.dp).clip(RoundedCornerShape(10.dp)).background(Color(0xFF12243C)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Description, null, tint = NauclioAegean, modifier = Modifier.size(19.dp))
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    part.filename.ifBlank { "Attachment" },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(attachmentDetails(part), color = NauclioMuted, fontSize = 10.sp, maxLines = 1)
            }
        }
    }
}

private data class ToolCategory(val key: String, val singular: String, val plural: String)

private fun toolCategory(part: MessagePart): ToolCategory {
    val name = part.toolName.ifBlank { part.type }.lowercase()
    return when {
        Regex("bash|shell|terminal|exec|command").containsMatchIn(name) -> ToolCategory("command", "command", "commands")
        Regex("apply.?patch|edit|replace").containsMatchIn(name) -> ToolCategory("edit", "edit", "edits")
        Regex("write|create.?file").containsMatchIn(name) -> ToolCategory("write", "write", "writes")
        Regex("read|view.?file").containsMatchIn(name) -> ToolCategory("read", "read", "reads")
        Regex("grep|glob|search|find").containsMatchIn(name) -> ToolCategory("search", "search", "searches")
        Regex("browser|navigate|click|screenshot").containsMatchIn(name) -> ToolCategory("browser", "browser action", "browser actions")
        else -> ToolCategory("tool", "tool call", "tool calls")
    }
}

private fun toolGroupLabel(parts: List<MessagePart>): String {
    val counts = linkedMapOf<String, Pair<ToolCategory, Int>>()
    parts.forEach { part ->
        val category = toolCategory(part)
        counts[category.key] = category to ((counts[category.key]?.second ?: 0) + 1)
    }
    return counts.values.joinToString(", ") { (category, count) ->
        "$count ${if (count == 1) category.singular else category.plural}"
    }
}

private fun displayToolName(name: String): String = name
    .removePrefix("tool-")
    .replace('_', ' ')
    .replace('-', ' ')
    .trim()
    .ifBlank { "Tool" }

private fun toolPreview(part: MessagePart): String {
    val value = part.inputPreview.ifBlank {
        part.inputJson.toString(StandardCharsets.UTF_8).trim().replace(Regex("\\s+"), " ")
    }.ifBlank { part.outputPreview }
    return if (value.length > 140) value.take(137) + "…" else value
}

@Composable
private fun ToolGroup(messageId: String, groupKey: String, parts: List<MessagePart>, model: NauclioViewModel) {
    if (parts.isEmpty()) return
    var expanded by remember(messageId, groupKey) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Row(
            Modifier.clip(RoundedCornerShape(6.dp)).clickable { expanded = !expanded }
                .padding(horizontal = 4.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = if (expanded) "Collapse tool activity" else "Expand tool activity",
                tint = NauclioMuted,
                modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f),
            )
            Spacer(Modifier.width(5.dp))
            Text(toolGroupLabel(parts), color = NauclioMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        }
        if (expanded) {
            Column(
                Modifier.fillMaxWidth().padding(start = 7.dp, top = 2.dp)
                    .drawBehind {
                        drawLine(
                            color = NauclioOutline,
                            start = Offset.Zero,
                            end = Offset(0f, size.height),
                            strokeWidth = 1.dp.toPx(),
                        )
                    }
                    .padding(start = 11.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                parts.forEach { part -> ToolItem(messageId, part, model) }
            }
        }
    }
}

@Composable
private fun ToolItem(messageId: String, part: MessagePart, model: NauclioViewModel) {
    var expanded by remember(part.toolCallId, part.payloadRevision) { mutableStateOf(false) }
    var payload by remember(part.toolCallId, part.payloadRevision) { mutableStateOf<ToolOutput?>(null) }
    var loading by remember(part.toolCallId, part.payloadRevision) { mutableStateOf(false) }
    var error by remember(part.toolCallId, part.payloadRevision) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val input = (payload?.inputJson ?: part.inputJson).toString(StandardCharsets.UTF_8).trim()
    val output = (payload?.outputJson ?: part.outputJson).toString(StandardCharsets.UTF_8).trim()
    fun toggle() {
        expanded = !expanded
        if (expanded && payload == null && !loading && (part.hasInput || part.hasOutput)) {
            loading = true
            scope.launch {
                runCatching { model.loadToolOutput(messageId, part) }
                    .onSuccess { payload = it; error = null }
                    .onFailure { error = it.message ?: "Could not load tool details" }
                loading = false
            }
        }
    }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(5.dp)).clickable { toggle() }
                .padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.Terminal, null, tint = NauclioMuted, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(6.dp))
            Text(
                displayToolName(part.toolName.ifBlank { part.type }),
                color = NauclioMuted,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
            )
            val preview = toolPreview(part)
            if (preview.isNotBlank()) {
                Spacer(Modifier.width(7.dp))
                Text(
                    preview,
                    modifier = Modifier.weight(1f),
                    color = NauclioMuted.copy(alpha = 0.67f),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            } else Spacer(Modifier.weight(1f))
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = if (expanded) "Collapse details" else "Expand details",
                tint = NauclioMuted,
                modifier = Modifier.size(13.dp).rotate(if (expanded) 90f else 0f),
            )
        }
        if (expanded) {
            val payloadError = payload?.errorText.orEmpty().ifBlank { part.errorText }
            if (loading) {
                Row(
                    Modifier.padding(start = 25.dp, top = 5.dp, bottom = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(7.dp))
                    Text("Loading tool details…", color = NauclioMuted, fontSize = 10.sp)
                }
            }
            if (error != null) {
                Text(error.orEmpty(), Modifier.padding(start = 25.dp, bottom = 6.dp), color = MaterialTheme.colorScheme.error, fontSize = 10.sp)
            }
            if (payloadError.isNotBlank()) ToolPayloadBlock("Error", payloadError, error = true)
            if (input.isNotBlank()) ToolPayloadBlock("Input", input)
            if (output.isNotBlank()) ToolPayloadBlock("Output", output)
            if (!loading && error == null && payloadError.isBlank() && input.isBlank() && output.isBlank()) {
                Text("No additional payload", Modifier.padding(start = 25.dp, bottom = 6.dp), color = NauclioMuted, fontSize = 10.sp)
            }
        }
    }
}

@Composable
private fun ToolPayloadBlock(label: String, value: String, error: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(start = 25.dp, end = 6.dp, bottom = 6.dp)) {
        Text(label, color = if (error) MaterialTheme.colorScheme.error else NauclioMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(3.dp))
        Surface(
            color = MaterialTheme.colorScheme.background,
            shape = RoundedCornerShape(6.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
        ) {
            SelectionContainer {
                Text(
                    value,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp).verticalScroll(rememberScrollState())
                        .padding(horizontal = 8.dp, vertical = 7.dp),
                    color = if (error) MaterialTheme.colorScheme.error else NauclioMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    lineHeight = 13.sp,
                )
            }
        }
    }
}

@Composable
private fun CommentsBody(state: NauclioUiState, model: NauclioViewModel, modifier: Modifier = Modifier) {
    val comments = state.conversation?.detail?.commentsList.orEmpty()
    var text by remember { mutableStateOf("") }
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(comments.isNotEmpty()) {
        if (comments.isEmpty()) return@LaunchedEffect
        while (true) {
            delay(60_000)
            now = Instant.now()
        }
    }
    Column(modifier) {
        if (comments.isEmpty()) {
            EmptyList("No comments yet", "Comments are human notes and never wake the agent.", Icons.Outlined.ChatBubbleOutline, Modifier.weight(1f))
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(comments, key = { it.id }) { comment ->
                    Card(
                        colors = CardDefaults.cardColors(containerColor = NauclioSurfaceHigh),
                        shape = RoundedCornerShape(16.dp),
                    ) {
                        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 13.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Surface(shape = RoundedCornerShape(7.dp), color = Color(0xFF12243C)) {
                                    Text(
                                        if (state.selectedCard?.scope == "board") "BOARD COMMENT" else "CHAT NOTE",
                                        color = NauclioAegean,
                                        fontSize = 9.sp,
                                        fontWeight = FontWeight.Bold,
                                        letterSpacing = 0.7.sp,
                                        modifier = Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
                                    )
                                }
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    comment.author.name.ifBlank { "Human" },
                                    color = MaterialTheme.colorScheme.onSurface,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Spacer(Modifier.weight(1f))
                                Text(shortTimestamp(comment.createdAt, now), color = NauclioMuted, fontSize = 11.sp)
                            }
                            Spacer(Modifier.height(8.dp))
                            Text(comment.body, color = MaterialTheme.colorScheme.onSurface, fontSize = 14.sp, lineHeight = 20.sp)
                        }
                    }
                }
            }
        }
        MessageComposer(
            value = text,
            placeholder = "Add a comment…",
            enabled = !state.working,
            onValueChange = { text = it },
            onSend = { _, _, _ ->
                val message = text.trim()
                if (message.isNotBlank()) {
                    text = ""
                    model.addComment(message)
                }
            },
        )
    }
}

@Composable
internal fun AttachmentPickerSheet(
    onDismiss: () -> Unit,
    onImages: () -> Unit,
    onFiles: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = NauclioSurfaceHigh) {
        Column(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add attachment", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                "Choose images or browse any document on this device.",
                color = NauclioMuted,
                fontSize = 12.sp,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                AttachmentSourceCard(
                    title = "Images",
                    detail = "Photo library",
                    icon = Icons.Outlined.PhotoLibrary,
                    modifier = Modifier.weight(1f).testTag("attach-images"),
                    onClick = onImages,
                )
                AttachmentSourceCard(
                    title = "Files",
                    detail = "Browse device",
                    icon = Icons.Outlined.Description,
                    modifier = Modifier.weight(1f).testTag("attach-files"),
                    onClick = onFiles,
                )
            }
            Text(
                "Up to 4 attachments · 5 MB each · 6 MB total",
                color = NauclioMuted.copy(alpha = 0.78f),
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun AttachmentSourceCard(
    title: String,
    detail: String,
    icon: ImageVector,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        color = NauclioSurface,
        border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Box(
                Modifier.size(42.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF12243C)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = NauclioAegean, modifier = Modifier.size(21.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(detail, color = NauclioMuted, fontSize = 11.sp)
            }
        }
    }
}

@Composable
internal fun ComposerAttachmentPreview(
    part: MessagePart,
    index: Int,
    enabled: Boolean,
    onRemove: () -> Unit,
) {
    val bitmap = remember(part.url, part.data) { decodeAttachmentBitmap(part, maxDimension = 360)?.asImageBitmap() }
    if (bitmap != null) {
        Box(
            Modifier.width(116.dp).height(88.dp).clip(RoundedCornerShape(12.dp))
                .background(NauclioSurfaceHigh)
                .testTag("composer-attachment-$index"),
        ) {
            Image(
                bitmap = bitmap,
                contentDescription = part.filename.ifBlank { "Attached image" },
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            Text(
                part.filename.ifBlank { "Image" },
                color = Color.White,
                fontSize = 10.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.58f)).padding(horizontal = 7.dp, vertical = 5.dp),
            )
            IconButton(
                onClick = onRemove,
                enabled = enabled,
                modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(25.dp)
                    .clip(CircleShape).background(Color.Black.copy(alpha = 0.62f)),
            ) {
                Icon(Icons.Outlined.Close, "Remove ${part.filename.ifBlank { "image" }}", tint = Color.White, modifier = Modifier.size(14.dp))
            }
        }
        return
    }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = NauclioSurfaceHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline),
        modifier = Modifier.width(224.dp).height(64.dp).testTag("composer-attachment-$index"),
    ) {
        Row(
            Modifier.padding(start = 10.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(Color(0xFF12243C)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Description, null, tint = NauclioAegean, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    part.filename.ifBlank { "Attachment" },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(attachmentDetails(part), color = NauclioMuted, fontSize = 10.sp, maxLines = 1)
            }
            IconButton(onClick = onRemove, enabled = enabled, modifier = Modifier.size(36.dp)) {
                Icon(Icons.Outlined.Close, "Remove ${part.filename.ifBlank { "attachment" }}", Modifier.size(16.dp))
            }
        }
    }
}

@Composable
private fun MessageComposer(
    value: String,
    placeholder: String,
    enabled: Boolean,
    harnesses: List<Harness> = emptyList(),
    card: BoardCard? = null,
    contextUsage: ComposerContextUsage? = null,
    attachments: List<MessagePart> = emptyList(),
    error: String? = null,
    onValueChange: (String) -> Unit,
    onAttach: (() -> Unit)? = null,
    onRemoveAttachment: (Int) -> Unit = {},
    onSend: (String, String, String) -> Unit,
) {
    val locked = card?.initialPromptSentAt?.isNotBlank() == true
    var provider by remember(card?.id, harnesses) {
        mutableStateOf(card?.provider?.takeIf { it.isNotBlank() } ?: harnesses.firstOrNull()?.id.orEmpty())
    }
    val selectedHarness = harnesses.firstOrNull { it.id == provider } ?: harnesses.firstOrNull()
    var selectedModel by remember(card?.id, provider, selectedHarness) {
        mutableStateOf(card?.model?.takeIf { it.isNotBlank() } ?: selectedHarness?.defaultModel.orEmpty())
    }
    var effort by remember(card?.id, provider, selectedModel) { mutableStateOf(card?.effort.orEmpty()) }
    val selectedHarnessModel = selectedHarness?.modelsList?.firstOrNull { it.id == selectedModel }
    val effortOptions = selectedHarness?.effortOptionsFor(selectedModel).orEmpty()
    val displayedEffort = effort.ifBlank { selectedHarnessModel?.defaultEffort.orEmpty() }
    val effortLabel = effortOptions.firstOrNull { it.id == displayedEffort }?.name
        ?: displayedEffort.replaceFirstChar { if (it.isLowerCase()) it.uppercaseChar().toString() else it.toString() }
            .ifBlank { "Default" }
    var providerMenu by remember { mutableStateOf(false) }
    var modelMenu by remember { mutableStateOf(false) }
    var effortMenu by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (attachments.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                attachments.forEachIndexed { index, part ->
                    ComposerAttachmentPreview(
                        part = part,
                        index = index,
                        enabled = enabled,
                        onRemove = { onRemoveAttachment(index) },
                    )
                }
            }
        }
        if (error != null) Text(error, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
        if (harnesses.isNotEmpty() && card != null) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box {
                        ComposerSettingPill(selectedHarness?.name ?: provider.ifBlank { "Agent" }, enabled = !locked) { providerMenu = true }
                        DropdownMenu(providerMenu, { providerMenu = false }) {
                            harnesses.forEach { harness ->
                                DropdownMenuItem(text = { Text(harness.name) }, onClick = {
                                    providerMenu = false
                                    provider = harness.id
                                    selectedModel = harness.defaultModel
                                    effort = ""
                                })
                            }
                        }
                    }
                    Box {
                        ComposerSettingPill(selectedHarnessModel?.name ?: selectedModel.ifBlank { "Default model" }, enabled = !locked) { modelMenu = true }
                        DropdownMenu(modelMenu, { modelMenu = false }) {
                            selectedHarness?.modelsList.orEmpty().forEach { harnessModel ->
                                DropdownMenuItem(text = { Text(harnessModel.name) }, onClick = {
                                    modelMenu = false
                                    selectedModel = harnessModel.id
                                    effort = ""
                                })
                            }
                        }
                    }
                    if (effortOptions.isNotEmpty()) {
                        Box {
                            ComposerSettingPill(effortLabel, enabled = !locked) { effortMenu = true }
                            DropdownMenu(effortMenu, { effortMenu = false }) {
                                DropdownMenuItem(text = { Text("Default") }, onClick = { effortMenu = false; effort = "" })
                                effortOptions.forEach { option ->
                                    DropdownMenuItem(text = { Text(option.name) }, onClick = { effortMenu = false; effort = option.id })
                                }
                            }
                        }
                    }
                }
                if (contextUsage != null) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "${formatTokenCount(contextUsage.used)} · ${contextUsage.percent}%",
                        color = NauclioMuted.copy(alpha = 0.78f),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                    )
                }
            }
        }
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Surface(
                color = NauclioSurfaceHigh,
                shape = RoundedCornerShape(27.dp),
                modifier = Modifier.weight(1f),
            ) {
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    enabled = enabled,
                    maxLines = 5,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                    ),
                    cursorBrush = SolidColor(NauclioAegean),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp, max = 144.dp).testTag("message-input"),
                    decorationBox = { innerTextField ->
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 54.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (onAttach != null) {
                                IconButton(onClick = onAttach, enabled = enabled, modifier = Modifier.size(42.dp)) {
                                    Icon(Icons.Outlined.AttachFile, "Attach images or files", tint = NauclioMuted, modifier = Modifier.size(19.dp))
                                }
                            } else {
                                Spacer(Modifier.width(17.dp))
                            }
                            Box(Modifier.weight(1f).padding(end = 14.dp, top = 15.dp, bottom = 14.dp)) {
                                if (value.isEmpty()) Text(placeholder, color = NauclioMuted.copy(alpha = 0.72f), fontSize = 14.sp)
                                innerTextField()
                            }
                        }
                    },
                )
            }
            val canSend = enabled && (value.isNotBlank() || attachments.isNotEmpty())
            Box(
                Modifier.size(54.dp).clip(RoundedCornerShape(18.dp))
                    .background(NauclioAegean)
                    .clickable(enabled = canSend) { onSend(provider, selectedModel, effort) }
                    .testTag("send-message"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Color(0xFF071426), modifier = Modifier.size(23.dp))
            }
        }
    }
}

@Composable
private fun ComposerSettingPill(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.height(32.dp).widthIn(max = 142.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(NauclioSurfaceHigh)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 11.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = NauclioMuted, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private data class ComposerContextUsage(val used: Long, val percent: Int)

private fun latestContextUsage(messages: List<UiMessage>): ComposerContextUsage? {
    messages.asReversed().forEach { message ->
        val raw = message.metadataJson.toString(StandardCharsets.UTF_8)
        if (raw.isBlank()) return@forEach
        val metadata = runCatching { JSONObject(raw) }.getOrNull() ?: return@forEach
        val usage = metadata.optJSONObject("usage") ?: return@forEach
        val rawUsage = usage.optJSONObject("raw")
        val used = rawUsage?.longOrNull("totalTokens")
            ?: usage.longOrNull("totalTokens")
            ?: ((usage.longOrNull("inputTokens") ?: 0L) + (usage.longOrNull("outputTokens") ?: 0L))
        val available = metadata.longOrNull("contextWindowTokens")
        if (used > 0 && available != null && available > 0) {
            return ComposerContextUsage(used, ((used.toDouble() / available) * 100).toInt().coerceIn(0, 100))
        }
    }
    return null
}

private fun JSONObject.longOrNull(key: String): Long? =
    if (has(key) && !isNull(key)) optLong(key) else null

private fun formatTokenCount(tokens: Long): String = when {
    tokens >= 100_000 -> "${tokens / 1_000}k"
    tokens >= 1_000 -> String.format(Locale.US, "%.1fk", tokens / 1_000.0)
    else -> tokens.toString()
}

@Composable
private fun BoardLabelFilters(
    state: NauclioUiState,
    selectedLabelId: String,
    dragState: BoardLabelDragState,
    onSelect: (String) -> Unit,
    onDrop: (cardId: String, labelId: String) -> Unit,
) {
    val board = state.board ?: return
    val boardCards = state.cards.filter { it.boardId == board.id }
    val haptic = LocalHapticFeedback.current
    val currentOnDrop by rememberUpdatedState(onDrop)
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val filters = listOf("" to "All cards") + board.labelsList.map { it.id to it.name }
        filters.forEach { (labelId, name) ->
            val selected = labelId == selectedLabelId
            val count = if (labelId.isBlank()) boardCards.size else boardCards.count { labelId in it.labelIdsList }
            val boardLabel = board.labelsList.firstOrNull { it.id == labelId }
            val tint = boardLabel?.color?.let { value ->
                runCatching { Color(value.toColorInt()) }.getOrNull()
            }
            var sourceOrigin by remember(board.id, labelId) { mutableStateOf(Offset.Zero) }
            val dragModifier = if (labelId.isBlank()) Modifier else Modifier
                .testTag("board-label-$labelId")
                .semantics { contentDescription = "$name label; drag onto a card to assign" }
                .onGloballyPositioned { sourceOrigin = it.positionInRoot() }
                .pointerInput(board.id, labelId, dragState) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { offset ->
                            dragState.start(
                                DraggedBoardLabel(labelId, name, boardLabel?.color.orEmpty()),
                                sourceOrigin + offset,
                            )
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        },
                        onDrag = { change, dragAmount ->
                            change.consume()
                            dragState.moveBy(dragAmount)
                        },
                        onDragEnd = {
                            dragState.finish()?.let { (cardId, droppedLabelId) ->
                                currentOnDrop(cardId, droppedLabelId)
                            }
                        },
                        onDragCancel = dragState::reset,
                    )
                }
            Surface(
                onClick = { onSelect(labelId) },
                modifier = dragModifier,
                shape = RoundedCornerShape(12.dp),
                color = if (selected) Color(0xFF173A5D) else Color.Transparent,
                contentColor = if (selected) MaterialTheme.colorScheme.onBackground else NauclioMuted,
                border = if (selected) null else androidx.compose.foundation.BorderStroke(1.dp, NauclioOutline.copy(alpha = 0.72f)),
            ) {
                Row(
                    Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (labelId.isBlank() && selected) Icon(Icons.Default.Check, null, Modifier.size(15.dp), tint = NauclioAegean)
                    else if (tint != null) Box(Modifier.size(8.dp).clip(CircleShape).background(tint))
                    Text(
                        "$name · $count",
                        fontSize = 13.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    )
                }
            }
        }
    }
}

@Composable
private fun LaneTabs(state: NauclioUiState, model: NauclioViewModel, visibleCards: List<BoardCard>) {
    val board = state.board ?: return
    val selectedIndex = board.lanesList.indexOfFirst { it.id == state.selectedLane }.coerceAtLeast(0)
    PrimaryTabRow(
        selectedTabIndex = selectedIndex,
        containerColor = MaterialTheme.colorScheme.background,
        contentColor = NauclioAegean,
        divider = { HorizontalDivider(color = NauclioOutline.copy(alpha = 0.72f)) },
    ) {
        board.lanesList.forEach { lane ->
            val count = visibleCards.count { it.lane == lane.id }
            val selected = state.selectedLane == lane.id
            Tab(
                selected = selected,
                onClick = { model.selectLane(lane.id) },
                selectedContentColor = NauclioAegean,
                unselectedContentColor = NauclioMuted,
                text = {
                    Text(
                        "${lane.name} $count",
                        fontSize = 12.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    )
                },
            )
        }
    }
}

@Composable
private fun SwipeableWorkCard(
    card: BoardCard,
    board: Board?,
    selected: Boolean,
    pending: Boolean,
    revealed: Boolean,
    onReveal: () -> Unit,
    onCloseActions: () -> Unit,
    onMove: () -> Unit,
    onEdit: () -> Unit,
    onArchive: () -> Unit,
    onStart: () -> Unit,
    labelDragState: BoardLabelDragState,
    onClick: () -> Unit,
) {
    val density = LocalDensity.current
    val revealDistance = with(density) { 264.dp.toPx() }
    var dragOffset by remember(card.id) { mutableFloatStateOf(0f) }
    val labelDropTargeted = labelDragState.isTargeted(card.id)

    DisposableEffect(labelDragState, card.id) {
        onDispose { labelDragState.unregisterCard(card.id) }
    }

    LaunchedEffect(revealed, revealDistance) {
        dragOffset = if (revealed) -revealDistance else 0f
    }

    Box(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(17.dp))
            .background(NauclioSurfaceHigh)
            .then(
                if (labelDropTargeted) Modifier.border(2.dp, NauclioSeafoam, RoundedCornerShape(17.dp))
                else Modifier,
            )
            .onGloballyPositioned { labelDragState.registerCard(card.id, it.boundsInRoot()) }
            .semantics {
                contentDescription = "${card.title.ifBlank { "Untitled conversation" }}; drop a board label here"
            }
            .testTag("swipe-card-${card.id}"),
    ) {
        Row(
            Modifier.matchParentSize(),
            horizontalArrangement = Arrangement.End,
        ) {
            SwipeCardAction(
                label = "Edit",
                icon = Icons.Outlined.Edit,
                containerColor = NauclioSurface,
                contentColor = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.testTag("edit-card-${card.id}"),
                onClick = onEdit,
            )
            SwipeCardAction(
                label = "Move",
                icon = Icons.AutoMirrored.Outlined.DriveFileMove,
                containerColor = NauclioAegean.copy(alpha = 0.24f),
                contentColor = NauclioCobalt,
                modifier = Modifier.testTag("move-card-${card.id}"),
                onClick = onMove,
            )
            SwipeCardAction(
                label = "Archive",
                icon = Icons.Outlined.Archive,
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
                modifier = Modifier.testTag("archive-card-${card.id}"),
                onClick = onArchive,
            )
        }
        WorkCard(
            card = card,
            board = board,
            selected = selected,
            pending = pending,
            modifier = Modifier
                .offset { IntOffset(dragOffset.toInt(), 0) }
                .draggable(
                    orientation = Orientation.Horizontal,
                    state = rememberDraggableState { delta ->
                        dragOffset = (dragOffset + delta).coerceIn(-revealDistance, 0f)
                    },
                    onDragStopped = {
                        if (shouldRevealCardActions(dragOffset, revealDistance)) {
                            dragOffset = -revealDistance
                            onReveal()
                        } else {
                            dragOffset = 0f
                            onCloseActions()
                        }
                    },
                ),
            onStart = onStart.takeIf { card.startLane(board) != null },
            onClick = if (revealed) onCloseActions else onClick,
        )
    }
}

@Composable
private fun SwipeCardAction(
    label: String,
    icon: ImageVector,
    containerColor: Color,
    contentColor: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = modifier.width(88.dp).fillMaxHeight(),
        color = containerColor,
        contentColor = contentColor,
    ) {
        Column(
            Modifier.fillMaxHeight().padding(horizontal = 8.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(icon, contentDescription = null, Modifier.size(21.dp))
            Spacer(Modifier.height(5.dp))
            Text(label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun MoveCardSheet(
    card: BoardCard,
    lanes: List<com.dbpprt.nauclio.v1.Lane>,
    onDismiss: () -> Unit,
    onMove: (String) -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("Move card", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(card.title.ifBlank { "Untitled conversation" }, color = NauclioMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(8.dp))
            lanes.forEach { lane ->
                val current = lane.id == card.lane
                Row(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable(enabled = !current) { onMove(lane.id) }
                        .testTag("move-card-to-${lane.id}")
                        .padding(horizontal = 14.dp, vertical = 15.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(lane.name, Modifier.weight(1f), fontWeight = FontWeight.Medium)
                    if (current) {
                        Icon(Icons.Default.Check, contentDescription = null, Modifier.size(18.dp), tint = NauclioSeafoam)
                        Spacer(Modifier.width(6.dp))
                        Text("Current", color = NauclioMuted, fontSize = 12.sp)
                    } else {
                        Icon(Icons.AutoMirrored.Outlined.DriveFileMove, contentDescription = "Move to ${lane.name}", tint = NauclioMuted)
                    }
                }
            }
        }
    }
}

@Composable
private fun EditCardSheet(
    card: BoardCard,
    working: Boolean,
    onDismiss: () -> Unit,
    onSave: (String, String) -> Unit,
) {
    var title by remember(card.id) { mutableStateOf(card.title) }
    var task by remember(card.id) { mutableStateOf(card.initialPrompt) }
    val taskEditable = card.canEditInitialTask()
    val canSave = title.isNotBlank() && task.isNotBlank() && !working
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = NauclioSurfaceHigh) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Edit card", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                if (taskEditable) "Update this draft before its task is sent to the agent."
                else "The task is read-only because it has already been sent to the agent.",
                color = NauclioMuted,
                fontSize = 12.sp,
                lineHeight = 17.sp,
            )
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Card title") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("edit-card-title"),
            )
            OutlinedTextField(
                value = task,
                onValueChange = { if (taskEditable) task = it },
                label = { Text("Agent task") },
                readOnly = !taskEditable,
                enabled = taskEditable,
                minLines = 5,
                modifier = Modifier.fillMaxWidth().testTag("edit-card-task"),
            )
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDismiss, enabled = !working, modifier = Modifier.testTag("cancel-card-edit")) {
                    Text("Cancel")
                }
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = { onSave(title.trim(), task.trim()) },
                    enabled = canSave,
                    modifier = Modifier.testTag("save-card-edit"),
                ) {
                    if (working) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    else Icon(Icons.Default.Check, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Save")
                }
            }
        }
    }
}

@Composable
private fun WorkCard(
    card: BoardCard,
    board: Board?,
    selected: Boolean,
    pending: Boolean,
    modifier: Modifier = Modifier,
    onStart: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val labels = board?.labelsList.orEmpty().filter { card.labelIdsList.contains(it.id) }
    Card(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().alpha(if (pending) 0.52f else 1f).then(
            if (selected) Modifier.border(1.dp, NauclioCobalt, RoundedCornerShape(17.dp)) else Modifier,
        ),
        colors = CardDefaults.cardColors(containerColor = if (selected) Color(0xFF102A47) else NauclioSurfaceHigh),
        shape = RoundedCornerShape(17.dp),
    ) {
        Column {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 13.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        card.title.ifBlank { "Untitled conversation" },
                        Modifier.weight(1f),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(shortTimestamp(card.lastActivityAt.ifBlank { card.updatedAt }), color = NauclioMuted, fontSize = 12.sp)
                }
                if (card.summary.isNotBlank()) {
                    Text(
                        card.summary,
                        color = NauclioMuted,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (labels.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        labels.take(3).forEach { label -> LabelPill(label.name, label.color) }
                    }
                }
            }
            HorizontalDivider(color = NauclioOutline.copy(alpha = 0.52f))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(card.provider.ifBlank { "agent" }, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                Spacer(Modifier.width(8.dp))
                Text(card.model, color = NauclioMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                if (onStart != null) {
                    Surface(
                        onClick = onStart,
                        modifier = Modifier.testTag("start-card-${card.id}"),
                        shape = RoundedCornerShape(10.dp),
                        color = NauclioSeafoam.copy(alpha = 0.16f),
                        contentColor = NauclioSeafoam,
                    ) {
                        Row(
                            Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Default.PlayArrow, contentDescription = null, Modifier.size(16.dp))
                            Spacer(Modifier.width(3.dp))
                            Text("Start", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                }
                if (card.commentCount > 0) {
                    Icon(Icons.Outlined.ChatBubbleOutline, null, Modifier.size(15.dp), tint = NauclioMuted)
                    Text(" ${card.commentCount}", color = NauclioMuted, fontSize = 12.sp)
                    Spacer(Modifier.width(10.dp))
                }
                Icon(Icons.Outlined.CheckCircle, null, Modifier.size(18.dp), tint = if (card.lane.contains("done", true)) NauclioSeafoam else NauclioMuted)
            }
        }
    }
}

@Composable
private fun LabelPill(name: String, color: String) {
    val tint = runCatching { Color(color.toColorInt()) }.getOrDefault(NauclioAegean)
    Row(
        Modifier.clip(RoundedCornerShape(20.dp)).background(tint.copy(alpha = 0.18f)).padding(horizontal = 9.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(tint))
        Spacer(Modifier.width(5.dp))
        Text(name, color = tint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun StatusPill(status: String) {
    val active = status.contains("running", true) || status.contains("starting", true) || status.contains("working", true)
    Row(
        Modifier.clip(RoundedCornerShape(20.dp))
            .border(1.dp, NauclioOutline.copy(alpha = 0.82f), RoundedCornerShape(20.dp))
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(8.dp).then(
                if (active) Modifier.clip(CircleShape).background(NauclioSeafoam)
                else Modifier.border(1.dp, NauclioMuted, CircleShape),
            ),
        )
        Spacer(Modifier.width(6.dp))
        Text(status.replaceFirstChar { it.uppercase() }, color = NauclioMuted, fontSize = 11.sp)
    }
}

@Composable
private fun ConnectionEmptyState(state: NauclioUiState, model: NauclioViewModel) {
    if (state.desiredConnected) return
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Sync, null, Modifier.size(46.dp), tint = NauclioAegean)
        Spacer(Modifier.height(14.dp))
        Text("Connect to Nauclio", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text("Start nauclio serve on this computer and bridge the visible emulator with adb reverse tcp:4242 tcp:4242.", color = NauclioMuted)
        Spacer(Modifier.height(16.dp))
        OutlinedButton(onClick = model::refresh) { Text(state.endpoint) }
        TextButton(onClick = model::refresh) { Text("Try again") }
    }
}

@Composable
private fun LoadingState(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

@Composable
private fun EmptyList(title: String, body: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(icon, null, Modifier.size(42.dp), tint = NauclioMuted)
        Spacer(Modifier.height(12.dp))
        Text(title, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(5.dp))
        Text(body, color = NauclioMuted)
    }
}

@Composable
private fun EmptyDetail(title: String, body: String, icon: ImageVector, modifier: Modifier = Modifier) {
    EmptyList(title, body, icon, modifier)
}

@Composable
private fun HorizontalPaneDivider() {
    Box(Modifier.fillMaxHeight().width(1.dp).background(NauclioOutline))
}

internal fun shortTimestamp(
    value: String,
    now: Instant = Instant.now(),
    zoneId: ZoneId = ZoneId.systemDefault(),
): String {
    if (value.isBlank()) return ""
    return runCatching {
        val timestamp = Instant.parse(value)
        if (timestamp.isAfter(now)) {
            val until = Duration.between(now, timestamp)
            return@runCatching when {
                until.toMinutes() < 1 -> "in <1m"
                until.toMinutes() < 60 -> "in ${until.toMinutes()}m"
                until.toHours() < 24 -> "in ${until.toHours()}h"
                else -> DateTimeFormatter.ofPattern("MMM d · HH:mm")
                    .format(timestamp.atZone(zoneId))
            }
        }
        val age = Duration.between(timestamp, now)
        when {
            age.toMinutes() < 1 -> "now"
            age.toMinutes() < 60 -> "${age.toMinutes()}m"
            age.toHours() < 24 -> "${age.toHours()}h"
            else -> DateTimeFormatter.ofPattern("MMM d")
                .format(timestamp.atZone(zoneId))
        }
    }.getOrElse { value.substringBefore('T').takeLast(5) }
}

@Composable
internal fun FileCreateDialog(currentPath: String, onDismiss: () -> Unit, onCreate: (String, Boolean) -> Unit) {
    var name by remember { mutableStateOf("") }
    var directory by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Create in ${currentPath.ifBlank { "/" }}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = !directory, onClick = { directory = false }, label = { Text("File") })
                    FilterChip(selected = directory, onClick = { directory = true }, label = { Text("Folder") })
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { onCreate(listOf(currentPath.trim('/'), name.trim('/')).filter { it.isNotBlank() }.joinToString("/"), directory) },
                enabled = name.isNotBlank(),
            ) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun TextInputDialog(
    title: String,
    label: String,
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var value by remember(initial) { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(value, { value = it }, label = { Text(label) }, modifier = Modifier.fillMaxWidth()) },
        confirmButton = { Button(onClick = { onConfirm(value.trim()) }, enabled = value.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ConfirmDialog(
    title: String,
    body: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = { Button(onClick = onConfirm) { Text(confirmLabel) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun CardLabelsDialog(state: NauclioUiState, onDismiss: () -> Unit, onSave: (List<String>) -> Unit) {
    val selected = remember(state.selectedCardId) { mutableStateListOf<String>().also { it += state.selectedCard?.labelIdsList.orEmpty() } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Card labels") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                state.board?.labelsList.orEmpty().forEach { label ->
                    FilterChip(
                        selected = label.id in selected,
                        onClick = { if (label.id in selected) selected.remove(label.id) else selected += label.id },
                        label = { Text(label.name) },
                    )
                }
                if (state.board?.labelsCount == 0) Text("This board has no labels yet.", color = NauclioMuted)
            }
        },
        confirmButton = { Button(onClick = { onSave(selected.toList()) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

internal fun Harness.effortOptionsFor(modelId: String) =
    modelsList.firstOrNull { it.id == modelId }?.effortsList.orEmpty().let { allowed ->
        effort.optionsList.filter { allowed.isEmpty() || it.id in allowed }
    }
