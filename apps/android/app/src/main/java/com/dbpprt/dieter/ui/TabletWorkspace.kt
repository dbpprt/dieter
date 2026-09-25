@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.settings.NavigationFolderScope
import com.dbpprt.dieter.settings.DEFAULT_SIDEBAR_LEADING_FRACTION
import com.dbpprt.dieter.ui.theme.*
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Project

// Medium windows retain the Fold layout. Use the actual window, not the device's
// physical size, so split-screen and freeform windows adapt without losing selection.
internal const val TABLET_WORKSPACE_MIN_WIDTH_DP = 840
internal fun usesTabletWorkspace(widthDp: Float) = widthDp >= TABLET_WORKSPACE_MIN_WIDTH_DP
internal val LocalTabletWorkspace = staticCompositionLocalOf { false }
internal val LocalTabletProjectWorkspaces = staticCompositionLocalOf { false }
private val LocalTabletStatusContent = staticCompositionLocalOf<@Composable () -> Unit> { {} }

internal enum class TabletProjectTab(val label: String) {
    BOARD("Board"), CHATS("Chats"), FILES("Files"), SCHEDULES("Schedules"), WORKSPACES("Worktrees")
}

@Composable
internal fun TabletWorkspace(
    state: DieterUiState,
    model: DieterViewModel,
    destinationContent: @Composable (DieterUiState) -> Unit,
    surfaceContent: @Composable () -> Unit,
    statusContent: @Composable () -> Unit = {},
) {
    var projectChats by rememberSaveable { mutableStateOf(false) }
    var workspaces by rememberSaveable { mutableStateOf(false) }
    var usage by rememberSaveable { mutableStateOf(false) }
    var manageProjects by rememberSaveable { mutableStateOf(false) }
    val projects = state.destination in listOf(Destination.BOARD, Destination.FILES, Destination.SCHEDULES) ||
        (state.destination == Destination.CHATS && projectChats)
    val tools = !projects && !state.destination.isPrimaryDestination() || usage
    val attentionCount = remember(state.spaceCards, state.cards, state.chats, state.activityDetails) {
        buildActivityEntries(state.spaceCards + state.cards + state.chats, state.activityDetails).count { it.needsYou }
    }
    val settings = state.appSurface == AppSurface.APP_SETTINGS
    val newChat = state.appSurface == AppSurface.NEW_CHAT
    val projectTab = when {
        state.destination == Destination.FILES -> TabletProjectTab.FILES
        state.destination == Destination.SCHEDULES -> TabletProjectTab.SCHEDULES
        state.destination == Destination.CHATS -> TabletProjectTab.CHATS
        workspaces -> TabletProjectTab.WORKSPACES
        else -> TabletProjectTab.BOARD
    }
    val navigate: (Destination) -> Unit = { destination ->
        projectChats = false
        workspaces = false
        usage = false
        manageProjects = false
        model.navigate(destination)
    }
    LaunchedEffect(state.destination) {
        if (state.destination != Destination.CHATS) projectChats = false
        if (state.destination != Destination.BOARD) workspaces = false
        if (state.destination.isPrimaryDestination()) usage = false
    }
    CompositionLocalProvider(LocalTabletWorkspace provides true, LocalTabletStatusContent provides statusContent) {
        Surface(color = MaterialTheme.colorScheme.background, contentColor = MaterialTheme.colorScheme.onBackground) {
            Row(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).testTag("tablet-workspace")) {
                TabletNavigationRail(
                    selected = when {
                        newChat -> Destination.CHATS
                        projects -> Destination.BOARD
                        else -> state.destination
                    },
                    toolsSelected = tools && !newChat,
                    settingsSelected = settings,
                    attentionCount = attentionCount,
                    onlineCount = state.presentedEndpointConnections.count { it.online },
                    onNavigate = navigate,
                    onTools = { navigate(Destination.MACHINES) },
                    onCreate = { usage = false; model.openSurface(AppSurface.NEW_CHAT) },
                    onConnections = model::showConnectionDialog,
                    onSettings = { model.openSurface(AppSurface.APP_SETTINGS) },
                )
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    when {
                        settings -> TabletDetailPane { surfaceContent() }
                        newChat -> TabletListDetail(
                            dividerTag = "tablet-chats-pane-divider",
                            initialLeadingFraction = state.chatsPaneLeadingFraction,
                            onLeadingFractionCommitted = model::setChatsPaneLeadingFraction,
                            list = { ChatsList(state, model, it) },
                            detail = { Box(it) { surfaceContent() } },
                        )
                        projects -> {
                            TabletListDetail(
                                dividerTag = "tablet-projects-pane-divider",
                                initialLeadingFraction = state.projectsPaneLeadingFraction,
                                onLeadingFractionCommitted = model::setProjectsPaneLeadingFraction,
                                list = { paneModifier ->
                                    TabletProjectNavigator(state, model, paneModifier,
                                        onManage = { manageProjects = true; model.showBoardOverview() },
                                        onOpenBoard = { projectId, boardId ->
                                            workspaces = false
                                            manageProjects = false
                                            model.closeSurface()
                                            model.openBoard(projectId, boardId)
                                        },
                                    )
                                },
                                detail = { paneModifier ->
                                    Column(paneModifier) {
                                        if ((state.project != null && !state.boardOverviewVisible) ||
                                            state.destination in listOf(Destination.FILES, Destination.SCHEDULES) || projectChats) {
                                            TabletProjectTabs(state.project?.name.orEmpty(), projectTab, projectScopedNavigationEnabled(state)) { tab ->
                                                model.closeSurface()
                                                usage = false
                                                workspaces = tab == TabletProjectTab.WORKSPACES
                                                projectChats = tab == TabletProjectTab.CHATS
                                                when (tab) {
                                                    TabletProjectTab.BOARD, TabletProjectTab.WORKSPACES ->
                                                        model.openBoard(state.selectedProjectId, state.selectedBoardId)
                                                    TabletProjectTab.CHATS -> model.navigate(Destination.CHATS)
                                                    TabletProjectTab.FILES -> model.navigate(Destination.FILES)
                                                    TabletProjectTab.SCHEDULES -> model.navigate(Destination.SCHEDULES)
                                                }
                                                if (tab == TabletProjectTab.WORKSPACES) model.loadProjectWorkspaces()
                                            }
                                        }
                                        Box(Modifier.weight(1f).fillMaxWidth()) {
                                            when {
                                                state.appSurface != null -> surfaceContent()
                                                workspaces && state.destination == Destination.BOARD && !state.boardOverviewVisible ->
                                                    CompositionLocalProvider(LocalTabletProjectWorkspaces provides true) { destinationContent(state) }
                                                manageProjects && state.boardOverviewVisible -> SpacesOverview(state, model, Modifier.fillMaxSize())
                                                state.destination == Destination.BOARD && state.boardOverviewVisible ->
                                                    EmptyDetail("Your projects, side by side", "Choose a board to see its workflow, conversations, and files.", Icons.Outlined.ViewKanban, Modifier.fillMaxSize())
                                                else -> destinationContent(if (projectChats) state.copy(
                                                    chats = state.chats.filter { it.projectId == state.selectedProjectId },
                                                    projects = state.projects.filter { it.id == state.selectedProjectId },
                                                ) else state)
                                            }
                                        }
                                    }
                                },
                            )
                        }
                        tools -> Row(Modifier.fillMaxSize()) {
                            TabletToolsPane(state.destination, usage, { usage = false; navigate(it) }, {
                                usage = true
                                model.refreshProviderQuotas()
                            })
                            VerticalDivider(color = DieterDivider)
                            TabletDetailPane(Modifier.weight(1f).fillMaxHeight()) {
                                when {
                                    state.appSurface != null -> surfaceContent()
                                    usage -> Column(Modifier.fillMaxSize()) {
                                        SimpleScreenHeader("Usage", "Provider account limits and availability") {}
                                        ProviderQuotaDetails(state, { model.refreshProviderQuotas() }, model::setProviderQuotaSummaryInclusion,
                                            model::consumeProviderQuotaReset, Modifier.fillMaxSize().padding(20.dp))
                                    }
                                    else -> destinationContent(state)
                                }
                            }
                        }
                        state.appSurface != null -> TabletDetailPane { surfaceContent() }
                        else -> destinationContent(state)
                    }
                }
            }
        }
    }
}

