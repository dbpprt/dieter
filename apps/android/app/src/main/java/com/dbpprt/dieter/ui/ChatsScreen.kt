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
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Workspaces
import androidx.compose.material.icons.outlined.FolderOpen
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
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
import com.dbpprt.dieter.settings.NavigationFolderPreferences
import com.dbpprt.dieter.settings.NavigationFolderScope
import androidx.compose.material.icons.outlined.Folder
import com.dbpprt.dieter.connection.isActiveRuntime
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellDeep
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterDivider
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
    if (LocalTabletWorkspace.current && expanded) {
        TabletListDetail(
            modifier = Modifier.padding(contentPadding),
            dividerTag = "tablet-chats-pane-divider",
            initialLeadingFraction = state.chatsPaneLeadingFraction,
            onLeadingFractionCommitted = model::setChatsPaneLeadingFraction,
            list = { ChatsList(state, model, it) },
            detail = {
                if (state.selectedCardId == null) EmptyDetail("Select a chat", "Open a conversation or start a new one.", Icons.Outlined.ChatBubbleOutline, it)
                else CardDetailScreen(state, model, it, showBack = false)
            },
        )
    } else if (expanded) {
        ResizableHorizontalSplitPane(
            dividerTag = "chats-pane-divider",
            modifier = Modifier.fillMaxSize().padding(contentPadding),
            initialLeadingFraction = state.chatsPaneLeadingFraction,
            onLeadingFractionCommitted = model::setChatsPaneLeadingFraction,
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
    var query by rememberSaveable { mutableStateOf("") }
    val pinnedChatDragState = remember { PinnedChatDragState() }
    val haptic = LocalHapticFeedback.current
    val searchTerm = query.trim()
    val chats = remember(state.chats, state.projects, state.chatFolders, searchTerm) {
        chatsForQuery(state.chats, state.projects, state.chatFolders, searchTerm)
            .sortedWith(compareByDescending<BoardCard> { it.pinned }.thenByDescending { it.lastActivityAt })
    }
    val pinned = remember(chats, state.pinnedChatOrder) {
        orderedPinnedChats(chats.filter { it.pinned }, state.pinnedChatOrder)
    }
    val filedIDs = remember(state.chatFolders) { state.chatFolders.folders.flatMap { it.itemIDs }.toSet() }
    val unfiledChats = remember(chats, filedIDs) { chats.filterNot { it.id in filedIDs } }
    val unpinnedByProject = remember(unfiledChats) { unfiledChats.filterNot { it.pinned }.groupBy(BoardCard::getProjectId) }
    val chatProjects = remember(state.projects, unfiledChats, searchTerm, state.chatFolders) {
        chatProjectsForQuery(state.projects, unfiledChats, searchTerm).filter {
            state.chatFolders.folders.isEmpty() || unpinnedByProject[it.id].orEmpty().isNotEmpty()
        }
    }
    val visibleFolders = remember(state.chatFolders, chats, searchTerm) {
        val matchingIDs = chats.mapTo(hashSetOf()) { it.id }
        state.chatFolders.folders.filter { folder ->
            searchTerm.isBlank() || folder.name.contains(searchTerm, ignoreCase = true) || folder.itemIDs.any { it in matchingIDs }
        }
    }
    val chatsByID = remember(chats) { chats.associateBy { it.id } }
    val projectIds = remember(state.projects) { state.projects.mapTo(hashSetOf(), Project::getId) }
    val otherChats = remember(unfiledChats, projectIds) {
        unfiledChats.filter { chat -> !chat.pinned && chat.projectId !in projectIds }
    }
    val projectLabels = remember(state.projects) {
        state.projects.associate { it.id to it.name.ifBlank { "Project" } }
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
                NewNavigationFolderButton(NavigationFolderScope.CHATS, state.chatFolders, model.navigationFolders)
                IconButton(onClick = { model.openSurface(AppSurface.APP_SETTINGS) }) {
                    Icon(Icons.Outlined.Settings, "App settings", tint = DieterMuted)
                }
            }
            NavigationSyncStatus(state)
            SurfaceErrorBanner(state.error, model::clearError)
            CompactSearchField(query, { query = it }, "Search chats, projects, folders", clearable = true)
            if (!state.connected && state.projects.isEmpty() && state.chatFolders.folders.isEmpty()) {
                ConnectionEmptyState(state, model)
            } else if (state.chats.isEmpty() && state.projects.isEmpty() && state.chatFolders.folders.isEmpty()) {
                EmptyList("No chats yet", "Start a standalone conversation with a local agent.", Icons.Outlined.ChatBubbleOutline)
            } else if (searchTerm.isNotEmpty() && chats.isEmpty() && chatProjects.isEmpty() && visibleFolders.isEmpty()) {
                EmptyList("No matching chats", "Try a chat title, project, or folder name.", Icons.Outlined.Search)
            } else {
                LazyColumn(
                    modifier = Modifier.testTag("chats-list"),
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 96.dp),
                ) {
                    if (pinned.isNotEmpty()) {
                        item(key = "pinned-heading") { ChatSectionHeading("Pinned", Icons.Outlined.PushPin, pinned.size, DieterAmber) }
                        items(pinned, key = { "pinned-${it.id}" }) { chat ->
                            val dragged = pinnedChatDragState.chatId == chat.id
                            var dragHandleOriginInRoot by remember(chat.id) { mutableStateOf(Offset.Zero) }
                            DisposableEffect(pinnedChatDragState, chat.id) {
                                onDispose { pinnedChatDragState.unregister(chat.id) }
                            }
                            ChatRow(
                                chat = chat,
                                model = model,
                                folderPreferences = state.chatFolders,
                                showPinnedDragHandle = true,
                                folderLabel = state.chatFolders.folderContaining(chat.id)?.name,
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
                    if (visibleFolders.isNotEmpty()) {
                        item(key = "folders-heading") { ChatSectionHeading("Folders", Icons.Outlined.FolderOpen, visibleFolders.size, DieterAmber) }
                    }
                    visibleFolders.forEach { folder ->
                        val members = folder.itemIDs.mapNotNull(chatsByID::get)
                        if (searchTerm.isBlank() || members.isNotEmpty() || folder.name.contains(searchTerm, ignoreCase = true)) {
                            item(key = "chat-folder-${folder.id}") {
                                NavigationFolderHeader(folder, members.size, NavigationFolderScope.CHATS,
                                    state.chatFolders, model.navigationFolders, revealSearchResults = searchTerm.isNotBlank())
                            }
                            if (folder.isExpanded || searchTerm.isNotBlank()) {
                                if (members.isEmpty()) item(key = "chat-folder-empty-${folder.id}") {
                                    Text("No chats in this folder", color = DieterMuted,
                                        modifier = Modifier.chatGroupRail(DieterAmber.copy(alpha = 0.3f)).padding(12.dp))
                                }
                                items(members, key = { "folder-${folder.id}-${it.id}" }) { chat ->
                                    ChatRow(chat, model, projectLabels[chat.projectId] ?: "Project unavailable",
                                        modifier = Modifier.chatGroupRail(DieterAmber.copy(alpha = 0.3f)), folderPreferences = state.chatFolders)
                                }
                            }
                        }
                    }
                    if (chatProjects.isNotEmpty()) {
                        item(key = "projects-heading") { ChatSectionHeading("Projects", Icons.Outlined.Workspaces, chatProjects.size) }
                    }
                    chatProjects.forEach { project ->
                        val projectChats = unpinnedByProject[project.id].orEmpty()
                        val collapsed = searchTerm.isBlank() && project.id in state.collapsedChatProjectIds
                        val expanded = searchTerm.isNotBlank() || project.id in state.expandedChatProjectIds
                        val visibleProjectChats = if (expanded) projectChats else projectChats.take(PROJECT_CHAT_PREVIEW_COUNT)
                        item(key = "project-chat-header-${project.id}") {
                            ChatProjectHeader(
                                project, projectChats.size, collapsed,
                                onToggle = { model.toggleChatProjectCollapsed(project.id) },
                                onNewChat = { model.selectProject(project.id); model.openSurface(AppSurface.NEW_CHAT) },
                            )
                        }
                        if (!collapsed) {
                            if (projectChats.isEmpty() && searchTerm.isBlank()) {
                                item(key = "project-chat-empty-${project.id}") {
                                    Text(
                                        "No chats yet",
                                        color = DieterMuted,
                                        fontSize = 12.sp,
                                        modifier = Modifier.fillMaxWidth().chatGroupRail(DieterDivider).padding(12.dp),
                                    )
                                }
                            } else {
                                items(visibleProjectChats, key = { it.id }) { chat ->
                                    ChatRow(chat, model, projectLabels[chat.projectId] ?: project.name,
                                        modifier = Modifier.chatGroupRail(DieterDivider), showProjectLabel = false,
                                        folderPreferences = state.chatFolders)
                                }
                                if (searchTerm.isBlank() && projectChats.size > PROJECT_CHAT_PREVIEW_COUNT) {
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
                    if (otherChats.isNotEmpty()) {
                        item(key = "other-heading") { ChatSectionHeading("Other chats", Icons.Outlined.ChatBubbleOutline, otherChats.size) }
                    }
                    items(otherChats, key = { it.id }) { chat ->
                        ChatRow(chat, model, projectLabels[chat.projectId] ?: "Project unavailable", folderPreferences = state.chatFolders)
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
    folderPreferences: NavigationFolderPreferences = NavigationFolderPreferences(),
    showPinnedDragHandle: Boolean = false,
    showProjectLabel: Boolean = true,
    folderLabel: String? = null,
) {
    var moveOpen by remember(chat.id) { mutableStateOf(false) }
    var actionsOpen by remember(chat.id) { mutableStateOf(false) }
    var renameOpen by remember(chat.id) { mutableStateOf(false) }
    var renameText by remember(chat.id, chat.title) { mutableStateOf(chat.title) }
    val running = isActiveRuntime(chat.runtime)
    Surface(
        color = when {
            chat.pinned && showPinnedDragHandle -> DieterSurface
            running -> DieterRunning.copy(alpha = 0.045f)
            else -> Color.Transparent
        },
        shape = RoundedCornerShape(16.dp),
        border = when {
            dropTarget -> androidx.compose.foundation.BorderStroke(2.dp, DieterShellDeep)
            chat.pinned && showPinnedDragHandle -> androidx.compose.foundation.BorderStroke(1.dp, DieterAmber.copy(alpha = 0.22f))
            else -> null
        },
        shadowElevation = when {
            dragged -> 8.dp
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
                    if (chat.pinned && showPinnedDragHandle) append("; use the drag handle to reorder")
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
                    .padding(start = 12.dp, end = 0.dp, top = 11.dp, bottom = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val host = model.state.value.conversationHost(chat)?.hostname ?: chat.ownerDaemonId
                ChatRowContent(
                    chat, running, projectLabel, dragHandleModifier, showPinnedDragHandle,
                    hostLabel = host, showProjectLabel = showProjectLabel, folderLabel = folderLabel,
                )
                IconButton(onClick = { actionsOpen = true }, modifier = Modifier.size(48.dp).testTag("chat-actions-${chat.id}")) {
                    Icon(Icons.Outlined.MoreVert, "Actions for ${chat.title.ifBlank { "Untitled chat" }}",
                        tint = DieterMuted, modifier = Modifier.size(18.dp))
                }
            }
            DropdownMenu(expanded = actionsOpen, onDismissRequest = { actionsOpen = false }) {
                DropdownMenuItem(
                    text = { Text("Move to folder") },
                    leadingIcon = { Icon(Icons.Outlined.Folder, null) },
                    modifier = Modifier.testTag("chat-folder-${chat.id}"),
                    onClick = { actionsOpen = false; moveOpen = true },
                )
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
                    onClick = { actionsOpen = false; model.archiveConversation(chat) },
                )
            }
        }
    }
    if (moveOpen) MoveToNavigationFolderDialog(chat.id, NavigationFolderScope.CHATS,
        folderPreferences, model.navigationFolders, onDismiss = { moveOpen = false })
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
                        model.renameConversation(chat, renameText.trim())
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
    showPinnedDragHandle: Boolean = true,
    hostLabel: String = "",
    showProjectLabel: Boolean = true,
    folderLabel: String? = null,
) {
    Column(Modifier.weight(1f)) {
        Text(
            chat.title.ifBlank { "Untitled chat" },
            fontSize = 15.sp,
            lineHeight = 19.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.testTag("chat-title-${chat.id}"),
        )
        Spacer(Modifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (chat.pinned && !showPinnedDragHandle) {
                Icon(Icons.Outlined.PushPin, "Pinned chat", tint = DieterAmber,
                    modifier = Modifier.size(12.dp).testTag("chat-pinned-indicator-${chat.id}"))
                Spacer(Modifier.width(4.dp))
            }
            val context = listOfNotNull(projectLabel.takeIf { showProjectLabel }, hostLabel.takeIf { it.isNotBlank() })
                .joinToString(" · ")
            if (context.isNotEmpty()) {
                Text(context, color = DieterMuted, fontSize = 11.sp, lineHeight = 14.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false).testTag("chat-project-${chat.id}"))
                Text(" · ", color = DieterMuted, fontSize = 11.sp)
            }
            Text(shortTimestamp(chat.lastActivityAt.ifBlank { chat.updatedAt }), color = DieterMuted, fontSize = 11.sp)
        }
        if (running || folderLabel != null) {
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (running) ChatRuntimeStatus(true, Modifier.testTag("chat-runtime-${chat.id}"))
                if (folderLabel != null) {
                    if (running) Spacer(Modifier.width(8.dp))
                    Icon(Icons.Outlined.Folder, null, tint = DieterAmber, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(folderLabel, color = DieterMuted, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
    if (chat.pinned && showPinnedDragHandle) {
        Spacer(Modifier.width(6.dp))
        Icon(
            Icons.Outlined.DragHandle,
            contentDescription = "Drag pinned chat to reorder",
            tint = DieterMuted,
            modifier = dragHandleModifier.size(48.dp).padding(14.dp),
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
    )
    val glow = transition?.animateFloat(
        initialValue = 0.42f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            tween(680, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "chat-running-glow",
    )

    Box(
        modifier.semantics(mergeDescendants = true) {
            contentDescription = "Chat is ${status.lowercase()}"
            stateDescription = status
        },
    ) {
        if (running) {
            Surface(
                color = Color.Transparent,
                contentColor = DieterRunning,
                shape = RoundedCornerShape(50),
                // Observe animation values while drawing. Reading them during
                // composition rebuilt the entire badge, including text/layout,
                // on every display frame for every mounted running chat.
                modifier = Modifier.drawBehind {
                    val pulse = glow?.value ?: 0f
                    drawRoundRect(
                        color = DieterRunning.copy(alpha = 0.09f + pulse * 0.025f),
                        cornerRadius = CornerRadius(size.height / 2),
                    )
                    val stroke = 1.dp.toPx()
                    drawRoundRect(
                        color = DieterRunning.copy(alpha = 0.2f + pulse * 0.16f),
                        topLeft = Offset(stroke / 2, stroke / 2),
                        size = Size(size.width - stroke, size.height - stroke),
                        cornerRadius = CornerRadius((size.height - stroke) / 2),
                        style = Stroke(stroke),
                    )
                },
            ) {
                Row(
                    Modifier.padding(start = 5.dp, end = 8.dp, top = 3.dp, bottom = 3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Canvas(Modifier.size(18.dp)) {
                        val strokeWidth = 1.7.dp.toPx()
                        val pulse = glow?.value ?: 0f
                        drawCircle(DieterRunning.copy(alpha = 0.16f), style = Stroke(strokeWidth))
                        rotate(rotation?.value ?: 0f) {
                            drawArc(
                                color = DieterRunning.copy(alpha = 0.55f + pulse * 0.45f),
                                startAngle = -90f,
                                sweepAngle = 112f,
                                useCenter = false,
                                style = Stroke(strokeWidth, cap = StrokeCap.Round),
                            )
                        }
                        drawCircle(DieterRunning.copy(alpha = 0.2f + pulse * 0.15f), radius = 4.dp.toPx())
                        drawCircle(DieterRunning, radius = 2.2.dp.toPx())
                    }
                    Spacer(Modifier.width(4.dp))
                    Text("Running", color = DieterShell, fontSize = 10.sp, lineHeight = 12.sp, fontWeight = FontWeight.SemiBold)
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
internal fun CompactSearchField(value: String, onValueChange: (String) -> Unit, placeholder: String, clearable: Boolean = false) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            .heightIn(min = if (clearable) 48.dp else 42.dp).clip(RoundedCornerShape(24.dp)).background(DieterSurfaceHigh)
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
            modifier = Modifier.weight(1f).semantics { contentDescription = placeholder },
            decorationBox = { inner ->
                if (value.isBlank()) Text(placeholder, color = DieterMuted, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                inner()
            }
        )
        if (clearable && value.isNotEmpty()) {
            IconButton(onClick = { onValueChange("") }, modifier = Modifier.size(48.dp)) {
                Icon(Icons.Outlined.Cancel, "Clear search", tint = DieterMuted, modifier = Modifier.size(18.dp))
            }
        }
    }
}
