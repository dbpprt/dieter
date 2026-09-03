@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.LocalOffer
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.connection.isServerConversationId
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.Subagent
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import java.time.Duration
import java.time.Instant
import com.dbpprt.dieter.ui.theme.DieterRunning

@Composable
internal fun CardDetailScreen(
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
internal fun DetailTabLabel(label: String, count: Int = 0, selected: Boolean) {
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
internal fun SubagentsBody(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    val subagents = state.conversation?.conversation?.subagentsList.orEmpty()
    val active = subagents.count { it.status == "running" || it.status == "pending" }
    val conversationMessages = remember(state.olderMessages, state.conversation) {
        mergedConversationMessages(state.olderMessages, state.conversation?.conversation?.messagesList.orEmpty())
    }
    val contextUsage = remember(conversationMessages) { latestContextUsage(conversationMessages) }
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
            contextUsage = contextUsage,
            onValueChange = { text = it },
            onSend = { provider, selectedModel, effort, providerOptions ->
                val message = text.trim()
                if (message.isNotBlank()) {
                    text = ""
                    model.sendMessage(message, emptyList(), provider, selectedModel, effort, providerOptions)
                }
            },
        )
    }
}

@Composable
internal fun SubagentStatusCard(subagent: Subagent) {
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

internal val subagentSuffixPattern = Regex("""\s*\((agent\s+\d+)\)\s*$""", RegexOption.IGNORE_CASE)

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

internal fun subagentElapsed(subagent: Subagent): String {
    val durationMs = subagent.durationMs.takeIf { it > 0 } ?: runCatching {
        val start = Instant.parse(subagent.startedAt)
        val end = subagent.endedAt.takeIf(String::isNotBlank)?.let(Instant::parse) ?: Instant.now()
        Duration.between(start, end).toMillis()
    }.getOrDefault(0L)
    val seconds = (durationMs / 1_000).coerceAtLeast(0)
    if (seconds <= 0L) return ""
    return if (seconds < 60) "${seconds}s" else "${seconds / 60}m ${seconds % 60}s"
}