@Composable
internal fun TabletNavigationRail(
    selected: Destination,
    toolsSelected: Boolean,
    settingsSelected: Boolean,
    attentionCount: Int,
    onlineCount: Int,
    onNavigate: (Destination) -> Unit,
    onTools: () -> Unit,
    onCreate: () -> Unit,
    onConnections: () -> Unit,
    onSettings: () -> Unit,
) {
    Column(
        Modifier.width(88.dp).fillMaxHeight().background(DieterSurface).statusBarsPadding().navigationBarsPadding()
            .semantics { paneTitle = "Navigation" },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            FloatingActionButton(onClick = onCreate, containerColor = DieterShell, contentColor = DieterAbyss,
                modifier = Modifier.padding(top = 20.dp, bottom = 24.dp).size(56.dp).testTag("tablet-new-chat")) {
                Icon(Icons.Default.Add, "New chat")
            }
            listOf(
                NavItem(Destination.ACTIVITY, "Inbox", Icons.Outlined.Inbox),
                NavItem(Destination.CHATS, "Chats", Icons.Outlined.ChatBubbleOutline),
                NavItem(Destination.BOARD, "Projects", Icons.Outlined.FolderOpen),
            ).forEach { item ->
                NavigationRailItem(
                    selected = !toolsSelected && !settingsSelected && item.destination == selected,
                    onClick = { onNavigate(item.destination) },
                    icon = { BadgedBox(badge = {
                        if (item.destination == Destination.ACTIVITY && attentionCount > 0) Badge { Text(attentionCount.toString()) }
                    }) { Icon(item.icon, null) } },
                    label = { Text(item.label) },
                    modifier = Modifier.padding(bottom = 8.dp).testTag("nav-${item.destination.name.lowercase()}"),
                )
            }
            NavigationRailItem(selected = toolsSelected && !settingsSelected, onClick = onTools,
                icon = { Icon(Icons.Outlined.GridView, null) }, label = { Text("Tools") }, modifier = Modifier.testTag("nav-tools"))
        }
        Surface(onClick = onConnections, color = DieterEyesTint, shape = RoundedCornerShape(16.dp),
            modifier = Modifier.padding(top = 8.dp).testTag("tablet-connections")) {
            Column(Modifier.padding(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Outlined.Computer, "Machines and connection status", tint = DieterEyes)
                Text("$onlineCount online", style = MaterialTheme.typography.labelSmall, color = DieterEyes)
            }
        }
        NavigationRailItem(selected = settingsSelected, onClick = onSettings,
            icon = { Icon(Icons.Outlined.Settings, null) }, label = { Text("Settings") },
            modifier = Modifier.padding(vertical = 8.dp).testTag("nav-settings"))
    }
}

