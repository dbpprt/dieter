@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Timeline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.activity.ActivityItem
import com.dbpprt.dieter.core.activity.ActivityKind
import com.dbpprt.dieter.core.activity.ActivitySection
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.core.quotas.QuotaLevel
import com.dbpprt.dieter.core.quotas.Quotas
import com.dbpprt.dieter.ui.theme.*
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.navigation.FolderScope
import kotlin.time.toKotlinInstant
import kotlinx.coroutines.delay
import java.time.Instant

@Composable
internal fun ActivityScreen(state: DieterUiState, model: DieterViewModel, expanded: Boolean, contentPadding: PaddingValues) {
    var accountKey by rememberSaveable(state.activeGatewayId) { mutableStateOf<String?>(null) }
    val feedState = rememberSaveableStateHolder()
    var folderChatId by rememberSaveable { mutableStateOf<String?>(null) }
    val tablet = LocalTabletWorkspace.current
    var timeline by rememberSaveable { mutableStateOf(false) }
    val content: @Composable (Modifier) -> Unit = { modifier ->
        feedState.SaveableStateProvider(state.activeGatewayId) {
            Box(modifier) {
                ActivityFeed(
                    state = state, modifier = Modifier.fillMaxSize(),
                    onOpen = { timeline = false; model.openCard(it, Destination.ACTIVITY) },
                    onConnections = model::showConnectionDialog,
                    onAccount = { accountKey = it.account_key },
                    onRefreshAccounts = { model.refreshProviderQuotas() },
                    tablet = tablet,
                    timelineOnly = tablet && timeline,
                    onTimelineToggle = { timeline = it },
                    actions = ActivityItemActions(
                        onRename = model::renameConversation,
                        onArchive = model::archiveConversation,
                        onTogglePin = model::togglePin,
                        onMoveToFolder = { folderChatId = it.id },
                        enabled = state.connected && !state.working,
                    ),
                    onClearError = model::clearError,
                )
                ExtendedFloatingActionButton(
                    onClick = { model.beginCapture() },
                    modifier = Modifier.align(Alignment.BottomEnd).padding(20.dp).testTag("inbox-new-task"),
                    icon = { Icon(Icons.Default.Add, "New task") },
                    text = { Text("New task") },
                )
            }
        }
    }
    if (tablet) {
        TabletListDetail(
            modifier = Modifier.padding(contentPadding),
            dividerTag = "activity-pane-divider",
            initialLeadingFraction = state.activityPaneLeadingFraction,
            onLeadingFractionCommitted = model::setActivityPaneLeadingFraction,
            list = content,
            detail = { modifier ->
                if (state.selectedCardId != null) CardDetailScreen(state, model, modifier, showBack = false)
                else EmptyDetail("Your inbox", "Select an item from your inbox to read, reply, or review it here.", Icons.Outlined.Inbox, modifier)
            },
        )
    } else if (!expanded && state.selectedCardId != null) {
        CardDetailScreen(state, model, Modifier.padding(contentPadding))
    } else if (expanded) {
        ResizableHorizontalSplitPane(
            dividerTag = "activity-pane-divider", modifier = Modifier.fillMaxSize().padding(contentPadding),
            initialLeadingFraction = state.activityPaneLeadingFraction,
            onLeadingFractionCommitted = model::setActivityPaneLeadingFraction,
            leading = content,
        ) { modifier ->
            if (state.selectedCardId != null) CardDetailScreen(state, model, modifier, showBack = false)
            else EmptyDetail("Your activity", "Select an item to read, reply, or review it here.", Icons.Outlined.Inbox, modifier)
        }
    } else {
        content(Modifier.fillMaxSize().padding(contentPadding))
    }
    folderChatId?.let { id ->
        MoveToNavigationFolderDialog(id, FolderScope.CHATS, state.chatFolders,
            model, onDismiss = { folderChatId = null })
    }
    val group = state.providerQuotaGroups.firstOrNull { group -> group.accounts.any { it.account_key == accountKey } }
    val account = group?.accounts?.firstOrNull { it.account_key == accountKey }
    if (account != null) {
        ModalBottomSheet(onDismissRequest = { accountKey = null }, containerColor = DieterSurface) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("${Quotas.productName(group.provider)} account", style = MaterialTheme.typography.titleLarge)
                ProviderQuotaAccountView(account, group.provider, state, model::setProviderQuotaSummaryInclusion,
                    model::consumeProviderQuotaReset, showMonetaryBalances = false)
            }
        }
    }
}

