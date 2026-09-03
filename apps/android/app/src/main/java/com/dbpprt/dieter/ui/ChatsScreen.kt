@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellDeep
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterPane
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Card as BoardCard
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.ui.theme.DieterShellTint
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
internal fun ChatsList(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    var expandedProjects by remember { mutableStateOf(emptySet<String>()) }
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
    LaunchedEffect(state.chats, state.pinnedChatOrder) {
        if (state.pinnedChatOrder.isEmpty()) {
            model.initializePinnedChatOrderIfNeeded(state.chats.filter { it.pinned }.map { it.id })
        }
    }
    Box(modifier) {
        Column(Modifier.fillMaxSize()) {
            SimpleScreenHeader("Chats") {
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
    modifier: Modifier = Modifier,
    dropTarget: Boolean = false,
    dragged: Boolean = false,
    dragHandleModifier: Modifier = Modifier,
) {
    var actionsOpen by remember(chat.id) { mutableStateOf(false) }
    var renameOpen by remember(chat.id) { mutableStateOf(false) }
    var renameText by remember(chat.id, chat.title) { mutableStateOf(chat.title) }
    Surface(
        color = if (chat.pinned) DieterSurface else Color.Transparent,
        shape = RoundedCornerShape(16.dp),
        border = if (dropTarget) androidx.compose.foundation.BorderStroke(2.dp, DieterShellDeep) else null,
        shadowElevation = if (dragged) 8.dp else 0.dp,
        modifier = modifier.fillMaxWidth().padding(vertical = 2.dp)
            .alpha(if (model.isPendingCard(chat.id)) 0.52f else 1f)
            .testTag("chat-${chat.id}")
            .semantics {
                contentDescription = buildString {
                    append(chat.title.ifBlank { "Untitled chat" })
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
                Spacer(Modifier.width(if (chat.pinned) 12.dp else 8.dp))
                Text(shortTimestamp(chat.lastActivityAt.ifBlank { chat.updatedAt }), color = DieterMuted, fontSize = 11.sp)
                if (chat.pinned) {
                    Spacer(Modifier.width(8.dp))
                    Icon(
                        Icons.Outlined.DragHandle,
                        contentDescription = "Drag pinned chat to reorder",
                        tint = DieterMuted,
                        modifier = dragHandleModifier.size(32.dp).padding(6.dp),
                    )
                }
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