/** Bounded navigation pane leaves a useful editor width even on a portrait tablet. */
@Composable
internal fun TabletListDetail(
    modifier: Modifier = Modifier,
    dividerTag: String,
    initialLeadingFraction: Float = DEFAULT_SIDEBAR_LEADING_FRACTION,
    onLeadingFractionCommitted: (Float) -> Unit = {},
    list: @Composable (Modifier) -> Unit,
    detail: @Composable (Modifier) -> Unit,
) {
    ResizableHorizontalSplitPane(
        dividerTag = dividerTag,
        modifier = modifier.fillMaxSize(),
        initialLeadingFraction = initialLeadingFraction,
        onLeadingFractionCommitted = onLeadingFractionCommitted,
        minimumLeadingWidth = 260.dp,
        minimumTrailingWidth = 420.dp,
        leading = { paneModifier ->
            // Paint the entire pane, including behind the system bars. Insets
            // belong to the controls inside it, not to the split's background.
            Box(paneModifier.background(DieterSurface).semantics { paneTitle = "List" }) {
                list(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding())
            }
        },
        trailing = { paneModifier ->
            TabletDetailPane(paneModifier.semantics { paneTitle = "Detail" }) {
                detail(Modifier.fillMaxSize())
            }
        },
    )
}

@Composable
private fun TabletDetailPane(modifier: Modifier = Modifier.fillMaxSize(), content: @Composable () -> Unit) {
    Column(modifier.statusBarsPadding().navigationBarsPadding()) {
        LocalTabletStatusContent.current()
        // A project may contain another split. Render connection status once
        // and let consumed window insets protect that nested content as well.
        CompositionLocalProvider(LocalTabletStatusContent provides {}) {
            Box(Modifier.weight(1f).fillMaxWidth()) { content() }
        }
    }
}

