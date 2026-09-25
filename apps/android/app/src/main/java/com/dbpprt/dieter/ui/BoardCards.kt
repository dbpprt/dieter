@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.core.graphics.toColorInt
import com.dbpprt.dieter.ui.theme.DieterCoral
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellDeep
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card as BoardCard
import java.time.Duration
import java.time.Instant
import com.dbpprt.dieter.ui.theme.DieterShellTintDeep
import com.dbpprt.dieter.ui.theme.DieterShellTint

@Composable
internal fun BoardLabelFilters(
    state: DieterUiState,
    selectedLabelId: String,
    selectedMachineId: String? = null,
    onMachineSelect: (String?) -> Unit = {},
    dragState: BoardLabelDragState,
    onSelect: (String) -> Unit,
    onDrop: (cardId: String, labelId: String) -> Unit,
) {
    val board = state.board ?: return
    val allCards = state.cards.filter { it.boardId == board.id }
    val machineIds = allCards.map { it.ownerDaemonId }.distinct().sortedBy { state.machineLabel(it) }
    val boardCards = allCards.filter { selectedMachineId == null || it.ownerDaemonId == selectedMachineId }
    val haptic = LocalHapticFeedback.current
    val currentOnDrop by rememberUpdatedState(onDrop)
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (machineIds.size > 1 || selectedMachineId != null) {
            BoardMachineFilter(state, machineIds, selectedMachineId, onMachineSelect)
        }
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
                shape = RoundedCornerShape(10.dp),
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
internal fun LaneTabs(state: DieterUiState, model: DieterViewModel, visibleCards: List<BoardCard>) {
    val board = state.board ?: return
    if (board.lanesCount == 0) return
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
internal fun SwipeableWorkCard(
    card: BoardCard,
    board: Board?,
    selected: Boolean,
    pending: Boolean,
    operation: CardOperation?,
    operationError: String?,
    activityNow: Instant,
    machineName: String = "",
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
    // The action must read as enabled in every palette. A translucent shell
    // fill paired with the deeper shell tint collapses to near-identical
    // colors on dark surfaces.
    val moveContainerColor = DieterShellDeep
    val moveContentColor = listOf(
        MaterialTheme.colorScheme.onBackground,
        MaterialTheme.colorScheme.onPrimary,
    ).maxBy { colorContrastRatio(it, moveContainerColor) }

    DisposableEffect(labelDragState, card.id) {
        onDispose { labelDragState.unregisterCard(card.id) }
    }

    LaunchedEffect(revealed, revealDistance) {
        dragOffset = if (revealed) -revealDistance else 0f
    }

    Box(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(DieterSurfaceHigh)
            .then(
                if (labelDropTargeted) Modifier.border(2.dp, DieterEyes, RoundedCornerShape(12.dp))
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
                enabled = revealed,
                modifier = Modifier.testTag("edit-card-${card.id}"),
                onClick = onEdit,
            )
            SwipeCardAction(
                label = "Move",
                icon = Icons.AutoMirrored.Outlined.DriveFileMove,
                containerColor = moveContainerColor,
                contentColor = moveContentColor,
                enabled = revealed,
                modifier = Modifier.testTag("move-card-${card.id}"),
                onClick = onMove,
            )
            SwipeCardAction(
                label = "Archive",
                icon = Icons.Outlined.Archive,
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
                enabled = revealed,
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
            machineName = machineName,
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
internal fun SwipeCardAction(
    label: String,
    icon: ImageVector,
    containerColor: Color,
    contentColor: Color,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
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
internal fun MoveCardSheet(
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
internal fun EditCardSheet(
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
internal fun WorkCard(
    card: BoardCard,
    board: Board?,
    selected: Boolean,
    pending: Boolean,
    operation: CardOperation?,
    operationError: String?,
    activityNow: Instant,
    machineName: String = "",
    modifier: Modifier = Modifier,
    onStart: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val labels = board?.labelsList.orEmpty().filter { card.labelIdsList.contains(it.id) }
    val starting = operation == CardOperation.STARTING || card.runtime.equals("starting", ignoreCase = true)
    val activityAge = boardCardActivityText(card.updatedAt, card.lastActivityAt, activityNow)
    val hasStartAction = starting || onStart != null
    val isDone = card.lane.contains("done", ignoreCase = true)
    val startContentColor = MaterialTheme.colorScheme.onPrimary
    Card(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().then(
            if (selected) Modifier.border(1.dp, DieterShellDeep, RoundedCornerShape(12.dp)) else Modifier,
        ),
        colors = CardDefaults.cardColors(containerColor = if (selected) DieterShellTintDeep else DieterSurfaceHigh),
        shape = RoundedCornerShape(12.dp),
    ) {
        // Keep the surface opaque while an optimistic card is syncing. Fading
        // the entire card exposes the swipe actions rendered underneath it.
        Column(Modifier.alpha(if (pending) 0.52f else 1f)) {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                if (labels.isNotEmpty()) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        labels.take(3).forEach { LabelPill(it.name, it.color, compact = true) }
                        if (labels.size > 3) MoreLabelsPill(labels.size - 3)
                    }
                }
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        card.title.ifBlank { "Untitled conversation" },
                        Modifier.weight(1f),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        lineHeight = 20.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (activityAge.isNotEmpty()) {
                        Spacer(Modifier.width(12.dp))
                        Text(
                            activityAge,
                            color = DieterMuted,
                            fontSize = 11.sp,
                            lineHeight = 14.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(top = 2.dp)
                                .testTag("card-activity-${card.id}")
                                .semantics { contentDescription = "Last activity $activityAge" },
                        )
                    }
                }
                if (card.summary.isNotBlank()) {
                    Text(
                        card.summary,
                        color = DieterMuted,
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    MachineCardBadge(machineName.ifBlank { card.ownerDaemonId.ifBlank { "Unassigned" } }, card.id)
                    WorkspaceCardBadge(card, Modifier.widthIn(max = 160.dp))
                }
                if (!operationError.isNullOrBlank()) {
                    Text(operationError, color = MaterialTheme.colorScheme.error, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            Row(
                Modifier.fillMaxWidth()
                    .padding(start = 12.dp, end = 12.dp, bottom = 8.dp)
                    .then(if (hasStartAction) Modifier.heightIn(min = 48.dp) else Modifier),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        listOf(card.provider.ifBlank { "agent" }, card.model).filter { it.isNotBlank() }.joinToString(" · "),
                        color = DieterMuted, fontSize = 11.sp, lineHeight = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    if (card.hasTokenUsage() && card.tokenUsage.reportedMessages > 0) {
                        Text(taskTokenUsageLabel(card.tokenUsage), color = DieterMuted, fontSize = 10.sp, lineHeight = 13.sp,
                            modifier = Modifier.semantics { contentDescription = taskTokenUsageDetail(card.tokenUsage) })
                    }
                }
                if (isDone) {
                    Spacer(Modifier.width(12.dp))
                    Icon(
                        Icons.Outlined.CheckCircle,
                        contentDescription = "Done",
                        modifier = Modifier.size(18.dp),
                        tint = DieterEyes,
                    )
                }
                if (hasStartAction) {
                    Spacer(Modifier.width(12.dp))
                    Surface(
                        onClick = { onStart?.invoke() },
                        enabled = onStart != null && operation == null && !starting,
                        modifier = Modifier.heightIn(min = 48.dp)
                            .testTag("start-card-${card.id}")
                            .semantics {
                                contentDescription = "Start ${card.title.ifBlank { "card" }}"
                            },
                        shape = RoundedCornerShape(13.dp),
                        color = DieterEyes,
                        contentColor = startContentColor,
                    ) {
                        Row(
                            Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (starting) {
                                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = startContentColor)
                            } else {
                                Icon(Icons.Default.PlayArrow, contentDescription = null, Modifier.size(18.dp))
                            }
                            Spacer(Modifier.width(5.dp))
                            Text(if (starting) "Starting…" else "Start", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun WorkspaceCardBadge(card: BoardCard, modifier: Modifier = Modifier) {
    val badge = workspaceCardBadgeInfo(card) ?: return
    val tint = if (badge.conflicted) DieterCoral else DieterShell
    Surface(
        modifier = modifier
            .testTag("workspace-badge-${card.id}")
            .semantics { contentDescription = badge.accessibilityLabel },
        shape = RoundedCornerShape(6.dp),
        color = tint.copy(alpha = 0.13f),
        contentColor = tint,
    ) {
        Row(
            Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(
                Icons.Outlined.AccountTree,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
            )
            Text(
                badge.title,
                fontSize = 11.sp,
                lineHeight = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
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
internal fun LabelPill(name: String, color: String, compact: Boolean = false) {
    val tint = runCatching { Color(color.toColorInt()) }.getOrDefault(DieterShell)
    val tintContrast = colorContrastRatio(tint, DieterSurfaceHigh)
    val contentTint = if (tintContrast < 3f) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f) else tint
    val backgroundTint = if (tintContrast < 1.5f) DieterOutline.copy(alpha = 0.3f) else tint.copy(alpha = 0.18f)
    Row(
        Modifier.widthIn(max = 134.dp).clip(RoundedCornerShape(if (compact) 5.dp else 20.dp))
            .background(backgroundTint).padding(horizontal = 8.dp, vertical = if (compact) 3.dp else 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(7.dp).clip(CircleShape).background(tint).then(
                if (tintContrast < 1.5f) Modifier.border(1.dp, contentTint.copy(alpha = 0.5f), CircleShape)
                else Modifier,
            ),
        )
        Spacer(Modifier.width(5.dp))
        Text(
            name,
            color = contentTint,
            fontSize = 11.sp,
            lineHeight = 14.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

internal fun colorContrastRatio(first: Color, second: Color): Float {
    val lighter = maxOf(first.luminance(), second.luminance())
    val darker = minOf(first.luminance(), second.luminance())
    return (lighter + 0.05f) / (darker + 0.05f)
}

@Composable
internal fun MoreLabelsPill(count: Int) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = DieterOutline.copy(alpha = 0.24f),
        contentColor = DieterMuted,
    ) {
        Text(
            "+$count",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp),
        )
    }
}

@Composable
internal fun StatusPill(status: String) {
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
internal fun BoardMachineFilter(
    state: DieterUiState,
    machineIds: List<String>,
    selected: String?,
    onSelect: (String?) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Surface(
            onClick = { expanded = true },
            shape = RoundedCornerShape(10.dp),
            color = if (selected != null) DieterShellTint else Color.Transparent,
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
            modifier = Modifier.testTag("board-machine-filter"),
        ) {
            Row(Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Computer, null, Modifier.size(15.dp), tint = DieterMuted)
                Text(selected?.let(state::machineLabel) ?: "All machines", fontSize = 13.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 140.dp))
                Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.size(15.dp), tint = DieterMuted)
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            (listOf<String?>(null) + machineIds).forEach { id ->
                DropdownMenuItem(
                    text = { Text(id?.let(state::machineLabel) ?: "All machines", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    trailingIcon = { if (selected == id) Icon(Icons.Default.Check, "Selected", Modifier.size(16.dp)) },
                    onClick = { expanded = false; onSelect(id) },
                    modifier = Modifier.testTag("board-machine-${id ?: "all"}"),
                )
            }
        }
    }
}

@Composable
private fun MachineCardBadge(name: String, cardId: String) {
    Surface(
        color = DieterOutline.copy(alpha = 0.3f),
        contentColor = DieterMuted,
        shape = RoundedCornerShape(6.dp),
        modifier = Modifier.widthIn(max = 160.dp).testTag("machine-badge-$cardId")
            .semantics(mergeDescendants = true) { contentDescription = "Machine $name" },
    ) {
        Row(Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Computer, null, Modifier.size(14.dp))
            Text(name, fontSize = 11.sp, lineHeight = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
