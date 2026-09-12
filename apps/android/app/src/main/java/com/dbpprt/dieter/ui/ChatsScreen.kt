@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.DragHandle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.dbpprt.dieter.connection.isActiveRuntime
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellDeep
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterPane
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterRunning
import com.dbpprt.dieter.v1.Card as BoardCard
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.ui.theme.DieterAbyss

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
        ResizableHorizontalSplitPane(
            dividerTag = "chats-pane-divider",
            modifier = Modifier.fillMaxSize().padding(contentPadding),
            leading = { paneModifier -> ChatsList(state, model, paneModifier) },
        ) { paneModifier ->
            if (state.selectedCardId == null) {
                EmptyDetail("Select a chat", "Open a durable conversation or start a new one.", Icons.Outlined.ChatBubbleOutline, paneModifier)
            } else {
                CardDetailScreen(state, model, paneModifier, showBack = false)
            }
        }
    } else {
        ChatsList(state, model, Modifier.fillMaxSize().padding(contentPadding))
    }
}

@Composable
internal fun ChatsList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    val pinnedChatDragState = remember { PinnedChatDragState() }
    val haptic = LocalHapticFeedback.current
    val chats = remember(state.chats, query) {
        state.chats
            .filter { query.isBlank() || it.title.contains(query, ignoreCase = true) }
            .sortedWith(compareByDescending<BoardCard> { it.pinned }.thenByDescending { it.lastActivityAt })
    }
    val pinned = remember(chats, state.pinnedChatOrder) {
        orderedPinnedChats(chats.filter { it.pinned }, state.pinnedChatOrder)
    }
    val unpinnedByProject = remember(chats) { chats.filterNot { it.pinned }.groupBy(BoardCard::getProjectId) }
    val chatProjects = remember(state.projects, chats, query) { chatProjectsForQuery(state.projects, chats, query) }
    val projectIds = remember(state.projects) { state.projects.mapTo(hashSetOf(), Project::getId) }
    val otherChats = remember(chats, projectIds) {
        chats.filter { chat -> !chat.pinned && chat.projectId !in projectIds }
    }
    val projectLabels = remember(state.projects, state.presentedProjectHosts) {
        val showHosts = state.presentedProjectHosts.values.map { it.daemonId }.distinct().size > 1
        state.projects.associate { project ->
            project.id to buildString {
                append(project.name.ifBlank { "Project" })
                if (showHosts) state.presentedProjectHosts[project.id]?.hostname?.let { append(" · ").append(it) }
            }
        }
    }
    LaunchedEffect(state.chats, state.pinnedChatOrder) {
        if (state.pinnedChatOrder.isEmpty()) {
            model.initializePinnedChatOrderIfNeeded(state.chats.filter { it.pinned }.map { it.id })
        }
    }
    Box(modifier) {
        Column(Modifier.fillMaxSize()) {
            SimpleScreenHeader(
                "All chats",
                "${state.chats.size} ${if (state.chats.size == 1) "conversation" else "conversations"} · " +
                    "${state.projects.size} ${if (state.projects.size == 1) "project" else "projects"}",
            ) {
                IconButton(onClick = { model.openSurface(AppSurface.APP_SETTINGS) }) {
                    Icon(Icons.Outlined.Settings, "App settings", tint = DieterMuted)
                }
            }
            SurfaceErrorBanner(state.error, model::clearError)
            CompactSearchField(query, { query = it }, "Search chats")
            if (!state.connected && state.projects.isEmpty()) {
                ConnectionEmptyState(state, model)
            } else if (chats.isEmpty() && state.projects.isEmpty()) {
                EmptyList("No chats yet", "Start a standalone conversation with a local agent.", Icons.Outlined.ChatBubbleOutline)
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 96.dp),
                ) {
                    if (pinned.isNotEmpty()) {
                        item { ListSectionLabel("Pinned") }
                        items(pinned, key = { it.id }) { chat ->
                            val dragged = pinnedChatDragState.chatId == chat.id
                            var dragHandleOriginInRoot by remember(chat.id) { mutableStateOf(Offset.Zero) }
                            DisposableEffect(pinnedChatDragState, chat.id) {
                                onDispose { pinnedChatDragState.unregister(chat.id) }
                            }
                            ChatRow(
                                chat = chat,
                                model = model,
                                projectLabel = projectLabels[chat.projectId] ?: "Project unavailable",
                                dropTarget = pinnedChatDragState.targetChatId == chat.id,
                                dragged = dragged,
                                modifier = Modifier
                                    .onGloballyPositioned {
                                        pinnedChatDragState.register(chat.id, it.boundsInRoot())
                                    }
                                    .offset { IntOffset(0, if (dragged) pinnedChatDragState.offsetY.toInt() else 0) }
                                    .zIndex(if (dragged) 2f else 0f),
                                dragHandleModifier = Modifier
                                    .onGloballyPositioned { dragHandleOriginInRoot = it.positionInRoot() }
                                    .pointerInput(chat.id, pinnedChatDragState) {
                                        detectDragGesturesAfterLongPress(
                                            onDragStart = { offset ->
                                                pinnedChatDragState.start(chat.id, dragHandleOriginInRoot + offset)
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            },
                                            onDrag = { change, dragAmount ->
                                                change.consume()
                                                pinnedChatDragState.moveBy(dragAmount)
                                            },
                                            onDragEnd = {
                                                pinnedChatDragState.finish()?.let { (chatId, targetChatId) ->
                                                    model.movePinnedChat(chatId, targetChatId)
                                                }
                                            },
                                            onDragCancel = pinnedChatDragState::reset,
                                        )
                                    },
                            )
                        }
                    }
                    chatProjects.forEach { project ->
                        val projectChats = unpinnedByProject[project.id].orEmpty()
                        val collapsed = project.id in state.collapsedChatProjectIds
                        val expanded = project.id in state.expandedChatProjectIds
                        val visibleProjectChats = if (expanded) projectChats else projectChats.take(PROJECT_CHAT_PREVIEW_COUNT)
                        item(key = "project-chat-header-${project.id}") {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                IconButton(
                                    onClick = { model.toggleChatProjectCollapsed(project.id) },
                                    modifier = Modifier.size(36.dp).testTag("project-chat-toggle-${project.id}")
                                        .semantics { stateDescription = if (collapsed) "Collapsed" else "Expanded" },
                                ) {
                                    Icon(
                                        Icons.Outlined.KeyboardArrowDown,
                                        if (collapsed) "Expand ${project.name} chats" else "Collapse ${project.name} chats",
                                        tint = DieterMuted,
                                        modifier = Modifier.size(18.dp).rotate(if (collapsed) -90f else 0f),
                                    )
                                }
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
                        if (!collapsed) {
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
                                items(visibleProjectChats, key = { it.id }) { chat ->
                                    ChatRow(chat, model, projectLabels[chat.projectId] ?: project.name)
                                }
                                if (projectChats.size > PROJECT_CHAT_PREVIEW_COUNT) {
                                    item(key = "project-chat-more-${project.id}") {
                                        TextButton(
                                            onClick = { model.toggleChatProjectExpanded(project.id) },
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
                    }
                    items(otherChats, key = { it.id }) { chat ->
                        ChatRow(chat, model, projectLabels[chat.projectId] ?: "Project unavailable")
                    }
                }
            }
        }
        ExtendedFloatingActionButton(
            onClick = { model.openSurface(AppSurface.NEW_CHAT) },
            icon = { Icon(Icons.Default.Add, null) },
            text = { Text("New chat", fontWeight = FontWeight.SemiBold) },
            modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).height(52.dp).testTag("new-chat"),
            containerColor = DieterPane,
            contentColor = DieterAbyss,
            shape = RoundedCornerShape(50),
        )
    }
}

@Composable
internal fun ChatRow(
    chat: BoardCard,
    model: DieterViewModel,
    projectLabel: String,
    modifier: Modifier = Modifier,
    dropTarget: Boolean = false,
    dragged: Boolean = false,
    dragHandleModifier: Modifier = Modifier,
) {
    var actionsOpen by remember(chat.id) { mutableStateOf(false) }
    var renameOpen by remember(chat.id) { mutableStateOf(false) }
    var renameText by remember(chat.id, chat.title) { mutableStateOf(chat.title) }
    val running = isActiveRuntime(chat.runtime)
    Surface(
        color = when {
            chat.pinned -> DieterSurface
            running -> DieterRunning.copy(alpha = 0.045f)
            else -> Color.Transparent
        },
        shape = RoundedCornerShape(16.dp),
        border = when {
            dropTarget -> androidx.compose.foundation.BorderStroke(2.dp, DieterShellDeep)
            running -> androidx.compose.foundation.BorderStroke(1.dp, DieterRunning.copy(alpha = 0.28f))
            else -> null
        },
        shadowElevation = when {
            dragged -> 8.dp
            running -> 1.dp
            else -> 0.dp
        },
        modifier = modifier.fillMaxWidth().padding(vertical = 2.dp)
            .alpha(if (model.isPendingCard(chat.id)) 0.52f else 1f)
            .testTag("chat-${chat.id}")
            .semantics {
                contentDescription = buildString {
                    append(chat.title.ifBlank { "Untitled chat" })
                    append("; project ").append(projectLabel)
                    append(if (running) "; running" else "; not running")
                    append("; long press for actions")
                    if (chat.pinned) append("; use the drag handle to reorder")
                }
            },
    ) {
        Box {
            Row(
                Modifier.fillMaxWidth()
                    .combinedClickable(
                        onClick = { model.openCard(chat, Destination.CHATS) },
                        onLongClick = { actionsOpen = true },
                    )
                    .padding(horizontal = 12.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ChatRowContent(chat, running, projectLabel, dragHandleModifier)
            }
            DropdownMenu(expanded = actionsOpen, onDismissRequest = { actionsOpen = false }) {
                DropdownMenuItem(
                    text = { Text(if (chat.pinned) "Unpin" else "Pin") },
                    leadingIcon = { Icon(Icons.Outlined.PushPin, null) },
                    modifier = Modifier.testTag("chat-pin-${chat.id}"),
                    onClick = { actionsOpen = false; model.togglePin(chat) },
                )
                DropdownMenuItem(
                    text = { Text("Rename") },
                    leadingIcon = { Icon(Icons.Outlined.Edit, null) },
                    modifier = Modifier.testTag("chat-rename-${chat.id}"),
                    onClick = {
                        actionsOpen = false
                        renameText = chat.title
                        renameOpen = true
                    },
                )
                DropdownMenuItem(
                    text = { Text("Archive") },
                    leadingIcon = { Icon(Icons.Outlined.Archive, null) },
                    modifier = Modifier.testTag("chat-archive-${chat.id}"),
                    onClick = { actionsOpen = false; model.archiveChat(chat) },
                )
            }
        }
    }
    if (renameOpen) {
        AlertDialog(
            onDismissRequest = { renameOpen = false },
            title = { Text("Rename chat") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    label = { Text("Title") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("chat-rename-title-${chat.id}"),
                )
            },
            dismissButton = { TextButton(onClick = { renameOpen = false }) { Text("Cancel") } },
            confirmButton = {
                TextButton(
                    enabled = renameText.isNotBlank(),
                    modifier = Modifier.testTag("chat-rename-confirm-${chat.id}"),
                    onClick = {
                        model.renameChat(chat, renameText.trim())
                        renameOpen = false
                    },
                ) { Text("Rename") }
            },
        )
    }
}

@Composable
internal fun RowScope.ChatRowContent(
    chat: BoardCard,
    running: Boolean,
    projectLabel: String,
    dragHandleModifier: Modifier = Modifier,
) {
    Column(Modifier.weight(1f)) {
        Text(
            chat.title.ifBlank { "Untitled chat" },
            fontSize = 15.sp,
            lineHeight = 19.sp,
            fontWeight = if (running) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.testTag("chat-title-${chat.id}"),
        )
        Spacer(Modifier.height(5.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (chat.pinned) {
                Icon(
                    Icons.Outlined.PushPin,
                    contentDescription = null,
                    tint = DieterMuted,
                    modifier = Modifier.size(12.dp).testTag("chat-pinned-indicator-${chat.id}"),
                )
                Spacer(Modifier.width(4.dp))
            }
            Text(
                projectLabel,
                color = DieterShell,
                fontSize = 10.sp,
                lineHeight = 12.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false).testTag("chat-project-${chat.id}"),
            )
            Text(" · ${shortTimestamp(chat.lastActivityAt.ifBlank { chat.updatedAt })}", color = DieterMuted, fontSize = 10.sp)
        }
        Spacer(Modifier.height(6.dp))
        ChatRuntimeStatus(
            running = running,
            modifier = Modifier.testTag("chat-runtime-${chat.id}"),
        )
    }
    if (chat.pinned) {
        Spacer(Modifier.width(6.dp))
        Icon(
            Icons.Outlined.DragHandle,
            contentDescription = "Drag pinned chat to reorder",
            tint = DieterMuted,
            modifier = dragHandleModifier.size(28.dp).padding(5.dp),
        )
    }
}

@Composable
internal fun ChatRuntimeStatus(
    running: Boolean,
    modifier: Modifier = Modifier,
) {
    val status = if (running) "Running" else "Not running"
    val transition = if (running) rememberInfiniteTransition(label = "chat-running") else null
    val rotation = transition?.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(1_450, easing = LinearEasing)),
        label = "chat-running-orbit",
    )?.value ?: 0f
    val glow = transition?.animateFloat(
        initialValue = 0.42f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            tween(680, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "chat-running-glow",
    )?.value ?: 0f

    Box(
        modifier.semantics(mergeDescendants = true) {
            contentDescription = "Chat is ${status.lowercase()}"
            stateDescription = status
        },
    ) {
        if (running) {
            Surface(
                color = DieterRunning.copy(alpha = 0.09f + glow * 0.025f),
                contentColor = DieterRunning,
                border = androidx.compose.foundation.BorderStroke(1.dp, DieterRunning.copy(alpha = 0.2f + glow * 0.16f)),
                shape = RoundedCornerShape(50),
            ) {
                Row(
                    Modifier.padding(start = 5.dp, end = 8.dp, top = 3.dp, bottom = 3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Canvas(Modifier.size(18.dp)) {
                        val strokeWidth = 1.7.dp.toPx()
                        drawCircle(DieterRunning.copy(alpha = 0.16f), style = Stroke(strokeWidth))
                        rotate(rotation) {
                            drawArc(
                                color = DieterRunning.copy(alpha = 0.55f + glow * 0.45f),
                                startAngle = -90f,
                                sweepAngle = 112f,
                                useCenter = false,
                                style = Stroke(strokeWidth, cap = StrokeCap.Round),
                            )
                        }
                        drawCircle(DieterRunning.copy(alpha = 0.2f + glow * 0.15f), radius = 4.dp.toPx())
                        drawCircle(DieterRunning, radius = 2.2.dp.toPx())
                    }
                    Spacer(Modifier.width(4.dp))
                    Text("Running", fontSize = 10.sp, lineHeight = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(7.dp).background(DieterMuted.copy(alpha = 0.12f), CircleShape)
                        .border(1.dp, DieterMuted.copy(alpha = 0.82f), CircleShape),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    status,
                    color = DieterMuted,
                    fontSize = 10.sp,
                    lineHeight = 12.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}

@Composable
internal fun ListSectionLabel(value: String, modifier: Modifier = Modifier) {
    Text(
        value.uppercase(),
        color = DieterMuted,
        fontSize = 10.sp,
        letterSpacing = 1.2.sp,
        modifier = modifier.padding(start = 8.dp, top = 10.dp, bottom = 3.dp),
    )
}

@Composable
internal fun SimpleScreenHeader(
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
internal fun CompactSearchField(value: String, onValueChange: (String) -> Unit, placeholder: String) {
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