@Composable
internal fun TabletProjectTabs(projectName: String, selected: TabletProjectTab, projectToolsEnabled: Boolean = true, onSelect: (TabletProjectTab) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Text(projectName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 20.dp, top = 16.dp, bottom = 4.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
        PrimaryScrollableTabRow(selectedTabIndex = selected.ordinal, edgePadding = 12.dp,
            containerColor = MaterialTheme.colorScheme.background, contentColor = DieterShell) {
            TabletProjectTab.entries.forEach { tab ->
                Tab(selected = selected == tab, onClick = { onSelect(tab) }, text = { Text(tab.label) },
                    enabled = projectToolsEnabled || tab == TabletProjectTab.BOARD || tab == TabletProjectTab.CHATS,
                    modifier = Modifier.testTag("tablet-project-${tab.name.lowercase()}"))
            }
        }
    }
}

@Composable
private fun TabletToolsPane(selected: Destination, usage: Boolean, onSelect: (Destination) -> Unit, onUsage: () -> Unit) {
    Column(Modifier.width(184.dp).fillMaxHeight().background(DieterSurface).statusBarsPadding().navigationBarsPadding()
        .verticalScroll(rememberScrollState()).padding(12.dp)
        .semantics { paneTitle = "Tools" }) {
        Text("Tools", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(8.dp, 12.dp))
        listOf(
            NavItem(Destination.TERMINALS, "Terminals", Icons.Outlined.Terminal),
            NavItem(Destination.SCREENS, "Screens", Icons.Outlined.DesktopWindows),
            NavItem(Destination.MACHINES, "Machines", Icons.Outlined.Computer),
        ).forEach { item ->
            NavigationDrawerItem(label = { Text(item.label) }, selected = !usage && selected == item.destination,
                onClick = { onSelect(item.destination) }, icon = { Icon(item.icon, null, Modifier.size(20.dp)) },
                modifier = Modifier.testTag("nav-${item.destination.name.lowercase()}"))
        }
        NavigationDrawerItem(label = { Text("Usage") }, selected = usage, onClick = onUsage,
            icon = { Icon(Icons.Outlined.DataUsage, null, Modifier.size(20.dp)) }, modifier = Modifier.testTag("tablet-usage"))
    }
}

@Composable
internal fun TabletProjectNavigator(
    state: DieterUiState,
    model: DieterViewModel,
    modifier: Modifier = Modifier,
    onManage: () -> Unit = model::showBoardOverview,
    onOpenBoard: (String, String) -> Unit = model::openBoard,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var alphabetical by rememberSaveable { mutableStateOf(false) }
    val boards = state.spaceBoards.groupBy { it.projectId }
    val projects = state.projects.filter { project -> query.isBlank() || project.name.contains(query, true) ||
        boards[project.id].orEmpty().any { it.name.contains(query, true) } }
    val byId = projects.associateBy { it.id }
    val pinned = orderedPinnedProjects(projects, state.pinnedProjectOrder)
    val unfiled = state.projectFolders.unfiledIDs(projects.map { it.id }).mapNotNull(byId::get)
        .filterNot { it.id in state.pinnedProjectOrder }
    fun ordered(items: List<Project>) = if (alphabetical) items.sortedBy { it.name.lowercase() } else items
    Column(modifier.background(DieterSurface).semantics { paneTitle = "Projects" }.testTag("tablet-project-navigator")) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, top = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Projects", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                Text("${state.projects.size} projects · ${state.projectFolders.folders.size} folders", style = MaterialTheme.typography.bodySmall, color = DieterMuted)
            }
            IconToggleButton(checked = alphabetical, onCheckedChange = { alphabetical = it }) {
                Icon(Icons.Outlined.SortByAlpha, if (alphabetical) "Use synced project order" else "Sort projects A–Z")
            }
            IconButton(onClick = { model.openSurface(AppSurface.NEW_PROJECT) }) { Icon(Icons.Default.Add, "New project") }
        }
        NavigationSyncStatus(state)
        CompactSearchField(query, { query = it }, "Filter projects and boards")
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (pinned.isNotEmpty()) {
                item { ListSectionLabel("Pinned") }
                items(ordered(pinned), key = { "pinned-${it.id}" }) { TabletProjectRow(it, boards[it.id].orEmpty(), state, model, onOpenBoard) }
            }
            state.projectFolders.folders.forEach { folder ->
                val members = ordered(folder.itemIDs.mapNotNull(byId::get).filterNot { it.id in state.pinnedProjectOrder })
                if (query.isBlank() || members.isNotEmpty()) {
                    item(key = "folder-${folder.id}") {
                        NavigationFolderHeader(folder, members.size, NavigationFolderScope.PROJECTS, state.projectFolders,
                            model.navigationFolders, revealSearchResults = query.isNotBlank())
                    }
                    if (folder.isExpanded || query.isNotBlank()) items(members, key = { "folder-project-${it.id}" }) {
                        TabletProjectRow(it, boards[it.id].orEmpty(), state, model, onOpenBoard)
                    }
                }
            }
            if (unfiled.isNotEmpty()) {
                item { ListSectionLabel(if (pinned.isEmpty() && state.projectFolders.folders.isEmpty()) "All projects" else "Unfiled") }
                items(ordered(unfiled), key = { it.id }) { TabletProjectRow(it, boards[it.id].orEmpty(), state, model, onOpenBoard) }
            }
            if (projects.isEmpty()) item {
                Text(if (query.isBlank()) "Add a project to get started." else "No matching projects", color = DieterMuted, modifier = Modifier.padding(12.dp))
            }
            item {
                TextButton(onClick = onManage, modifier = Modifier.testTag("tablet-manage-projects")) { Text("Manage projects") }
            }
        }
    }
}