/** Stateless callbacks keep the real screen usable in isolated native UI tests. */
@Composable
internal fun ActivityFeed(
    state: DieterUiState,
    modifier: Modifier = Modifier,
    onOpen: (Card) -> Unit,
    onConnections: () -> Unit,
    onAccount: (ProviderQuotaSnapshot) -> Unit,
    onRefreshAccounts: () -> Unit,
    clock: Instant? = null,
    tablet: Boolean = false,
    timelineOnly: Boolean = false,
    onTimelineToggle: (Boolean) -> Unit = {},
    actions: ActivityItemActions? = null,
    onClearError: () -> Unit = {},
) {
    val itemActions: (Card) -> ActivityItemActions? = { card ->
        actions?.copy(enabled = actions.enabled && card.id !in state.pendingCardIds)
    }
    var tick by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(clock) {
        if (clock == null) while (true) { tick = Instant.now(); delay(15_000L) }
    }
    val now = clock ?: tick
    val timelineNow = if (state.connected) now else state.lastConnectedAtMillis?.let(Instant::ofEpochMilli) ?: now
    var projectId by rememberSaveable(state.activeGatewayId) { mutableStateOf("") }
    var query by rememberSaveable(state.activeGatewayId) { mutableStateOf("") }
    var searchOpen by rememberSaveable { mutableStateOf(false) }
    var hours by rememberSaveable { mutableIntStateOf(1) }
    var expandedTimeline by rememberSaveable { mutableStateOf(false) }
    var expandedAccounts by rememberSaveable { mutableStateOf(false) }
    val entries = state.activityItems
    val projectNames = remember(state.projects) { state.projects.associate { it.id to it.name } }
    // A removed project must not leave the user looking at a permanently empty filter.
    val selectedProject = projectId.takeIf { it in projectNames }.orEmpty()
    val filtered = remember(entries, selectedProject, query) { Activity.filter(entries, selectedProject, query) }
    val sections = remember(filtered) { Activity.sections(filtered) }
    val attention = sections.getValue(ActivitySection.ATTENTION)
    val running = sections.getValue(ActivitySection.RUNNING)
    val recent = sections.getValue(ActivitySection.RECENT)
    val intervals = remember(filtered, timelineNow, hours) { Activity.timeline(filtered, timelineNow.toKotlinInstant(), hours) }
    val accounts = state.providerQuotaGroups.flatMap { group -> group.accounts.map { group.provider to it } }
    Box(modifier, contentAlignment = Alignment.TopCenter) {
        LazyColumn(
            Modifier.widthIn(max = if (timelineOnly) 1800.dp else 900.dp).fillMaxSize().testTag("activity-feed"),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 88.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (state.error != null) item("error") { SurfaceErrorBanner(state.error, onClearError) }
            item("header") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(if (tablet) "Inbox" else "Activity", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
                        Text("${state.projects.size} projects · ${attention.size} need attention · ${running.size} running",
                            style = MaterialTheme.typography.bodySmall, color = DieterMuted)
                    }
                    IconButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) query = "" }) {
                        Icon(if (searchOpen) Icons.Outlined.Close else Icons.Outlined.Search, if (searchOpen) "Close search" else "Search activity")
                    }
                    IconButton(onClick = onConnections) {
                        BadgedBox(badge = { if (!state.connected) Badge(containerColor = DieterAmber) }) {
                            Icon(Icons.Outlined.DesktopWindows, "Machines and connection status")
                        }
                    }
                }
            }
            if (tablet) item("view-mode") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = !timelineOnly, onClick = { onTimelineToggle(false) }, label = { Text("List") }, modifier = Modifier.testTag("tablet-inbox-list"))
                    FilterChip(selected = timelineOnly, onClick = { onTimelineToggle(true) }, label = { Text("Timeline") }, modifier = Modifier.testTag("tablet-inbox-timeline"))
                }
            }
            if (searchOpen) item("search") {
                OutlinedTextField(query, { query = it }, label = { Text("Search chats and cards") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("activity-search"))
            }
            item("projects") {
                if (tablet) {
                    var projectMenu by remember { mutableStateOf(false) }
                    Box {
                        FilterChip(selected = selectedProject.isNotBlank(), onClick = { projectMenu = true },
                            label = { Text(projectNames[selectedProject] ?: "All projects") },
                            trailingIcon = { Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.size(18.dp)) },
                            modifier = Modifier.testTag("tablet-inbox-projects"))
                        DropdownMenu(expanded = projectMenu, onDismissRequest = { projectMenu = false }) {
                            DropdownMenuItem(text = { Text("All projects") }, onClick = { projectId = ""; projectMenu = false })
                            state.projects.forEach { project ->
                                DropdownMenuItem(text = { Text(project.name) }, onClick = { projectId = project.id; projectMenu = false })
                            }
                        }
                    }
                } else {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 12.dp)) {
                        item("all") { ActivityProjectTile("", "All", selectedProject.isEmpty(), null, { projectId = "" }) }
                        items(state.projects, key = { it.id }) { project ->
                            ActivityProjectTile(project.id, project.name, selectedProject == project.id,
                                Activity.needsYouCount(entries.filter { it.card.project_id == project.id }).takeIf { it > 0 }, { projectId = project.id })
                        }
                    }
                }
            }
            if (timelineOnly) item("wide-timeline") {
                TabletActivityTimeline(intervals, projectNames, hours, state.connected, { hours = it }, onOpen, itemActions)
            }
            if (!timelineOnly) {
                item("timeline") {
                    if (tablet) {
                        Surface(onClick = { onTimelineToggle(true) }, color = DieterSurfaceHigh, shape = RoundedCornerShape(14.dp), modifier = Modifier.fillMaxWidth()) {
                            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(if (state.connected) "● LIVE" else "CACHED", color = if (state.connected) DieterEyes else DieterAmber, style = MaterialTheme.typography.labelMedium)
                                Text("  ${running.size} running", Modifier.weight(1f), color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                                Icon(Icons.Outlined.Timeline, "Open activity timeline", Modifier.size(20.dp), tint = DieterMuted)
                            }
                        }
                    } else ActivityTimelinePanel(intervals, hours, state.connected, running.size, expandedTimeline,
                        onHours = { hours = it }, onExpand = { expandedTimeline = !expandedTimeline }, onOpen = onOpen, actions = itemActions)
                }
                ActivitySection.entries.forEach { section ->
                    activitySection(section.title, sections.getValue(section), now, state::machineLabel, onOpen, state.selectedCardId, itemActions)
                }
                if (filtered.isEmpty()) item("empty") {
                    Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(if (query.isNotBlank()) "No matching activity" else "All quiet here", fontWeight = FontWeight.SemiBold)
                        Text("Activity from chats and cards appears here when an agent starts, replies, or needs you.", color = DieterMuted)
                    }
                }
            }
            if (!timelineOnly) {
                item("accounts-header") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ActivitySectionHeading("Accounts · usage remaining", Modifier.weight(1f))
                        TextButton(onClick = onRefreshAccounts, enabled = !state.providerQuotasLoading) {
                            Text(if (state.providerQuotasLoading) "Refreshing…" else "Refresh")
                        }
                    }
                }
                state.providerQuotaError?.let { error -> item("accounts-error") { Text(error, color = DieterAmber, style = MaterialTheme.typography.bodySmall) } }
                if (accounts.isEmpty()) item("accounts-empty") {
                    Text(if (state.providerQuotasLoading) "Loading accounts…" else "No account usage available. Sign in to a supported provider on a Dieter machine.",
                        color = DieterMuted, modifier = Modifier.padding(bottom = 12.dp))
                }
                items(if (expandedAccounts) accounts else accounts.take(3), key = { "account-${it.first.value}-${it.second.account_key}" }) { (provider, account) ->
                    ActivityAccountRow(provider, account, now, onClick = { onAccount(account) })
                }
                if (accounts.size > 3) item("accounts-more") {
                    TextButton(onClick = { expandedAccounts = !expandedAccounts }) {
                        Text(if (expandedAccounts) "Show fewer accounts" else "Show all ${accounts.size} accounts")
                    }
                }
            }

        }
    }
}

