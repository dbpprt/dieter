@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChevronRight
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
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.presentation.CardDetails
import com.dbpprt.dieter.core.presentation.ConversationPresentation
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.presentation.SubagentPresentation
import com.dbpprt.dieter.core.presentation.TimelineCache
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterRunning
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged

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
    val daemonId = state.conversationView?.daemonId
    val catalog by remember(daemonId) { model.conversationCatalog(daemonId) }.collectAsState(null)
    val timelineCache = remember(state.selectedCardId) { TimelineCache() }
    val presentation = remember(
        state.conversationView, state.selectedCardId, state.selectedCard, state.pendingMessageIds, state.acceptedOutboxIds,
        state.failedOutboxIds, state.cardOperations, state.showReasoningTraces, state.spaceBoards, state.board, catalog,
    ) { model.presentConversation(state, catalog, timelineCache) }
    if (card == null || presentation == null) {
        LoadingState(modifier)
        return
    }
    val agent = composerAgent(state, presentation, catalog)
    val detailSections = DetailSection.entries
    val detailPageCount = detailSections.size
    val subagents = snapshot?.conversation?.subagents.orEmpty()
    val activeSubagents = SubagentPresentation.active(subagents)
    val changedFileCount = CardDetails.changedFiles(card, state.workspaceReview.changeset)
    val showDetailTabs = CardDetails.showsTabs(card, subagents)
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
                    if (Cards.isChat(card)) {
                        "${snapshot?.detail?.project?.name ?: state.project?.name ?: "Project"} · Standalone chat"
                    } else {
                        "${snapshot?.detail?.project?.name ?: state.project?.name ?: "Project"} / ${snapshot?.detail?.board?.name ?: state.board?.name ?: "Board"}"
                    },
                    color = DieterMuted,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    conversationRefreshLabel(
                        state.conversationLastRefreshedAtMillis,
                        state.conversationSyncing,
                        refreshClockMillis,
                    ),
                    color = DieterMuted,
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.testTag("conversation-last-refreshed"),
                )
            }
            StatusPill(presentation.runtime)
            if (presentation.canHalt) {
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
                    if (Cards.isChat(card)) {
                        DropdownMenuItem(
                            text = { Text(if (card.pinned) "Unpin chat" else "Pin chat") },
                            leadingIcon = { Icon(Icons.Outlined.PushPin, null) },
                            onClick = { actionsOpen = false; model.togglePin(card) },
                        )
                    } else {
                        DropdownMenuItem(
                            text = { Text("Labels") },
                            leadingIcon = { Icon(Icons.Outlined.LocalOffer, null) },
                            onClick = { actionsOpen = false; labelsOpen = true },
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
                        modifier = Modifier.testTag("card-detail-${section.name.lowercase()}"),
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
                    DetailSection.CONVERSATION -> ConversationBody(state, model, presentation, agent, Modifier.fillMaxSize())
                    DetailSection.CHANGES -> WorkspaceChangesBody(
                        state = state,
                        model = model,
                        active = detailSections.getOrNull(state.detailTab) == DetailSection.CHANGES,
                        modifier = Modifier.fillMaxSize(),
                    )
                    DetailSection.SUBAGENTS -> SubagentsBody(state, model, presentation, agent, Modifier.fillMaxSize())
                }
            }
        } else {
            HorizontalDivider(color = DieterOutline.copy(alpha = 0.52f))
            ConversationBody(state, model, presentation, agent, Modifier.weight(1f).fillMaxWidth())
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
    SUBAGENTS("Subagents"),
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
        }
    }
}

/** The conversation's delegated agents, with a composer that messages the conversation with the composer's [agent]. */
@Composable
internal fun SubagentsBody(
    state: DieterUiState,
    model: DieterViewModel,
    presentation: ConversationPresentation,
    agent: AgentControls?,
    modifier: Modifier = Modifier,
) {
    val subagents = state.conversation?.conversation?.subagents.orEmpty()
    val active = SubagentPresentation.active(subagents)
    var text by remember(state.selectedCardId) { mutableStateOf("") }
    Column(modifier) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(Counts.of(subagents.size, "subagent"), fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
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
            controls = agent,
            contextUsage = presentation.contextUsage,
            onValueChange = { text = it },
            onChoose = model::chooseAgent,
            onSend = {
                model.sendMessage(text)
                text = ""
            },
        )
    }
}