@Composable
private fun TabletProjectRow(project: Project, boards: List<Board>, state: DieterUiState, model: DieterViewModel, onOpenBoard: (String, String) -> Unit) {
    val selected = project.id == state.selectedProjectId
    var expanded by rememberSaveable(project.id, selected) { mutableStateOf(selected) }
    Surface(onClick = { expanded = !expanded }, color = if (selected) DieterShellTint else androidx.compose.ui.graphics.Color.Transparent,
        shape = RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth().testTag("tablet-project-row-${project.id}")) {
        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Surface(color = stableAccent(project.id), shape = RoundedCornerShape(10.dp), modifier = Modifier.size(32.dp)) {
                Box(contentAlignment = Alignment.Center) { Text(project.name.take(1).uppercase(), color = androidx.compose.ui.graphics.Color.White, fontWeight = FontWeight.Bold) }
            }
            Column(Modifier.weight(1f)) {
                Text(project.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${boards.size} ${plural(boards.size, "board")}", color = DieterMuted, style = MaterialTheme.typography.labelSmall)
            }
            Icon(if (expanded) Icons.Outlined.ExpandMore else Icons.Outlined.ChevronRight, if (expanded) "Collapse ${project.name}" else "Expand ${project.name}", Modifier.size(18.dp))
        }
    }
    if (expanded) {
        boards.forEach { board ->
            NavigationDrawerItem(label = { Text(board.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                selected = selected && board.id == state.selectedBoardId && !state.boardOverviewVisible,
                onClick = { onOpenBoard(project.id, board.id) }, icon = { Icon(Icons.Outlined.ViewKanban, null, Modifier.size(18.dp)) },
                modifier = Modifier.padding(start = 18.dp).testTag("tablet-board-${board.id}"))
        }
        if (boards.isEmpty()) TextButton(onClick = { model.openNewBoard(project.id) }, modifier = Modifier.padding(start = 24.dp)) { Text("Create board") }
    }
}

@Composable
internal fun SettingsAdaptiveLayout(
    selectedTab: Int,
    onSelect: (Int) -> Unit,
    onBack: () -> Unit,
    contentPadding: PaddingValues,
    content: @Composable ColumnScope.() -> Unit,
) {
    val labels = listOf("Connect", "Alerts", "Display", "Usage", "Updates")
    Column(Modifier.fillMaxSize().padding(contentPadding).testTag("app-settings")) {
        SettingsHeader(onBack)
        if (LocalTabletWorkspace.current) {
            Row(Modifier.weight(1f).fillMaxWidth()) {
                Column(Modifier.width(224.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(12.dp)
                    .testTag("tablet-settings-categories")) {
                    labels.forEachIndexed { index, label ->
                        NavigationDrawerItem(label = { Text(label) }, selected = selectedTab == index, onClick = { onSelect(index) },
                            modifier = Modifier.testTag("settings-${label.lowercase()}"),
                            icon = { Icon(listOf(Icons.Outlined.Wifi, Icons.Outlined.Notifications, Icons.Outlined.Palette,
                                Icons.Outlined.DataUsage, Icons.Outlined.SystemUpdate)[index], null, Modifier.size(20.dp)) })
                    }
                }
                VerticalDivider(color = DieterDivider)
                Column(Modifier.weight(1f).fillMaxHeight()) { content() }
            }
        } else {
            PrimaryScrollableTabRow(selectedTabIndex = selectedTab, edgePadding = 8.dp,
                containerColor = MaterialTheme.colorScheme.background, contentColor = DieterShell) {
                labels.forEachIndexed { index, label -> SettingsTab(label, selectedTab == index) { onSelect(index) } }
            }
            content()
        }
    }
}

@Composable
internal fun TabletActivityTimeline(
    intervals: List<ActivityInterval>,
    projectNames: Map<String, String>,
    hours: Int,
    live: Boolean,
    onHours: (Int) -> Unit,
    onOpen: (com.dbpprt.dieter.v1.Card) -> Unit,
    actions: (com.dbpprt.dieter.v1.Card) -> ActivityItemActions? = { null },
) {
    var visibleCount by rememberSaveable(hours) { mutableIntStateOf(40) }
    Column(Modifier.fillMaxWidth().testTag("tablet-activity-timeline"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Latest activity per conversation", style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(1, 6, 24).forEach { value ->
                FilterChip(selected = hours == value, onClick = { onHours(value) }, label = { Text("${value}h") }, modifier = Modifier.testTag("tablet-range-$value"))
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("−${hours}h", color = DieterMuted, style = MaterialTheme.typography.labelSmall)
            Text(if (live) "Now" else "Last sync", color = DieterMuted, style = MaterialTheme.typography.labelSmall)
        }
        intervals.take(visibleCount).groupBy { it.entry.card.projectId }.forEach { (projectId, activity) ->
            Surface(color = DieterSurface, shape = RoundedCornerShape(20.dp)) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(projectNames[projectId] ?: "Project unavailable", color = stableAccent(projectId), fontWeight = FontWeight.SemiBold)
                    activity.forEach { interval ->
                        val color = if (interval.entry.needsYou) DieterAmber else DieterShell
                        ActivityItem(card = interval.entry.card, onOpen = onOpen, actions = actions(interval.entry.card), color = DieterSurfaceHigh, shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.fillMaxWidth().testTag("tablet-activity-${interval.entry.card.id}")) {
                            Column(Modifier.padding(12.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                    Text(interval.entry.card.title, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                                    Text(interval.entry.kind.label, style = MaterialTheme.typography.labelSmall, color = color)
                                }
                                Text(interval.entry.detail, style = MaterialTheme.typography.bodySmall, color = DieterMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 10.dp).height(6.dp).background(DieterDivider, RoundedCornerShape(3.dp))) {
                                    val start = interval.from.coerceIn(0f, 1f)
                                    val end = interval.to.coerceIn(start, 1f)
                                    val barWidth = (maxWidth * (end - start)).coerceAtLeast(4.dp).coerceAtMost(maxWidth)
                                    Box(Modifier.offset(x = (maxWidth * start).coerceAtMost(maxWidth - barWidth)).width(barWidth).fillMaxHeight().background(color, RoundedCornerShape(3.dp)))
                                }
                            }
                        }
                    }
                }
            }
        }
        if (intervals.isEmpty()) Text("No activity in the last ${hours}h", color = DieterMuted, modifier = Modifier.padding(20.dp))
        if (intervals.size > visibleCount) TextButton(onClick = { visibleCount += 40 }) { Text("Show more conversations") }
        Text("Bars show recorded durations; short marks are events without a recorded duration.", style = MaterialTheme.typography.labelSmall, color = DieterMuted)
    }
}
