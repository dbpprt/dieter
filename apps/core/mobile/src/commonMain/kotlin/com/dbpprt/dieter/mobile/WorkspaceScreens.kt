@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.ExperimentalFoundationApi::class,
)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.mobile.icons.*
import kotlin.time.Clock
import kotlin.time.Instant
import kotlinx.coroutines.delay

@Composable
internal fun rememberNow(): Instant {
    var now by remember { mutableStateOf(Clock.System.now()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            now = Clock.System.now()
        }
    }
    return now
}

@Composable
internal fun InboxScreen(store: MobileStore) {
    val view by store.activity.collectAsState()
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val quotas by store.quotas.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var project by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf("All") }
    var timeline by rememberSaveable { mutableStateOf(true) }
    var actions by remember { mutableStateOf<Card?>(null) }
    val now = rememberNow()
    val rows =
        view.rows.filter { row ->
            (project.isEmpty() || row.card?.project_id == project) &&
                Activity.matches(query, row.title, row.project_name, row.board_name) &&
                when (filter) {
                    "Needs you" -> row.needs_you
                    "Running" -> row.kind == "RUNNING"
                    "Review" -> row.kind == "REVIEW"
                    else -> true
                }
        }
    Column {
        PageHeader(
            "Inbox",
            "${view.summary?.running ?: 0} running · ${view.summary?.attention ?: 0} need attention",
        ) {
            IconButton(onClick = { timeline = !timeline }) {
                Icon(Icons.Outlined.Timeline, "Activity timeline")
            }
            IconButton(onClick = { store.newConversation() }) {
                Icon(Icons.Outlined.Add, "New task")
            }
        }
        LazyColumn(
            Modifier.fillMaxSize().testTag("activity-feed"),
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ChoiceChip(
                        workspace.projects.firstOrNull { it.id == project }?.name ?: "All projects",
                        listOf("" to "All projects") + workspace.projects.map { it.id to it.name },
                    ) {
                        project = it
                    }
                    ChoiceChip(
                        filter,
                        listOf("All", "Needs you", "Running", "Review").map { it to it },
                    ) {
                        filter = it
                    }
                }
                MobileTextField(
                    query,
                    { query = it },
                    Modifier.fillMaxWidth(),
                    placeholder = { Text("Search activity") },
                    leadingIcon = { Icon(Icons.Outlined.Search, null) },
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp),
                )
            }
            item {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    ProjectTile("", "All", project.isEmpty()) { project = "" }
                    workspace.projects.forEach { value ->
                        ProjectTile(value.id, value.name, value.id == project) {
                            project = value.id
                        }
                    }
                }
            }
            if (quotas.group_rows.isNotEmpty())
                item {
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        quotas.group_rows.forEach { group ->
                            Surface(
                                onClick = { store.navigate(MobileTab.USAGE) },
                                color = colors.surfaceContainerHigh,
                                shape = RoundedCornerShape(10.dp),
                            ) {
                                Column(Modifier.padding(12.dp)) {
                                    Text(
                                        group.provider_name,
                                        style = MaterialTheme.typography.labelMedium,
                                    )
                                    Text(
                                        if (group.lowest_remaining >= 0)
                                            "${group.lowest_remaining}% remaining"
                                        else group.summary,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = colors.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                    }
                }
            if (timeline) item { ActivityTimeline(rows, now) { id -> store.openCard(id) } }
            if (rows.isEmpty())
                item {
                    Box(Modifier.height(230.dp)) {
                        Empty(
                            if (workspace.loaded) "All quiet here" else "Loading activity…",
                            if (query.isNotBlank()) "No matching conversations."
                            else "Running work and replies appear here.",
                        )
                    }
                }
            ActivityRow.Section.entries.forEach { section ->
                val sectionRows = rows.filter { it.section == section }
                if (sectionRows.isNotEmpty())
                    item {
                        Text(
                            when (section) {
                                ActivityRow.Section.SECTION_ATTENTION -> "Needs attention"
                                ActivityRow.Section.SECTION_RUNNING -> "Running"
                                else -> "Recent"
                            },
                            style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
                        )
                    }
                items(sectionRows, key = { it.card?.id.orEmpty() }) { row ->
                    val card = row.card ?: return@items
                    val tint =
                        if (row.kind == "FAILED") colors.error
                        else if (row.needs_you) colors.tertiary else colors.secondary
                    Surface(
                        shape = RoundedCornerShape(14.dp),
                        color = colors.surface,
                        border = BorderStroke(1.dp, colors.outline.copy(alpha = .45f)),
                        modifier =
                            Modifier.fillMaxWidth()
                                .combinedClickable(
                                    onClick = { store.openCard(card.id) },
                                    onLongClick = { actions = card },
                                )
                                .testTag("activity-row-${card.id}"),
                    ) {
                        Column(
                            Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            Row(verticalAlignment = Alignment.Top) {
                                Text(
                                    row.title,
                                    Modifier.weight(1f),
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    Activity.age(
                                        row.shown_at_millis
                                            .takeIf { it > 0 }
                                            ?.let(Instant::fromEpochMilliseconds),
                                        now,
                                        suffix = true,
                                    ),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = colors.onSurfaceVariant,
                                )
                            }
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Text(
                                    listOf(
                                            row.project_name,
                                            row.board_name,
                                            if (row.chat) "Chat" else "Card",
                                        )
                                        .filter { it.isNotEmpty() }
                                        .joinToString(" · "),
                                    Modifier.weight(1f),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = colors.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                CompactBadge(
                                    session.machines
                                        .firstOrNull { it.id == card.owner_daemon_id }
                                        ?.display_name ?: "Unassigned",
                                    Icons.Outlined.Computer,
                                )
                            }
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Box(Modifier.size(6.dp).background(tint, CircleShape))
                                Text(
                                    row.detail.ifEmpty { row.kind_label },
                                    Modifier.weight(1f),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = tint,
                                    maxLines = 2,
                                )
                                if (row.can_finish)
                                    TextButton(
                                        onClick = {
                                            store.command(
                                                Command(finish_card = FinishCard(card.id))
                                            )
                                        }
                                    ) {
                                        Text("Finish")
                                    }
                            }
                            if (row.stale.isNotEmpty())
                                Text(
                                    row.stale,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = colors.tertiary,
                                )
                        }
                    }
                }
            }
        }
    }
    actions?.let { CardActions(store, it) { actions = null } }
}