@Composable
private fun ActivityProjectTile(id: String, name: String, isSelected: Boolean, count: Int?, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(64.dp)) {
        BadgedBox(badge = { if (count != null) Badge(containerColor = DieterAmber, contentColor = DieterAbyss) { Text(count.toString()) } }) {
            Surface(onClick = onClick, shape = RoundedCornerShape(19.dp),
                color = if (id.isBlank()) DieterShellTint else stableAccent(id),
                border = if (isSelected) BorderStroke(2.dp, DieterShell) else null,
                modifier = Modifier.size(58.dp).testTag("activity-project-${id.ifBlank { "all" }}")
                    .semantics { selected = isSelected; contentDescription = "$name${count?.let { ", $it need attention" }.orEmpty()}" }) {
                Box(contentAlignment = Alignment.Center) {
                    if (id.isBlank()) Icon(Icons.Outlined.Timeline, null, tint = DieterText)
                    else Text(name.take(1).lowercase(), color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
        Text(name, color = if (isSelected) DieterText else DieterMuted, style = MaterialTheme.typography.labelSmall,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun ActivityTimelinePanel(
    intervals: List<Activity.TimelineBar>, hours: Int, live: Boolean, runningCount: Int, expanded: Boolean,
    onHours: (Int) -> Unit, onExpand: () -> Unit, onOpen: (Card) -> Unit,
    actions: (Card) -> ActivityItemActions?,
) {
    var rangeMenu by remember { mutableStateOf(false) }
    var detailLimit by rememberSaveable(hours) { mutableIntStateOf(20) }
    val preview = intervals.sortedByDescending { it.item.running }.take(4)
    val outline = DieterOutline
    val marker = DieterCoral
    val colors = preview.map { if (it.item.kind.needsYou) DieterAmber else stableAccent(it.item.card.project_id) }
    Surface(shape = RoundedCornerShape(22.dp), color = DieterSurface, modifier = Modifier.fillMaxWidth().testTag("activity-timeline")) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (live) "● LIVE" else "CACHED", color = if (live) DieterEyes else DieterAmber,
                    style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace)
                Text("  $runningCount running", color = DieterMuted, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                Box {
                    TextButton(onClick = { rangeMenu = true }, modifier = Modifier.testTag("activity-range")) { Text("Last ${hours}h ▾") }
                    DropdownMenu(expanded = rangeMenu, onDismissRequest = { rangeMenu = false }) {
                        listOf(1, 6, 24).forEach { value ->
                            DropdownMenuItem(text = { Text("Last ${value}h") }, onClick = { onHours(value); rangeMenu = false },
                                modifier = Modifier.testTag("activity-range-$value").semantics { selected = value == hours })
                        }
                    }
                }
            }
            if (intervals.isEmpty()) {
                Text("No activity in the last ${hours}h", color = DieterMuted, modifier = Modifier.padding(vertical = 12.dp))
            } else {
                // The compact chart is one generous touch target; expanded rows expose every
                // conversation by name to touch, keyboard and accessibility users.
                Surface(onClick = onExpand, color = Color.Transparent,
                    modifier = Modifier.fillMaxWidth().testTag("activity-timeline-expand")
                        .semantics { contentDescription = if (expanded) "Collapse timeline details" else "Show timeline details, ${intervals.size} conversations" }) {
                    Canvas(Modifier.fillMaxWidth().height((preview.size * 15 + 12).coerceAtLeast(48).dp)) {
                        val width = (size.width - 6.dp.toPx()).coerceAtLeast(0f)
                        val rowHeight = size.height / preview.size
                        preview.forEachIndexed { index, interval ->
                            val y = rowHeight * (index + .5f)
                            val left = interval.from.toFloat() * width
                            val right = interval.to.toFloat() * width
                            if (interval.point) drawCircle(colors[index], 4.dp.toPx(), Offset(right, y))
                            else {
                                drawRoundRect(colors[index].copy(alpha = .55f), Offset(left, y - 4.dp.toPx()),
                                    Size((right - left).coerceAtLeast(3.dp.toPx()), 8.dp.toPx()), CornerRadius(2.dp.toPx()))
                                drawLine(colors[index], Offset(left, y - 4.dp.toPx()), Offset(left, y + 4.dp.toPx()), 2.dp.toPx())
                            }
                        }
                        drawLine(marker, Offset(width, 0f), Offset(width, size.height), 1.dp.toPx())
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("−${hours}h", color = DieterMuted, style = MaterialTheme.typography.labelSmall)
                Text("−${hours * 30}m", color = DieterMuted, style = MaterialTheme.typography.labelSmall)
                Text(if (live) "Now" else "Last sync", color = DieterCoral, style = MaterialTheme.typography.labelSmall)
            }
            if (expanded) {
                Text("Latest activity per conversation · dots mark events without a recorded duration.", color = DieterMuted, style = MaterialTheme.typography.labelSmall)
                intervals.take(detailLimit).forEach { interval ->
                    ActivityItem(card = interval.item.card, onOpen = onOpen, actions = actions(interval.item.card), color = Color.Transparent,
                        modifier = Modifier.fillMaxWidth().testTag("activity-bar-${interval.item.card.id}")) {
                        Column(Modifier.padding(vertical = 12.dp)) {
                            Text(interval.item.card.title, maxLines = 2, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.labelLarge)
                            Text("${if (interval.item.card.scope == "chat") "Chat" else "Card"} · ${interval.item.detail}",
                                color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    HorizontalDivider(color = outline)
                }
                if (intervals.size > detailLimit) TextButton(onClick = { detailLimit += 20 }) { Text("Show more conversations") }
                TextButton(onClick = onExpand) { Text("Collapse timeline") }
            }
        }
    }
}

private fun LazyListScope.activitySection(
    title: String, entries: List<ActivityItem>, now: Instant,
    machineLabel: (String) -> String, onOpen: (Card) -> Unit,
    selectedId: String? = null,
    actions: (Card) -> ActivityItemActions? = { null },
) {
    if (entries.isEmpty()) return
    item("heading-$title") { ActivitySectionHeading("$title · ${entries.size}") }
    items(entries, key = { "$title-${it.card.id}" }) { entry ->
        ActivityRow(entry, machineLabel(entry.card.owner_daemon_id), now, entry.card.id == selectedId, actions(entry.card)) { onOpen(entry.card) }
    }
}

@Composable
private fun ActivitySectionHeading(title: String, modifier: Modifier = Modifier) {
    Text(title.uppercase(), color = DieterMuted, fontFamily = FontFamily.Monospace,
        style = MaterialTheme.typography.labelMedium, modifier = modifier.padding(top = 12.dp, bottom = 4.dp))
}

@Composable
private fun ActivityAccountRow(provider: ProviderQuotaProvider, account: ProviderQuotaSnapshot, now: Instant, onClick: () -> Unit) {
    val warning = Quotas.warning(account, now.toKotlinInstant())
    Surface(onClick = onClick, shape = RoundedCornerShape(16.dp), color = DieterSurface,
        modifier = Modifier.fillMaxWidth().testTag("activity-account-${account.account_key}")) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(Quotas.productName(provider), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(Quotas.identity(account),
                color = DieterMuted, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            warning?.let { Text(it, color = DieterAmber, style = MaterialTheme.typography.labelSmall) }
            account.windows.forEach { window ->
                val remaining = (window.remaining_percent ?: 0).coerceIn(0, 100)
                Text("${Quotas.windowName(window)} · ${if (window.remaining_percent != null) "$remaining% remaining" else "Not reported"}",
                    style = MaterialTheme.typography.labelMedium)
                if (window.remaining_percent != null) LinearProgressIndicator(progress = { remaining / 100f },
                    color = if (Quotas.level(remaining) == QuotaLevel.CRITICAL) DieterCoral else quotaTint(provider, remaining),
                    trackColor = DieterOutline, modifier = Modifier.fillMaxWidth().height(5.dp))
                if (window.resets_at.isNotBlank()) Text(Quotas.resetText(window.resets_at, now.toKotlinInstant(), fine = false), color = DieterMuted, style = MaterialTheme.typography.labelSmall)
            }
            if (account.windows.size == 0) Text("Usage windows unavailable", color = DieterMuted, style = MaterialTheme.typography.bodySmall)
        }
    }
}
