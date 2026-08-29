@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

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
import androidx.compose.foundation.layout.navigationBarsPadding
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
import androidx.compose.material.icons.outlined.ArrowDownward
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
import androidx.compose.material.icons.outlined.Settings
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
import androidx.compose.material3.PrimaryScrollableTabRow
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
import androidx.compose.runtime.withFrameNanos
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
import com.dbpprt.dieter.connection.ProjectHost
import com.dbpprt.dieter.connection.isServerConversationId
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
import com.dbpprt.dieter.v1.FileDocument
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.QueuedMessage
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.Subagent
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.UiMessage
import com.dbpprt.dieter.v1.ToolOutput
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
import com.dbpprt.dieter.ui.theme.DieterAmberTint
import com.dbpprt.dieter.ui.theme.DieterShellTintDeep
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterRunning
import com.dbpprt.dieter.ui.theme.DieterAbyss

private const val PROJECT_CHAT_PREVIEW_COUNT = 5

internal fun conversationRefreshLabel(lastRefreshedAtMillis: Long?, syncing: Boolean, nowMillis: Long): String {
    if (lastRefreshedAtMillis == null) return if (syncing) "Refreshing…" else "Not refreshed yet"
    val ageMillis = (nowMillis - lastRefreshedAtMillis).coerceAtLeast(0L)
    val freshness = when {
        ageMillis < 60_000L -> "just now"
        ageMillis < 3_600_000L -> "${ageMillis / 60_000L}m ago"
        ageMillis < 86_400_000L -> "${ageMillis / 3_600_000L}h ago"
        else -> DateTimeFormatter.ofPattern("MMM d · HH:mm", Locale.getDefault())
            .format(Instant.ofEpochMilli(lastRefreshedAtMillis).atZone(ZoneId.systemDefault()))
    }
    return "Last refreshed $freshness" + if (syncing) " · Refreshing…" else ""
}

/** Dashed rounded outline used by the reference design for "add" affordances and empty states. */
internal fun Modifier.dashedBorder(
    color: Color,
    cornerRadius: androidx.compose.ui.unit.Dp = 20.dp,
    strokeWidth: androidx.compose.ui.unit.Dp = 1.dp,
): Modifier = drawBehind {
    val stroke = androidx.compose.ui.graphics.drawscope.Stroke(
        width = strokeWidth.toPx(),
        pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(
            floatArrayOf(9.dp.toPx(), 7.dp.toPx()),
        ),
    )
    drawRoundRect(
        color = color,
        style = stroke,
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(cornerRadius.toPx()),
    )
}

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
private fun SpacesOverview(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
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
    Surface(shape = RoundedCornerShape(50), color = (if (host.online) DieterEyes else DieterMuted).copy(alpha = 0.1f)) {
        Row(Modifier.padding(horizontal = 7.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(5.dp).background(if (host.online) DieterEyes else DieterMuted, CircleShape))
            Spacer(Modifier.width(5.dp))
            Text(host.hostname, color = DieterMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
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
private fun BoardDetailHeader(
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
private fun BoardQuickSwitcher(state: DieterUiState, model: DieterViewModel, onDismiss: () -> Unit) {
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
private fun BoardMark(color: Color, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(4.dp).height(18.dp).clip(CircleShape).background(color))
        Box(Modifier.width(4.dp).height(13.dp).clip(CircleShape).background(color.copy(alpha = 0.82f)))
        Box(Modifier.width(4.dp).height(8.dp).clip(CircleShape).background(color.copy(alpha = 0.68f)))
    }
}

private fun stableAccent(id: String): Color {
    val option = LabelColorPalette[Math.floorMod(id.hashCode(), LabelColorPalette.size)]
    return runCatching { Color(option.value.toColorInt()) }.getOrDefault(DieterShellDeep)
}

private fun laneColor(lane: String): Color = when {
    lane.contains("review", true) -> DieterAmber
    lane.contains("done", true) -> DieterEyes
    lane.contains("running", true) -> DieterRunning
    else -> DieterMuted.copy(alpha = 0.58f)
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
private fun BoardList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
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
            containerColor = DieterPane,
            contentColor = DieterAbyss,
            shape = RoundedCornerShape(24.dp),
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
}

@Composable
private fun BoardLanePager(
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
        val visible = cardsByCreationTime(
            boardCards.filter { card -> card.lane == lane.id },
            direction = sortDirection,
        )
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
private fun LaneSortButton(
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

@Composable
fun ChatsScreen(
    state: DieterUiState,
    model: DieterViewModel,
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
private fun ChatsList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    var expandedProjects by remember { mutableStateOf(emptySet<String>()) }
    Box(modifier) {
        Column(Modifier.fillMaxSize()) {
            SimpleScreenHeader("Chats") {
                IconButton(onClick = { model.openSurface(AppSurface.APP_SETTINGS) }) {
                    Icon(Icons.Outlined.Settings, "App settings", tint = DieterMuted)
                }
            }
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
                                        state.presentedProjectHosts[project.id]?.let { append(" · ").append(it.hostname) }
                                        append(" · ").append(projectChats.size)
                                    },
                                    Modifier.weight(1f),
                                )
                                IconButton(onClick = { model.selectProject(project.id); model.openSurface(AppSurface.NEW_CHAT) }, modifier = Modifier.size(36.dp)) {
                                    Icon(Icons.Default.Add, "New chat in ${project.name}", tint = DieterMuted, modifier = Modifier.size(18.dp))
                                }
                            }
                        }
                        if (projectChats.isEmpty() && query.isBlank()) {
                            item(key = "project-chat-empty-${project.id}") {
                                Text(
                                    "No chats yet",
                                    color = DieterMuted,
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
                                            color = DieterShell,
                                            fontWeight = FontWeight.SemiBold,
                                        )
                                        Spacer(Modifier.width(4.dp))
                                        Icon(
                                            Icons.Outlined.KeyboardArrowDown,
                                            contentDescription = null,
                                            tint = DieterShell,
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
            text = { Text("New chat", fontWeight = FontWeight.SemiBold) },
            modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).height(52.dp),
            containerColor = DieterPane,
            contentColor = DieterAbyss,
            shape = RoundedCornerShape(50),
        )
    }
}

@Composable
private fun ChatRow(chat: BoardCard, model: DieterViewModel) {
    Surface(
        color = if (chat.pinned) DieterSurface else Color.Transparent,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp).alpha(if (model.isPendingCard(chat.id)) 0.52f else 1f),
    ) {
        Row(
            Modifier.fillMaxWidth().clickable { model.openCard(chat, Destination.CHATS) }
                .padding(horizontal = 12.dp, vertical = if (chat.pinned) 13.dp else 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (chat.pinned) {
                Surface(shape = CircleShape, color = DieterShellTint, modifier = Modifier.size(36.dp)) {
                    Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.PushPin, null, tint = DieterShell, modifier = Modifier.size(17.dp)) }
                }
            } else {
                Box(
                    Modifier.size(10.dp).border(1.dp, if (chat.runtime.contains("running", true)) DieterShell else DieterMuted, CircleShape)
                        .then(if (chat.runtime.contains("running", true)) Modifier.background(DieterShell, CircleShape) else Modifier),
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
            Text(shortTimestamp(chat.lastActivityAt.ifBlank { chat.updatedAt }), color = DieterMuted, fontSize = 11.sp)
        }
    }
}

@Composable
private fun ListSectionLabel(value: String, modifier: Modifier = Modifier) {
    Text(
        value.uppercase(),
        color = DieterMuted,
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
            if (!subtitle.isNullOrBlank()) Text(subtitle, color = DieterMuted, fontSize = 11.sp)
        }
        actions?.invoke(this)
    }
}

@Composable
private fun CompactSearchField(value: String, onValueChange: (String) -> Unit, placeholder: String) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            .height(42.dp).clip(RoundedCornerShape(22.dp)).background(DieterSurfaceHigh)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.Search, null, tint = DieterMuted, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(8.dp))
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onBackground),
            cursorBrush = SolidColor(DieterShell),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                if (value.isBlank()) Text(placeholder, color = DieterMuted, fontSize = 13.sp)
                inner()
            }
        )
    }
}

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
private fun FileList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
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
private fun FilePreview(
    state: DieterUiState,
    model: DieterViewModel,
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
fun SchedulesScreen(state: DieterUiState, model: DieterViewModel, contentPadding: PaddingValues) {
    Box(Modifier.fillMaxSize().padding(contentPadding)) {
        Column(Modifier.fillMaxSize()) {
            SimpleScreenHeader(
                "Schedules",
                "${state.project?.name?.lowercase() ?: "project"} · ${state.schedules.count { it.enabled }} active · ${state.schedules.size} configured",
            ) {
                IconButton(onClick = model::refresh) { Icon(Icons.Outlined.Refresh, "Refresh schedules") }
                IconButton(onClick = { model.openSurface(AppSurface.APP_SETTINGS) }) {
                    Icon(Icons.Outlined.Settings, "App settings", tint = DieterMuted)
                }
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
                text = { Text("New schedule", fontWeight = FontWeight.SemiBold) },
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).height(52.dp).testTag("new-schedule"),
                containerColor = DieterPane,
                contentColor = DieterAbyss,
                shape = RoundedCornerShape(50),
            )
        }
    }
}