@Composable
private fun ActivityTimeline(rows: List<ActivityRow>, now: Instant, onOpen: (String) -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .background(colors.surfaceContainerHigh, RoundedCornerShape(14.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(Activity.rangeTitle(24), style = MaterialTheme.typography.titleSmall)
        rows.forEach { row ->
            val span =
                Activity.span(
                    row.started_at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
                    row.at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
                    row.kind == "RUNNING",
                    now,
                    24,
                ) ?: return@forEach
            Row(
                Modifier.fillMaxWidth().clickable { row.card?.id?.let(onOpen) },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    row.title,
                    Modifier.width(130.dp),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.labelSmall,
                )
                BoxWithConstraints(Modifier.weight(1f).height(20.dp)) {
                    Box(
                        Modifier.offset(x = maxWidth * span.from.toFloat())
                            .width((maxWidth * (span.to - span.from).toFloat()).coerceAtLeast(5.dp))
                            .height(8.dp)
                            .align(Alignment.CenterStart)
                            .background(colors.secondary, RoundedCornerShape(4.dp))
                    )
                }
            }
        }
    }
}

@Composable
internal fun ProjectsScreen(store: MobileStore) {
    val workspace by store.workspace.collectAsState()
    val navigation by store.navigation.collectAsState()
    var search by rememberSaveable { mutableStateOf("") }
    var create by remember { mutableStateOf(false) }
    var folder by remember { mutableStateOf<NavigationFolder?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    var actions by remember { mutableStateOf("") }
    val layout = navigation.projects
    val order = layout?.order.orEmpty().ifEmpty { workspace.projects.map { it.id } }
    fun matches(id: String) =
        workspace.projects.firstOrNull { it.id == id }?.name?.contains(search, true) == true ||
            workspace.boards.any { it.project_id == id && it.name.contains(search, true) }
    Column {
        PageHeader(
            "Projects",
            "${workspace.projects.size} projects · ${layout?.folders?.size ?: 0} folders · ${if (navigation.caught_up) "synced" else "syncing"}",
        ) {
            IconButton(onClick = { newFolder = true }) {
                Icon(Icons.Outlined.CreateNewFolder, "New project folder")
            }
            IconButton(onClick = { create = true }) { Icon(Icons.Outlined.Add, "New project") }
        }
        MobileTextField(
            search,
            { search = it },
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            placeholder = { Text("Search projects") },
            leadingIcon = { Icon(Icons.Outlined.Search, null) },
            singleLine = true,
            shape = RoundedCornerShape(12.dp),
        )
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (layout?.pinned?.isNotEmpty() == true && search.isEmpty()) {
                item {
                    Text(
                        "PINNED",
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.onSurfaceVariant,
                    )
                }
                item {
                    Row(
                        Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        layout?.pinned.orEmpty().forEach { id ->
                            Box(Modifier.width(280.dp)) {
                                ProjectCard(store, id, true) { actions = id }
                            }
                        }
                    }
                }
                item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            }
            item {
                Text(
                    "ALL PROJECTS",
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.onSurfaceVariant,
                )
            }
            layout?.folders.orEmpty().forEach { group ->
                val ids = group.item_ids.filter { matches(it) }
                if (search.isEmpty() || ids.isNotEmpty() || group.name.contains(search, true)) {
                    item("folder-${group.id}") {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = colors.surfaceContainerHigh,
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                IconButton(
                                    onClick = {
                                        store.command(
                                            Command(
                                                navigation =
                                                    NavigationCommand(
                                                        set_folder_expanded =
                                                            SetFolderExpanded(
                                                                FolderScope.FOLDER_SCOPE_PROJECTS,
                                                                group.id,
                                                                !group.expanded,
                                                            )
                                                    )
                                            )
                                        )
                                    }
                                ) {
                                    Icon(
                                        if (group.expanded) Icons.Outlined.ExpandMore
                                        else Icons.Outlined.ChevronRight,
                                        "Expand folder",
                                    )
                                }
                                Icon(Icons.Outlined.Folder, null)
                                Text(
                                    group.name,
                                    Modifier.weight(1f).padding(8.dp),
                                    style = MaterialTheme.typography.titleMedium,
                                )
                                Text(
                                    "${group.item_ids.size}",
                                    style = MaterialTheme.typography.labelSmall,
                                )
                                IconButton(onClick = { folder = group }) {
                                    Icon(Icons.Outlined.MoreVert, "Folder actions")
                                }
                            }
                        }
                    }
                    if (group.expanded || search.isNotEmpty())
                        items(ids, key = { it }) { id ->
                            Box(Modifier.padding(start = 16.dp)) {
                                ProjectCard(store, id, false) { actions = id }
                            }
                        }
                }
            }
            items((layout?.unfiled ?: order).filter { matches(it) }, key = { it }) { id ->
                ProjectCard(store, id, false) { actions = id }
            }
            if (order.isEmpty() && workspace.loaded)
                item {
                    Box(Modifier.height(200.dp)) {
                        Empty(
                            "No projects yet",
                            "Add a Git repository from one of your enrolled machines.",
                        )
                    }
                }
        }
    }
    if (create) ProjectEditor(store) { create = false }
    if (newFolder || folder != null)
        FolderEditor(store, FolderScope.FOLDER_SCOPE_PROJECTS, folder) {
            newFolder = false
            folder = null
        }
    if (actions.isNotEmpty()) ProjectActions(store, actions) { actions = "" }
}