@Composable
internal fun SubagentStatusCard(subagent: Subagent) {
    val presented = SubagentPresentation(subagent, kotlin.time.Clock.System.now())
    val running = presented.active
    val completed = presented.completed
    val title = presented.title
    val elapsed = presented.elapsedLabel
    val primaryNarrative = presented.narrative.firstOrNull()
    val nowLine = presented.nowLine
    val metrics = presented.operationalMetrics
    val contextProgress = presented.contextFraction?.toFloat()
    val detailSections = presented.details
    val hasMoreDetails = detailSections.isNotEmpty()
    var expanded by remember(subagent.id) { mutableStateOf(false) }
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
            if (primaryNarrative != null) {
                SubagentDetailText(
                    label = primaryNarrative.label,
                    value = primaryNarrative.value,
                    modifier = Modifier.padding(start = 39.dp, end = 13.dp, top = 7.dp),
                    maxLines = if (expanded) Int.MAX_VALUE else 3,
                )
            }
            if (nowLine != null) {
                Text(
                    "Now · $nowLine",
                    color = DieterMuted,
                    fontSize = 11.sp,
                    maxLines = if (expanded) Int.MAX_VALUE else 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 39.dp, end = 13.dp, top = 7.dp),
                )
            }
            if (metrics.isNotEmpty()) {
                Text(
                    metrics.joinToString(" · "),
                    color = DieterMuted,
                    fontSize = 10.sp,
                    lineHeight = 14.sp,
                    modifier = Modifier.padding(start = 39.dp, end = 13.dp, top = 7.dp),
                )
            }
            if (contextProgress != null) {
                LinearProgressIndicator(
                    progress = { contextProgress },
                    modifier = Modifier.fillMaxWidth().padding(start = 39.dp, end = 13.dp, top = 8.dp).height(3.dp),
                    color = tint,
                    trackColor = DieterOutline,
                )
            }
            if (subagent.error.isNotBlank()) {
                SubagentDetailText(
                    label = "Error",
                    value = subagent.error,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(start = 39.dp, end = 13.dp, top = 8.dp),
                )
            }
            if (subagent.retry.isNotBlank()) {
                SubagentDetailText(
                    label = "Retry",
                    value = subagent.retry,
                    modifier = Modifier.padding(start = 39.dp, end = 13.dp, top = 8.dp),
                )
            }
            if (hasMoreDetails) {
                Row(
                    Modifier
                        .padding(start = 31.dp, end = 5.dp, top = 3.dp)
                        .clip(RoundedCornerShape(7.dp))
                        .clickable { expanded = !expanded }
                        .padding(horizontal = 7.dp, vertical = 7.dp)
                        .testTag("subagent-details-${subagent.id}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Outlined.ChevronRight,
                        contentDescription = null,
                        tint = DieterMuted,
                        modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(if (expanded) "Hide details" else "More details", color = DieterMuted, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            if (expanded) {
                Column(
                    Modifier.padding(start = 39.dp, end = 13.dp, bottom = 3.dp),
                    verticalArrangement = Arrangement.spacedBy(9.dp),
                ) {
                    detailSections.forEach { section ->
                        SubagentDetailText(
                            label = section.label,
                            value = section.value,
                            monospace = section.monospace,
                        )
                    }
                }
            }
            HorizontalDivider(color = DieterOutline.copy(alpha = 0.52f), modifier = Modifier.padding(top = 9.dp))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 13.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    presented.agentLabel,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 10.sp,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    presented.identity,
                    color = DieterMuted,
                    fontSize = 10.sp,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(presented.statusLabel, color = tint, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun SubagentDetailText(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    monospace: Boolean = false,
    maxLines: Int = Int.MAX_VALUE,
    color: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.onSurface,
) {
    Column(modifier) {
        Text(label.uppercase(), color = DieterMuted, fontSize = 8.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(2.dp))
        SelectionContainer {
            Text(
                SubagentPresentation.DetailSection(label, value).bounded(),
                color = color,
                fontSize = if (monospace) 9.sp else 11.sp,
                lineHeight = if (monospace) 13.sp else 15.sp,
                fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default,
                maxLines = maxLines,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