@Composable
private fun ScheduleEmptyState(onCreate: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            Modifier.fillMaxWidth()
                .dashedBorder(DieterOutline.copy(alpha = 0.9f), cornerRadius = 24.dp)
                .padding(horizontal = 28.dp, vertical = 34.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Surface(shape = RoundedCornerShape(18.dp), color = DieterShellTint, modifier = Modifier.size(64.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.CalendarMonth, null, tint = DieterShell, modifier = Modifier.size(28.dp))
                }
            }
            Spacer(Modifier.height(18.dp))
            Text("Automate recurring work", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text(
                "Create cards on a project calendar, then optionally start their local agents when capacity is available.",
                color = DieterMuted,
                fontSize = 13.sp,
                lineHeight = 19.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(18.dp))
            Button(
                onClick = onCreate,
                shape = RoundedCornerShape(50),
                modifier = Modifier.testTag("new-schedule"),
            ) {
                Icon(Icons.Default.Add, null, Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Create the first schedule")
            }
        }
    }
}

@Composable
private fun ScheduleCard(
    schedule: Schedule,
    state: DieterUiState,
    model: DieterViewModel,
    onEdit: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    Card(
        onClick = { model.selectSchedule(if (state.selectedScheduleId == schedule.id) null else schedule) },
        colors = CardDefaults.cardColors(containerColor = DieterSurfaceHigh),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(schedule.name, fontWeight = FontWeight.SemiBold)
                    Text(schedule.cron + " · " + schedule.timezone, color = DieterMuted, fontSize = 13.sp)
                }
                Switch(checked = schedule.enabled, onCheckedChange = { model.toggleSchedule(schedule) })
            }
            if (schedule.description.isNotBlank()) Text(schedule.description, color = DieterMuted)
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
                Text("Next · ${shortTimestamp(schedule.nextRunAt)}", color = DieterShell, fontSize = 12.sp)
            }
            if (state.selectedScheduleId == schedule.id) {
                HorizontalDivider(color = DieterOutline)
                Text("Recent runs", fontWeight = FontWeight.SemiBold)
                if (state.scheduleRuns.isEmpty()) {
                    Text("No occurrences yet", color = DieterMuted, fontSize = 12.sp)
                } else {
                    state.scheduleRuns.forEach { run ->
                        Text(
                            "${run.status.ifBlank { "unknown" }} · ${shortTimestamp(run.scheduledFor.ifBlank { run.createdAt })}${run.message.takeIf { it.isNotBlank() }?.let { " · $it" }.orEmpty()}",
                            color = if (run.status == "failed") MaterialTheme.colorScheme.error else DieterMuted,
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
    state: DieterUiState,
    model: DieterViewModel,
    modifier: Modifier = Modifier,
    showBack: Boolean = true,
) {
    val snapshot = state.conversation
    val card = snapshot?.detail?.card ?: state.selectedCard
    var renameOpen by remember { mutableStateOf(false) }
    var labelsOpen by remember { mutableStateOf(false) }
    var actionsOpen by remember { mutableStateOf(false) }
    var refreshClockMillis by remember(state.selectedCardId) { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.selectedCardId, state.conversationLastRefreshedAtMillis) {
        refreshClockMillis = System.currentTimeMillis()
        while (true) {
            delay(30_000L)
            refreshClockMillis = System.currentTimeMillis()
        }
    }
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
    val serverBacked = isServerConversationId(card.id)
    val changedFileCount = state.workspaceReview.changeset?.filesCount ?: card.workspace.changedFiles
    val showDetailTabs = !standalone || serverBacked || subagents.isNotEmpty() || commentCount > 0
    val cardOperation = state.cardOperations[card.id]
    val displayRuntime = resolvedCardRuntime(card.runtime, snapshot?.conversation?.status.orEmpty(), cardOperation)
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
                    color = DieterMuted,
                    fontSize = 11.sp,
                )
                Text(
                    conversationRefreshLabel(
                        state.conversationLastRefreshedAtMillis,
                        state.conversationSyncing,
                        refreshClockMillis,
                    ),
                    color = DieterMuted,
                    fontSize = 10.sp,
                    modifier = Modifier.testTag("conversation-last-refreshed"),
                )
            }
            StatusPill(displayRuntime)
            if (isActiveCardRuntime(displayRuntime) && cardOperation != CardOperation.CANCELLING) {
                IconButton(onClick = model::cancelSelected) {
                    Icon(Icons.Outlined.Cancel, "Cancel active turn")
                }
            }
            Box {
                IconButton(onClick = { actionsOpen = true }) { Icon(Icons.Outlined.MoreVert, "Conversation actions") }
                DropdownMenu(expanded = actionsOpen, onDismissRequest = { actionsOpen = false }) {
                    if (model.isFailedOutboxItem(card.id)) {
                        DropdownMenuItem(
                            text = { Text("Retry queued action") },
                            onClick = { actionsOpen = false; model.retryOutboxItem(card.id) },
                        )
                        DropdownMenuItem(
                            text = { Text("Discard queued action") },
                            onClick = { actionsOpen = false; model.discardOutboxItem(card.id) },
                        )
                    }
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
                    DropdownMenuItem(
                        text = { Text("Fork as new chat") },
                        onClick = { actionsOpen = false; model.forkSelected() },
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
        // Stale-while-revalidate affordance: the cached transcript stays
        // interactive while this strip signals a live refresh is in flight.
        if (state.conversationSyncing && snapshot != null) {
            LinearProgressIndicator(
                Modifier.fillMaxWidth().height(2.dp).testTag("conversation-syncing"),
                color = DieterShell,
            )
        }
        if (showDetailTabs) {
            PrimaryScrollableTabRow(
                selectedTabIndex = state.detailTab,
                containerColor = MaterialTheme.colorScheme.background,
                edgePadding = 4.dp,
            ) {
                detailSections.forEachIndexed { index, section ->
                    Tab(
                        selected = state.detailTab == index,
                        onClick = { model.selectDetailTab(index) },
                        selectedContentColor = DieterShell,
                        unselectedContentColor = DieterMuted,
                        text = {
                            DetailTabLabel(
                                section.label,
                                count = when (section) {
                                    DetailSection.CONVERSATION -> 0
                                    DetailSection.CHANGES -> changedFileCount
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
                    DetailSection.CHANGES -> WorkspaceChangesBody(
                        state = state,
                        model = model,
                        active = detailSections.getOrNull(state.detailTab) == DetailSection.CHANGES,
                        modifier = Modifier.fillMaxSize(),
                    )
                    DetailSection.COMMENTS -> CommentsBody(state, model, Modifier.fillMaxSize())
                    DetailSection.SUBAGENTS -> SubagentsBody(state, model, Modifier.fillMaxSize())
                }
            }
        } else {
            HorizontalDivider(color = DieterOutline.copy(alpha = 0.52f))
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
    CHANGES("Changes"),
    COMMENTS("Comments"),
    SUBAGENTS("Subagents"),
}

internal fun detailSectionsFor(standalone: Boolean): List<DetailSection> = if (standalone) {
    listOf(DetailSection.CONVERSATION, DetailSection.CHANGES, DetailSection.SUBAGENTS, DetailSection.COMMENTS)
} else {
    listOf(DetailSection.CONVERSATION, DetailSection.CHANGES, DetailSection.COMMENTS, DetailSection.SUBAGENTS)
}

@Composable
private fun DetailTabLabel(label: String, count: Int = 0, selected: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
        if (count > 0) {
            Surface(
                color = if (selected) DieterShell.copy(alpha = 0.18f) else DieterSurfaceHigh,
                shape = CircleShape,
            ) {
                Text(
                    count.toString(),
                    color = if (selected) DieterShell else DieterMuted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
                )
            }
        } else if (label == "Comments") {
            Text("0", color = DieterMuted, fontSize = 12.sp)
        }
    }
}

@Composable
private fun SubagentsBody(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
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
                Text("● $active running", color = DieterRunning, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
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
                        color = DieterMuted,
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
        running -> DieterRunning
        completed -> DieterEyes
        else -> MaterialTheme.colorScheme.error
    }
    Surface(
        color = DieterSurfaceHigh,
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
                    Text(elapsed, color = if (running) tint else DieterMuted, fontSize = 10.sp)
                }
            }
            val activity = subagent.activity.ifBlank {
                subagent.currentTool.ifBlank { subagent.description.ifBlank { subagent.assignment } }
            }
            if (activity.isNotBlank() && cleanSubagentTitle(activity) != title) {
                Text(
                    activity,
                    color = DieterMuted,
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
                    trackColor = DieterOutline,
                )
            }
            HorizontalDivider(color = DieterOutline.copy(alpha = 0.52f), modifier = Modifier.padding(top = 10.dp))
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
                    color = DieterMuted,
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
private fun ConversationBody(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    val allMessages = state.conversationMessages
    val listState = remember(state.selectedCardId) { LazyListState() }
    var initialScrollComplete by remember(state.selectedCardId) { mutableStateOf(false) }
    var followingLatest by remember(state.selectedCardId) { mutableStateOf(true) }
    var historyAnchorPending by remember(state.selectedCardId) { mutableStateOf(false) }
    var historyAnchorKey by remember(state.selectedCardId) { mutableStateOf<String?>(null) }
    var historyKeepLatest by remember(state.selectedCardId) { mutableStateOf(false) }
    var historyStartAtRequest by remember(state.selectedCardId) { mutableStateOf(0) }
    var historyObservedLoading by remember(state.selectedCardId) { mutableStateOf(false) }
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
    val runtime = resolvedCardRuntime(
        card?.runtime.orEmpty(),
        conversation?.status.orEmpty(),
        card?.id?.let(state.cardOperations::get),
    )
    val activeTurn = isActiveCardRuntime(runtime)
    val turnFailure = resolveConversationTurnFailure(
        messages = allMessages,
        conversationStatus = conversation?.status.orEmpty(),
        cardRuntime = card?.runtime.orEmpty(),
    )
    var presentedFailureLog by remember(card?.id, turnFailure?.log) { mutableStateOf<String?>(null) }
    var failureRetryQueued by remember(card?.id, turnFailure?.log) { mutableStateOf(false) }
    val assistantCount = messages.count { it.role.equals("assistant", true) || it.role.equals("agent", true) }
    // Keep the live cue at the transcript tail for the whole turn. Partial
    // assistant text must not make the agent appear idle while it is still
    // generating more text or running tools.
    val showAgentWorking = shouldShowAgentWorking(activeTurn, awaitingAgent)
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
        if (activeTurn || turnFailure == null || state.error != null) failureRetryQueued = false
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
    fun requestEarlierHistory(viewport: ConversationHistoryViewport) {
        if (!shouldLoadEarlierConversationHistory(
                hasMore = state.historyHasMore,
                loading = state.historyLoading,
                anchorPending = historyAnchorPending,
                initialScrollComplete = initialScrollComplete,
                viewport = viewport,
            )
        ) return
        historyAnchorPending = true
        historyObservedLoading = false
        historyKeepLatest = followingLatest && listState.isAtConversationEnd()
        historyStartAtRequest = state.historyStart
        historyAnchorKey = if (historyKeepLatest) {
            null
        } else {
            listState.layoutInfo.visibleItemsInfo
                .map { it.key.toString() }
                .firstOrNull { it.startsWith("message:") }
                ?: messages.firstOrNull()?.let { conversationMessageKey(it, 0) }
        }
        model.loadOlderMessages()
    }
    LaunchedEffect(
        listState,
        state.selectedCardId,
        state.historyHasMore,
        state.historyLoading,
        historyAnchorPending,
        initialScrollComplete,
    ) {
        snapshotFlow {
            val layout = listState.layoutInfo
            ConversationHistoryViewport(
                firstVisibleItemIndex = listState.firstVisibleItemIndex,
                canScrollBackward = listState.canScrollBackward,
                canScrollForward = listState.canScrollForward,
                hasItems = layout.totalItemsCount > 0,
            )
        }
            .distinctUntilChanged()
            .collect(::requestEarlierHistory)
    }
    LaunchedEffect(
        state.historyStart,
        state.historyLoading,
        messages.size,
        historyAnchorPending,
    ) {
        if (!historyAnchorPending) return@LaunchedEffect
        if (!state.historyHasMore && !state.historyLoading && state.historyStart == historyStartAtRequest) {
            historyAnchorPending = false
            historyAnchorKey = null
            historyObservedLoading = false
            return@LaunchedEffect
        }
        if (state.historyLoading) {
            historyObservedLoading = true
            return@LaunchedEffect
        }
        if (!historyObservedLoading && state.historyStart == historyStartAtRequest) return@LaunchedEffect
        if (state.historyStart != historyStartAtRequest) {
            delay(1)
            if (historyKeepLatest) {
                val endIndex = listState.layoutInfo.totalItemsCount - 1
                if (endIndex >= 0) listState.scrollToItem(endIndex)
                followingLatest = true
            } else if (historyAnchorKey != null) {
                val messageIndex = messages.withIndex().indexOfFirst { (index, message) ->
                    conversationMessageKey(message, index) == historyAnchorKey
                }
                if (messageIndex >= 0) {
                    val historyItems = if (state.historyHasMore || state.historyLoading) 1 else 0
                    val unsentTaskItems = if (hasUnsentDraft) 1 else 0
                    listState.scrollToItem(historyItems + unsentTaskItems + messageIndex)
                }
                followingLatest = false
            }
        } else {
            // Keep the anchor pending after a failed request. This prevents an
            // automatic retry loop; the visible history control remains a
            // manual retry path.
            return@LaunchedEffect
        }
        historyAnchorPending = false
        historyAnchorKey = null
        historyObservedLoading = false
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
        // Wait until the updated row sizes are reflected in LazyListState.
        // If new tool/model content grew below the current viewport, preserve
        // the reading position and expose the explicit jump affordance.
        withFrameNanos { }
        val historyItems = if (state.historyHasMore || state.historyLoading) 1 else 0
        val unsentTaskItems = if (hasUnsentDraft) 1 else 0
        val endIndex = historyItems + unsentTaskItems + messages.size +
            (if (showAgentWorking) 1 else 0) + queuedMessages.size
        val explicitOpenScroll = consumedScrollRequest != state.conversationScrollRequest
        val isAtLatestAfterUpdate = listState.isAtConversationEnd()
        if ((hasUnsentDraft || messages.isNotEmpty() || showAgentWorking || queuedMessages.isNotEmpty()) &&
            shouldFollowConversationUpdate(
                explicitOpenScroll = explicitOpenScroll,
                initialScrollComplete = initialScrollComplete,
                followingLatest = followingLatest,
                isAtLatestAfterUpdate = isAtLatestAfterUpdate,
            )
        ) {
            listState.scrollToItem(endIndex)
            consumedScrollRequest = state.conversationScrollRequest
            initialScrollComplete = true
            followingLatest = true
        } else if (initialScrollComplete && followingLatest && !isAtLatestAfterUpdate) {
            followingLatest = false
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
                    modifier = Modifier.fillMaxSize()
                        .alpha(if (initialScrollComplete) 1f else 0f)
                        .testTag("conversation-list"),
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
                                if (state.historyLoading) {
                                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                    Spacer(Modifier.width(8.dp))
                                    Text("Loading earlier messages…", color = DieterMuted, fontSize = 11.sp)
                                } else {
                                    Text("Load earlier messages · ${allMessages.size} of ${state.historyTotal}")
                                }
                            }
                        }
                    }
                    if (hasUnsentDraft) {
                        item(key = "unsent-agent-task") {
                            UnsentTaskMessage(unsentTask.orEmpty(), draftAttachments)
                        }
                    }
                    itemsIndexed(messages, key = { index, message -> conversationMessageKey(message, index) }) { _, message ->
                        val plan = plansByMessage[message.id]
                        val subagents = subagentsByMessage[message.id].orEmpty()
                        // animateItem eases freshly synced messages in instead
                        // of teleporting the stale transcript to the new tail.
                        Box(Modifier.animateItem()) {
                            MessageBlock(
                                message,
                                model,
                                showAgentAvatar = card?.scope == "chat",
                                showReasoningTraces = state.showReasoningTraces,
                                plan = plan,
                                subagents = subagents,
                            )
                        }
                    }
                    if (showAgentWorking) {
                        item(key = "agent-working") {
                            AgentWorkingIndicator(conversation?.pendingToolsList?.lastOrNull()?.toolName.orEmpty())
                        }
                    }
                    if (turnFailure != null) {
                        item(key = "turn-failure") {
                            TurnFailureBanner(
                                failure = turnFailure,
                                retrying = failureRetryQueued,
                                onViewLog = { presentedFailureLog = turnFailure.log },
                                onRetry = {
                                    if (!failureRetryQueued) {
                                        failureRetryQueued = true
                                        model.retryFailedTurn(turnFailure.retryParts)
                                    }
                                },
                            )
                        }
                    }
                    items(queuedMessages, key = { "queued-${it.id}" }) { queued ->
                        QueuedMessageBlock(
                            queued = queued,
                            showInterrupt = queued.id == queuedMessages.firstOrNull()?.id && activeTurn,
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
                            containerColor = DieterSurfaceHigh,
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
                    .clip(RoundedCornerShape(16.dp)).background(DieterAmberTint).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Schedule, null, tint = DieterAmber)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("Ready for review", fontWeight = FontWeight.SemiBold, color = DieterAmber)
                    Text("Send feedback or mark it done.", fontSize = 12.sp, color = DieterMuted)
                }
                Button(
                    onClick = model::markDone,
                    colors = ButtonDefaults.buttonColors(containerColor = DieterAmber, contentColor = DieterAbyss),
                ) { Text("Mark done") }
            }
        }
        if (card?.canStartFromTodo(draftAttachments.isNotEmpty()) == true) {
            StartCardBanner(
                starting = state.cardOperations[card.id] == CardOperation.STARTING,
                error = state.cardOperationErrors[card.id],
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
    presentedFailureLog?.let { log ->
        TurnFailureLogDialog(log = log, onDismiss = { presentedFailureLog = null })
    }
}

@Composable
internal fun TurnFailureBanner(
    failure: ConversationTurnFailure,
    retrying: Boolean,
    onViewLog: () -> Unit,
    onRetry: () -> Unit,
) {
    Surface(
        color = DieterSurfaceHigh.copy(alpha = 0.94f),
        shape = RoundedCornerShape(17.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.48f)),
        shadowElevation = 4.dp,
        modifier = Modifier.fillMaxWidth().testTag("turn-failure"),
    ) {
        Column(Modifier.padding(15.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "Turn failed",
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    SelectionContainer {
                        Text(
                            "Turn failed — ${failure.summary}",
                            color = MaterialTheme.colorScheme.error,
                            fontSize = 13.sp,
                            lineHeight = 18.sp,
                        )
                    }
                }
                Spacer(Modifier.width(8.dp))
                Icon(Icons.Outlined.Cancel, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Surface(color = MaterialTheme.colorScheme.error.copy(alpha = 0.13f), shape = CircleShape) {
                    Text(
                        "●  Failed",
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onViewLog, modifier = Modifier.testTag("turn-failure-view-log")) {
                    Text("View log", fontWeight = FontWeight.SemiBold)
                }
                Button(
                    onClick = onRetry,
                    enabled = !retrying && failure.retryParts.isNotEmpty(),
                    modifier = Modifier.testTag("turn-failure-retry"),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.onSurface,
                        contentColor = MaterialTheme.colorScheme.surface,
                    ),
                ) {
                    if (retrying) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                    else Icon(Icons.Outlined.Refresh, null, Modifier.size(16.dp))
                    Spacer(Modifier.width(5.dp))
                    Text(if (retrying) "Retry queued…" else "Retry turn", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
internal fun TurnFailureLogDialog(log: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Turn failure log") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Complete output captured from the local harness worker.", color = DieterMuted, fontSize = 12.sp)
                Surface(
                    color = DieterSurface,
                    shape = RoundedCornerShape(10.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
                ) {
                    SelectionContainer {
                        Text(
                            log,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                            lineHeight = 16.sp,
                            modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp)
                                .verticalScroll(rememberScrollState()).padding(12.dp)
                                .testTag("turn-failure-log"),
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        modifier = Modifier.testTag("turn-failure-log-dialog"),
    )
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
            color = DieterSurfaceHigh.copy(alpha = 0.72f),
            contentColor = DieterMuted,
            shape = RoundedCornerShape(17.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
            modifier = Modifier.widthIn(max = 340.dp).testTag("queued-message-${queued.id}"),
        ) {
            Column {
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
                if (showInterrupt) {
                    Row(
                        Modifier.fillMaxWidth().padding(start = 7.dp, end = 7.dp, bottom = 5.dp),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        TextButton(
                            onClick = onInterrupt,
                            enabled = !working,
                            modifier = Modifier
                                .heightIn(min = 30.dp)
                                .testTag("interrupt-queued-message")
                                .semantics {
                                    contentDescription = "Interrupt current turn and send this message now"
                                },
                            contentPadding = PaddingValues(horizontal = 9.dp, vertical = 0.dp),
                            colors = ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.error,
                                containerColor = MaterialTheme.colorScheme.error.copy(alpha = 0.1f),
                            ),
                        ) {
                            if (working) {
                                CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Outlined.Cancel, null, Modifier.size(14.dp))
                            }
                            Spacer(Modifier.width(5.dp))
                            Text(
                                if (working) "Interrupting…" else "Interrupt",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun UnsentTaskMessage(task: String, attachments: List<MessagePart> = emptyList()) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Surface(
            color = DieterSurfaceHigh.copy(alpha = 0.72f),
            contentColor = DieterMuted,
            shape = RoundedCornerShape(17.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
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
private fun StartCardBanner(starting: Boolean, error: String?, onStart: () -> Unit) {
    Surface(
        color = DieterShell.copy(alpha = 0.12f),
        shape = RoundedCornerShape(16.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterShell.copy(alpha = 0.34f)),
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
                    if (starting) "The daemon accepted the start request…" else "Run the saved task and move this card to Running.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                    lineHeight = 17.sp,
                )
                if (!error.isNullOrBlank()) {
                    Text(error, color = MaterialTheme.colorScheme.error, fontSize = 11.sp, lineHeight = 15.sp)
                }
            }
            Button(
                onClick = onStart,
                enabled = !starting,
                modifier = Modifier.testTag("start-card"),
                colors = ButtonDefaults.buttonColors(
                    containerColor = DieterShell,
                    contentColor = DieterAbyss,
                ),
            ) {
                if (starting) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Default.PlayArrow, null, Modifier.size(18.dp))
                }
                Spacer(Modifier.width(6.dp))
                Text(if (starting) "Starting…" else "Start card")
            }
        }
    }
}

private fun LazyListState.isAtConversationEnd(): Boolean {
    val layout = layoutInfo
    if (layout.totalItemsCount == 0) return true
    return layout.visibleItemsInfo.lastOrNull()?.index == layout.totalItemsCount - 1
}

private fun conversationMessageKey(message: UiMessage, index: Int): String =
    if (message.id.isNotBlank()) "message:${message.id}" else "message:anonymous:${message.hashCode()}:$index"

@Composable
private fun MessageBlock(
    message: UiMessage,
    model: DieterViewModel,
    showAgentAvatar: Boolean,
    showReasoningTraces: Boolean,
    plan: TaskPlan? = null,
    subagents: List<Subagent> = emptyList(),
) {
    val fromUser = message.role.equals("user", true) || message.role.equals("human", true)
    val pendingAlpha = if (model.isPendingMessage(message.id)) 0.52f else 1f
    val failed = model.isFailedOutboxItem(message.id)
    var deliveryActionsOpen by remember(message.id) { mutableStateOf(false) }
    if (fromUser) {
        Row(Modifier.fillMaxWidth().alpha(pendingAlpha), horizontalArrangement = Arrangement.End) {
            Surface(
                color = DieterShellDeep,
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
                            failed = failed,
                        ),
                        Modifier.align(Alignment.BottomEnd).offset(x = (-4).dp, y = (-4).dp)
                            .clickable(enabled = failed) { deliveryActionsOpen = true },
                    )
                    DropdownMenu(expanded = deliveryActionsOpen, onDismissRequest = { deliveryActionsOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Retry queued message") },
                            onClick = { deliveryActionsOpen = false; model.retryOutboxItem(message.id) },
                        )
                        DropdownMenuItem(
                            text = { Text("Discard queued message") },
                            onClick = { deliveryActionsOpen = false; model.discardOutboxItem(message.id) },
                        )
                    }
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
        MessageDeliveryState.FAILED -> "Send failed; tap to retry or discard"
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
    model: DieterViewModel,
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
                Surface(color = DieterSurfaceHigh, shape = RoundedCornerShape(9.dp), modifier = Modifier.fillMaxWidth()) {
                    Text(
                        block.text,
                        color = DieterMuted,
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
                SpanStyle(color = DieterShell, background = DieterSurfaceHigh, fontFamily = FontFamily.Monospace),
            )
            else -> pushStyle(SpanStyle(color = DieterShell, textDecoration = TextDecoration.Underline))
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
        color = DieterSurfaceHigh,
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)
            .border(1.dp, DieterOutline.copy(alpha = 0.55f), RoundedCornerShape(9.dp)),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(horizontal = 9.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted, modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f))
                Spacer(Modifier.width(6.dp))
                if (active) CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 1.5.dp, color = DieterShell)
                else Icon(Icons.Outlined.CheckCircle, null, tint = DieterEyes, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(7.dp))
                Text("Task progress", Modifier.weight(1f), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                Text("$completed/${tasks.size}", color = DieterMuted, fontSize = 10.sp)
            }
            if (expanded) {
                Column(Modifier.padding(start = 31.dp, end = 9.dp, bottom = 9.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (plan.explanation.isNotBlank()) Text(plan.explanation, color = DieterMuted, fontSize = 10.sp, lineHeight = 14.sp)
                    plan.phasesList.forEach { phase ->
                        if (phase.name.isNotBlank()) Text(phase.name.uppercase(), color = DieterMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
                        phase.tasksList.forEach { task ->
                            Row(verticalAlignment = Alignment.Top) {
                                when (task.status) {
                                    "in_progress" -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = DieterShell)
                                    "completed" -> Icon(Icons.Filled.Check, null, tint = DieterEyes, modifier = Modifier.size(13.dp))
                                    "blocked" -> Icon(Icons.Outlined.Cancel, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(13.dp))
                                    else -> Icon(Icons.Outlined.Schedule, null, tint = DieterMuted, modifier = Modifier.size(13.dp))
                                }
                                Spacer(Modifier.width(7.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        if (task.status == "in_progress" && task.activeForm.isNotBlank()) task.activeForm else task.content,
                                        color = if (task.status == "completed" || task.status == "abandoned") DieterMuted else MaterialTheme.colorScheme.onSurface,
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
            Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted, modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f))
            Spacer(Modifier.width(5.dp))
            Text("${subagents.size} ${if (subagents.size == 1) "subagent" else "subagents"}", color = DieterMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            if (active) {
                Spacer(Modifier.width(7.dp))
                CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.4.dp, color = DieterShell)
                Spacer(Modifier.width(4.dp))
                Text("Working", color = DieterShell, fontSize = 9.sp)
            }
        }
        if (expanded) {
            Column(Modifier.padding(start = 20.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                subagents.forEach { subagent ->
                    Surface(shape = RoundedCornerShape(8.dp), color = DieterSurfaceHigh, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(horizontal = 9.dp, vertical = 7.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (subagent.status == "running") CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.4.dp, color = DieterShell)
                                else Icon(if (subagent.status == "completed") Icons.Outlined.CheckCircle else Icons.Outlined.Cancel, null, tint = if (subagent.status == "completed") DieterEyes else DieterMuted, modifier = Modifier.size(12.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    cleanSubagentTitle(subagent.task.ifBlank { subagent.name.ifBlank { subagent.agentType } }),
                                    Modifier.weight(1f),
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(subagent.status, color = DieterMuted, fontSize = 8.sp)
                            }
                            val activity = subagent.activity.ifBlank { subagent.description }
                            if (activity.isNotBlank()) Text(activity, color = DieterMuted, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            val metrics = listOfNotNull(
                                subagent.model.takeIf(String::isNotBlank),
                                subagent.toolCount.takeIf { it > 0 }?.let { "$it tools" },
                                subagent.tokens.takeIf { it > 0 }?.let { "$it tokens" },
                                if (subagent.contextTokens > 0 && subagent.contextWindow > 0) "${(subagent.contextTokens * 100 / subagent.contextWindow)}% context" else null,
                            )
                            if (metrics.isNotEmpty()) Text(metrics.joinToString(" · "), color = DieterMuted, fontSize = 8.sp)
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
                tint = DieterMuted,
                modifier = Modifier.size(14.dp).rotate(if (expanded) 90f else 0f),
            )
            Spacer(Modifier.width(5.dp))
            Text("Reasoning", color = DieterMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            if (!expanded) {
                Spacer(Modifier.width(6.dp))
                Text(
                    text.lineSequence().firstOrNull { it.isNotBlank() }.orEmpty().replace("**", ""),
                    color = DieterMuted.copy(alpha = 0.72f),
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
                    color = DieterMuted,
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
        color = DieterSurfaceHigh,
        contentColor = DieterShell,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.size(32.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Row(
                Modifier.size(width = 17.dp, height = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Box(Modifier.width(3.dp).height(16.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
                Box(Modifier.width(3.dp).height(11.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
                Box(Modifier.width(3.dp).height(8.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
                Box(Modifier.width(3.dp).height(5.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
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
        Surface(color = DieterSurfaceHigh, shape = RoundedCornerShape(17.dp)) {
            Row(
                Modifier.padding(horizontal = 11.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    agentWorkingLabel(toolName),
                    color = DieterMuted,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                repeat(3) { index ->
                    val active = phase.toInt().coerceIn(0, 2) == index
                    Box(
                        Modifier.size(if (active) 5.dp else 4.dp)
                            .clip(CircleShape)
                            .background(DieterShell.copy(alpha = if (active) 1f else 0.35f)),
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
                    color = DieterMuted,
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
        color = DieterSurfaceHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        modifier = Modifier.widthIn(max = 340.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(38.dp).clip(RoundedCornerShape(10.dp)).background(DieterShellTint),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Description, null, tint = DieterShell, modifier = Modifier.size(19.dp))
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
                Text(attachmentDetails(part), color = DieterMuted, fontSize = 10.sp, maxLines = 1)
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
private fun ToolGroup(messageId: String, groupKey: String, parts: List<MessagePart>, model: DieterViewModel) {
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
                tint = DieterMuted,
                modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f),
            )
            Spacer(Modifier.width(5.dp))
            Text(toolGroupLabel(parts), color = DieterMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        }
        if (expanded) {
            Column(
                Modifier.fillMaxWidth().padding(start = 7.dp, top = 2.dp)
                    .drawBehind {
                        drawLine(
                            color = DieterOutline,
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
private fun ToolItem(messageId: String, part: MessagePart, model: DieterViewModel) {
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
            Icon(Icons.Outlined.Terminal, null, tint = DieterMuted, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(6.dp))
            Text(
                displayToolName(part.toolName.ifBlank { part.type }),
                color = DieterMuted,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
            )
            val preview = toolPreview(part)
            if (preview.isNotBlank()) {
                Spacer(Modifier.width(7.dp))
                Text(
                    preview,
                    modifier = Modifier.weight(1f),
                    color = DieterMuted.copy(alpha = 0.67f),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            } else Spacer(Modifier.weight(1f))
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = if (expanded) "Collapse details" else "Expand details",
                tint = DieterMuted,
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
                    Text("Loading tool details…", color = DieterMuted, fontSize = 10.sp)
                }
            }
            if (error != null) {
                Text(error.orEmpty(), Modifier.padding(start = 25.dp, bottom = 6.dp), color = MaterialTheme.colorScheme.error, fontSize = 10.sp)
            }
            if (payloadError.isNotBlank()) ToolPayloadBlock("Error", payloadError, error = true)
            if (input.isNotBlank()) ToolPayloadBlock("Input", input)
            if (output.isNotBlank()) ToolPayloadBlock("Output", output)
            if (!loading && error == null && payloadError.isBlank() && input.isBlank() && output.isBlank()) {
                Text("No additional payload", Modifier.padding(start = 25.dp, bottom = 6.dp), color = DieterMuted, fontSize = 10.sp)
            }
        }
    }
}

@Composable
private fun ToolPayloadBlock(label: String, value: String, error: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(start = 25.dp, end = 6.dp, bottom = 6.dp)) {
        Text(label, color = if (error) MaterialTheme.colorScheme.error else DieterMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(3.dp))
        Surface(
            color = MaterialTheme.colorScheme.background,
            shape = RoundedCornerShape(6.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        ) {
            SelectionContainer {
                Text(
                    value,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp).verticalScroll(rememberScrollState())
                        .padding(horizontal = 8.dp, vertical = 7.dp),
                    color = if (error) MaterialTheme.colorScheme.error else DieterMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    lineHeight = 13.sp,
                )
            }
        }
    }
}

@Composable
private fun CommentsBody(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
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
                        colors = CardDefaults.cardColors(containerColor = DieterSurfaceHigh),
                        shape = RoundedCornerShape(16.dp),
                    ) {
                        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 13.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Surface(shape = RoundedCornerShape(7.dp), color = DieterShellTint) {
                                    Text(
                                        if (state.selectedCard?.scope == "board") "BOARD COMMENT" else "CHAT NOTE",
                                        color = DieterShell,
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
                                Text(shortTimestamp(comment.createdAt, now), color = DieterMuted, fontSize = 11.sp)
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
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add attachment", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                "Choose images or browse any document on this device.",
                color = DieterMuted,
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
                color = DieterMuted.copy(alpha = 0.78f),
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
        color = DieterSurface,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Box(
                Modifier.size(42.dp).clip(RoundedCornerShape(12.dp)).background(DieterShellTint),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = DieterShell, modifier = Modifier.size(21.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(detail, color = DieterMuted, fontSize = 11.sp)
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
                .background(DieterSurfaceHigh)
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
        color = DieterSurfaceHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        modifier = Modifier.width(224.dp).height(64.dp).testTag("composer-attachment-$index"),
    ) {
        Row(
            Modifier.padding(start = 10.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(DieterShellTint),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Description, null, tint = DieterShell, modifier = Modifier.size(18.dp))
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
                Text(attachmentDetails(part), color = DieterMuted, fontSize = 10.sp, maxLines = 1)
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
                        color = DieterMuted.copy(alpha = 0.78f),
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
                color = DieterSurfaceHigh,
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
                    cursorBrush = SolidColor(DieterShell),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp, max = 144.dp).testTag("message-input"),
                    decorationBox = { innerTextField ->
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 54.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (onAttach != null) {
                                IconButton(onClick = onAttach, enabled = enabled, modifier = Modifier.size(42.dp)) {
                                    Icon(Icons.Outlined.AttachFile, "Attach images or files", tint = DieterMuted, modifier = Modifier.size(19.dp))
                                }
                            } else {
                                Spacer(Modifier.width(17.dp))
                            }
                            Box(Modifier.weight(1f).padding(end = 14.dp, top = 15.dp, bottom = 14.dp)) {
                                if (value.isEmpty()) Text(placeholder, color = DieterMuted.copy(alpha = 0.72f), fontSize = 14.sp)
                                innerTextField()
                            }
                        }
                    },
                )
            }
            val canSend = enabled && (value.isNotBlank() || attachments.isNotEmpty())
            Box(
                Modifier.size(54.dp).clip(RoundedCornerShape(20.dp))
                    .background(DieterPane)
                    .clickable(enabled = canSend) { onSend(provider, selectedModel, effort) }
                    .testTag("send-message"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    "Send",
                    tint = if (canSend) DieterAbyss else DieterAbyss.copy(alpha = 0.55f),
                    modifier = Modifier.size(23.dp),
                )
            }
        }
    }
}

@Composable
private fun ComposerSettingPill(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.height(32.dp).widthIn(max = 142.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(DieterSurfaceHigh)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 11.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = DieterMuted, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
    tokens >= 1_000_000 -> String.format(Locale.US, "%.1fM", tokens / 1_000_000.0)
    tokens >= 100_000 -> "${tokens / 1_000}k"
    tokens >= 1_000 -> String.format(Locale.US, "%.1fk", tokens / 1_000.0)
    else -> tokens.toString()
}

@Composable
private fun BoardLabelFilters(
    state: DieterUiState,
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
                shape = RoundedCornerShape(50),
                color = if (selected) DieterShellTint else Color.Transparent,
                contentColor = if (selected) MaterialTheme.colorScheme.onBackground else DieterMuted,
                border = if (selected) null else androidx.compose.foundation.BorderStroke(1.dp, DieterOutline.copy(alpha = 0.72f)),
            ) {
                Row(
                    Modifier.padding(horizontal = 13.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (labelId.isBlank() && selected) Icon(Icons.Default.Check, null, Modifier.size(15.dp), tint = DieterShell)
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
private fun LaneTabs(state: DieterUiState, model: DieterViewModel, visibleCards: List<BoardCard>) {
    val board = state.board ?: return
    val selectedIndex = board.lanesList.indexOfFirst { it.id == state.selectedLane }.coerceAtLeast(0)
    PrimaryScrollableTabRow(
        selectedTabIndex = selectedIndex,
        containerColor = MaterialTheme.colorScheme.background,
        contentColor = DieterShell,
        edgePadding = 0.dp,
        divider = { HorizontalDivider(color = DieterOutline.copy(alpha = 0.72f)) },
    ) {
        board.lanesList.forEach { lane ->
            val count = visibleCards.count { it.lane == lane.id }
            val selected = state.selectedLane == lane.id
            Tab(
                selected = selected,
                onClick = { model.selectLane(lane.id) },
                selectedContentColor = DieterShell,
                unselectedContentColor = DieterMuted,
                text = {
                    Text(
                        buildAnnotatedString {
                            pushStyle(
                                SpanStyle(
                                    color = if (selected) DieterShell else DieterMuted,
                                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                ),
                            )
                            append(lane.name)
                            pop()
                            pushStyle(SpanStyle(color = DieterMuted.copy(alpha = 0.72f)))
                            append(" $count")
                            pop()
                        },
                        fontSize = 13.sp,
                        maxLines = 1,
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
    operation: CardOperation?,
    operationError: String?,
    activityNow: Instant,
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
            .clip(RoundedCornerShape(20.dp))
            .background(DieterSurfaceHigh)
            .then(
                if (labelDropTargeted) Modifier.border(2.dp, DieterEyes, RoundedCornerShape(20.dp))
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
                containerColor = DieterSurface,
                contentColor = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.testTag("edit-card-${card.id}"),
                onClick = onEdit,
            )
            SwipeCardAction(
                label = "Move",
                icon = Icons.AutoMirrored.Outlined.DriveFileMove,
                containerColor = DieterShell.copy(alpha = 0.24f),
                contentColor = DieterShellDeep,
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
            operation = operation,
            operationError = operationError,
            activityNow = activityNow,
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
    lanes: List<com.dbpprt.dieter.v1.Lane>,
    onDismiss: () -> Unit,
    onMove: (String) -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("Move card", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(card.title.ifBlank { "Untitled conversation" }, color = DieterMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
                        Icon(Icons.Default.Check, contentDescription = null, Modifier.size(18.dp), tint = DieterEyes)
                        Spacer(Modifier.width(6.dp))
                        Text("Current", color = DieterMuted, fontSize = 12.sp)
                    } else {
                        Icon(Icons.AutoMirrored.Outlined.DriveFileMove, contentDescription = "Move to ${lane.name}", tint = DieterMuted)
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
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Edit card", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                if (taskEditable) "Update this draft before its task is sent to the agent."
                else "The task is read-only because it has already been sent to the agent.",
                color = DieterMuted,
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
    operation: CardOperation?,
    operationError: String?,
    activityNow: Instant,
    modifier: Modifier = Modifier,
    onStart: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val labels = board?.labelsList.orEmpty().filter { card.labelIdsList.contains(it.id) }
    val starting = operation == CardOperation.STARTING || card.runtime.equals("starting", ignoreCase = true)
    Card(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().then(
            if (selected) Modifier.border(1.dp, DieterShellDeep, RoundedCornerShape(20.dp)) else Modifier,
        ),
        colors = CardDefaults.cardColors(containerColor = if (selected) DieterShellTintDeep else DieterSurfaceHigh),
        shape = RoundedCornerShape(20.dp),
    ) {
        // Keep the surface opaque while an optimistic card is syncing. Fading
        // the entire card exposes the swipe actions rendered underneath it.
        Column(Modifier.alpha(if (pending) 0.52f else 1f)) {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 13.dp),
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
                    labels.firstOrNull()?.let { label ->
                        LabelPill(label.name, label.color)
                    }
                }
                if (card.summary.isNotBlank()) {
                    Text(
                        card.summary,
                        color = DieterMuted,
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (labels.size > 1) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        labels.drop(1).take(2).forEach { label -> LabelPill(label.name, label.color) }
                    }
                }
                if (!operationError.isNullOrBlank()) {
                    Text(operationError, color = MaterialTheme.colorScheme.error, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            HorizontalDivider(color = DieterOutline.copy(alpha = 0.38f))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(card.provider.ifBlank { "agent" }, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                Spacer(Modifier.width(8.dp))
                Text(card.model, color = DieterMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                val activityAge = boardCardActivityText(card.updatedAt, card.lastActivityAt, activityNow)
                if (activityAge.isNotEmpty()) {
                    Text(
                        activityAge,
                        color = DieterMuted,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.testTag("card-activity-${card.id}")
                            .semantics { contentDescription = "Last activity $activityAge" },
                    )
                    Spacer(Modifier.width(10.dp))
                }
                if (starting || onStart != null) {
                    Surface(
                        onClick = { onStart?.invoke() },
                        enabled = onStart != null && operation == null && !starting,
                        modifier = Modifier.testTag("start-card-${card.id}"),
                        shape = RoundedCornerShape(10.dp),
                        color = DieterEyes.copy(alpha = 0.16f),
                        contentColor = DieterEyes,
                    ) {
                        Row(
                            Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (starting) {
                                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Default.PlayArrow, contentDescription = null, Modifier.size(16.dp))
                            }
                            Spacer(Modifier.width(3.dp))
                            Text(if (starting) "Starting…" else "Start", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                }
                if (card.commentCount > 0) {
                    Icon(Icons.Outlined.ChatBubbleOutline, null, Modifier.size(15.dp), tint = DieterMuted)
                    Text(" ${card.commentCount}", color = DieterMuted, fontSize = 12.sp)
                    Spacer(Modifier.width(10.dp))
                }
                Icon(Icons.Outlined.CheckCircle, null, Modifier.size(18.dp), tint = if (card.lane.contains("done", true)) DieterEyes else DieterMuted)
            }
        }
    }
}

internal fun boardCardActivityText(
    updatedAt: String,
    lastActivityAt: String,
    now: Instant = Instant.now(),
): String {
    val activity = listOfNotNull(
        updatedAt.takeIf { it.isNotBlank() }?.let { runCatching { Instant.parse(it) }.getOrNull() },
        lastActivityAt.takeIf { it.isNotBlank() }?.let { runCatching { Instant.parse(it) }.getOrNull() },
    ).maxOrNull() ?: return ""
    val age = Duration.between(activity, now).coerceAtLeast(Duration.ZERO)
    return when {
        age.seconds < 60 -> "now"
        age.toMinutes() < 60 -> "${age.toMinutes()}min"
        age.toHours() < 24 -> "${age.toHours()}h"
        age.toDays() < 7 -> "${age.toDays()}d"
        else -> "${age.toDays() / 7}w"
    }
}

@Composable
private fun LabelPill(name: String, color: String) {
    val tint = runCatching { Color(color.toColorInt()) }.getOrDefault(DieterShell)
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
    val active = isActiveCardRuntime(status)
    Row(
        Modifier.clip(RoundedCornerShape(20.dp))
            .border(1.dp, DieterOutline.copy(alpha = 0.82f), RoundedCornerShape(20.dp))
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(8.dp).then(
                if (active) Modifier.clip(CircleShape).background(DieterEyes)
                else Modifier.border(1.dp, DieterMuted, CircleShape),
            ),
        )
        Spacer(Modifier.width(6.dp))
        Text(status.replaceFirstChar { it.uppercase() }, color = DieterMuted, fontSize = 11.sp)
    }
}

@Composable
private fun ConnectionEmptyState(state: DieterUiState, model: DieterViewModel) {
    if (state.desiredConnected) return
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Sync, null, Modifier.size(46.dp), tint = DieterShell)
        Spacer(Modifier.height(14.dp))
        Text("Connect to Dieter", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text("Start dieter serve on this computer and bridge the visible emulator with adb reverse tcp:4242 tcp:4242.", color = DieterMuted)
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
        Surface(shape = RoundedCornerShape(18.dp), color = DieterShellTint, modifier = Modifier.size(64.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Icon(icon, null, Modifier.size(28.dp), tint = DieterShell)
            }
        }
        Spacer(Modifier.height(16.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(body, color = DieterMuted, fontSize = 13.sp, lineHeight = 19.sp, textAlign = TextAlign.Center)
    }
}

@Composable
private fun EmptyDetail(title: String, body: String, icon: ImageVector, modifier: Modifier = Modifier) {
    EmptyList(title, body, icon, modifier)
}

@Composable
private fun HorizontalPaneDivider() {
    Box(Modifier.fillMaxHeight().width(1.dp).background(DieterOutline))
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
private fun CardLabelsDialog(state: DieterUiState, onDismiss: () -> Unit, onSave: (List<String>) -> Unit) {
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
                if (state.board?.labelsCount == 0) Text("This board has no labels yet.", color = DieterMuted)
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