@Composable
private fun ProjectCard(store: MobileStore, id: String, pinned: Boolean, onActions: () -> Unit) {
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val navigation by store.navigation.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == id } ?: return
    val boards = workspace.boards.filter { it.project_id == id }
    val open = pinned || id in navigation.expanded_projects
    Surface(
        shape = RoundedCornerShape(if (pinned) 22.dp else 14.dp),
        color = colors.surfaceContainerHigh,
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.fillMaxWidth().clickable {
                    store.command(Command(set_project_expanded = SetProjectExpanded(id, !open)))
                },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(42.dp)
                        .background(
                            labelColor(com.dbpprt.dieter.core.admin.Labels.stable(id)),
                            RoundedCornerShape(12.dp),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        project.name.take(1).lowercase(),
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                    Text(project.name, style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (project.checkouts.isEmpty()) "No checkouts"
                        else
                            project.checkouts
                                .map { checkout ->
                                    session.machines
                                        .firstOrNull { it.id == checkout.daemon_id }
                                        ?.display_name ?: checkout.name
                                }
                                .distinct()
                                .joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                    )
                }
                IconButton(onClick = onActions) { Icon(Icons.Outlined.MoreVert, "Project actions") }
            }
            if (open)
                boards.forEach { board ->
                    Surface(
                        onClick = {
                            store.chooseBoard(board.id)
                            store.tab.value = MobileTab.BOARD
                        },
                        shape = RoundedCornerShape(10.dp),
                        color = colors.surface,
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Outlined.ViewKanban,
                                null,
                                tint =
                                    labelColor(
                                        com.dbpprt.dieter.core.admin.Labels.stable(board.id)
                                    ),
                                modifier = Modifier.size(22.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                board.name,
                                Modifier.weight(1f),
                                style = MaterialTheme.typography.titleSmall,
                            )
                            Text(
                                "${workspace.cards.count { it.board_id == board.id }} cards",
                                style = MaterialTheme.typography.labelSmall,
                            )
                            if ((workspace.board_attention[board.id] ?: 0) > 0)
                                Badge { Text("${workspace.board_attention[board.id]}") }
                            Icon(Icons.Outlined.ChevronRight, null, Modifier.size(20.dp))
                        }
                    }
                }
            if (open)
                Row(Modifier.horizontalScroll(rememberScrollState())) {
                    TextButton(
                        onClick = {
                            store.selectedProject.value = id
                            store.navigate(MobileTab.FILES)
                        }
                    ) {
                        Text("Files")
                    }
                    TextButton(
                        onClick = {
                            store.selectedProject.value = id
                            store.navigate(MobileTab.PROJECT_CHANGES)
                        }
                    ) {
                        Text("Changes")
                    }
                    TextButton(
                        onClick = {
                            store.selectedProject.value = id
                            store.navigate(MobileTab.SCHEDULES)
                        }
                    ) {
                        Text("Schedules")
                    }
                }
        }
    }
}

@Composable
private fun ProjectTile(id: String, name: String, selected: Boolean, open: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(64.dp)) {
        Surface(
            onClick = open,
            shape = RoundedCornerShape(19.dp),
            color =
                if (id.isEmpty()) colors.surfaceContainerHigh
                else labelColor(com.dbpprt.dieter.core.admin.Labels.stable(id)),
            border = if (selected) BorderStroke(2.dp, colors.onSurface) else null,
            modifier = Modifier.size(58.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                if (id.isEmpty()) Icon(Icons.Outlined.Timeline, null)
                else
                    Text(
                        name.take(1).lowercase(),
                        color = Color.White,
                        style = MaterialTheme.typography.headlineSmall,
                    )
            }
        }
        Text(
            name,
            Modifier.padding(top = 6.dp),
            style = MaterialTheme.typography.labelSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
internal fun ChatsScreen(store: MobileStore) {
    val workspace by store.workspace.collectAsState()
    val view by store.chats.collectAsState()
    val session by store.session.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var archived by rememberSaveable { mutableStateOf(false) }
    var actions by remember { mutableStateOf<Card?>(null) }
    Column {
        PageHeader("Chats", "Standalone conversations") {
            IconButton(
                onClick = {
                    archived = !archived
                    store.command(
                        Command(
                            chats =
                                ChatsCommand(
                                    scope = MobileStore.CHATS_SCOPE,
                                    show_archived = Toggle(archived),
                                )
                        )
                    )
                }
            ) {
                Icon(
                    Icons.Outlined.Archive,
                    if (archived) "Show live chats" else "Show archived chats",
                )
            }
            IconButton(onClick = { store.newConversation(chat = true) }) {
                Icon(Icons.Outlined.Add, "New chat")
            }
        }
        MobileTextField(
            query,
            {
                query = it
                store.command(
                    Command(
                        chats =
                            ChatsCommand(scope = MobileStore.CHATS_SCOPE, query = ChatsQuery(it))
                    )
                )
            },
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            placeholder = { Text("Search chats") },
            leadingIcon = { Icon(Icons.Outlined.Search, null) },
            singleLine = true,
            shape = RoundedCornerShape(12.dp),
        )
        LazyColumn(
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            fun LazyListScope.chatRows(ids: List<String>) {
                items(ids, key = { it }) { id ->
                    (if (archived) view.archived else workspace.cards)
                        .firstOrNull { it.id == id }
                        ?.let { card ->
                            WorkCard(
                                store,
                                card,
                                null,
                                machine =
                                    session.machines
                                        .firstOrNull { it.id == card.owner_daemon_id }
                                        ?.display_name ?: "Unassigned",
                                onActions = { actions = card },
                            )
                            if (archived)
                                TextButton(
                                    onClick = {
                                        store.command(
                                            Command(restore_card = RestoreCard(card_id = id))
                                        )
                                    }
                                ) {
                                    Text("Restore chat")
                                }
                        }
                }
            }
            if (view.pinned_ids.isNotEmpty()) {
                item { Text("Pinned", style = MaterialTheme.typography.titleSmall) }
                chatRows(view.pinned_ids)
            }
            view.folders.forEach { folder ->
                item {
                    TextButton(
                        onClick = {
                            store.command(
                                Command(
                                    navigation =
                                        NavigationCommand(
                                            set_folder_expanded =
                                                SetFolderExpanded(
                                                    FolderScope.FOLDER_SCOPE_CHATS,
                                                    folder.folder_id,
                                                    !folder.expanded,
                                                )
                                        )
                                )
                            )
                        }
                    ) {
                        Icon(Icons.Outlined.Folder, null)
                        Spacer(Modifier.width(8.dp))
                        Text(folder.name)
                    }
                }
                if (folder.show_chats) chatRows(folder.chat_ids)
            }
            view.projects.forEach { section ->
                item {
                    TextButton(
                        onClick = {
                            store.command(
                                Command(
                                    set_chat_section_collapsed =
                                        SetChatSectionCollapsed(
                                            project_id = section.project_id,
                                            collapsed = !section.collapsed,
                                        )
                                )
                            )
                        }
                    ) {
                        Text(
                            workspace.projects.firstOrNull { it.id == section.project_id }?.name
                                ?: "Project"
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("${section.total}")
                    }
                }
                if (section.show_chats) chatRows(section.chat_ids)
                if (section.toggle_label.isNotEmpty())
                    item {
                        TextButton(
                            onClick = {
                                store.command(
                                    Command(
                                        set_chats_show_all =
                                            SetChatsShowAll(
                                                project_id = section.project_id,
                                                show_all = !section.show_all,
                                            )
                                    )
                                )
                            }
                        ) {
                            Text(section.toggle_label)
                        }
                    }
            }
            chatRows(view.other_ids)
            if (view.visible_ids.isEmpty())
                item {
                    Box(Modifier.height(220.dp)) {
                        Empty(
                            if (archived) "No archived chats" else "No chats yet",
                            "Start a conversation in one of your projects.",
                        )
                    }
                }
        }
    }
    actions?.let { CardActions(store, it) { actions = null } }
}
