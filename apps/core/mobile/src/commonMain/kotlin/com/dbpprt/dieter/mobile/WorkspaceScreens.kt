@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.board.CardAges
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

/** Reusable "New task" / "New chat" command. */
internal fun newTaskAction(store: MobileStore, chat: Boolean = false) =
    ChromeAction(
        if (chat) "new-chat" else "new-task",
        if (chat) "New chat" else "New task",
        Glyph.COMPOSE,
        onClick = { store.newConversation(chat) },
    )

// ---------------------------------------------------------------------------------------------
// Inbox
// ---------------------------------------------------------------------------------------------

private enum class InboxFilter(val title: String) {
    ALL("All"),
    NEEDS_YOU("Needs you"),
    RUNNING("Running"),
    REVIEW("Review"),
}

@Composable
internal fun InboxScreen(store: MobileStore) {
    val view by store.activity.collectAsState()
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val quotas by store.quotas.collectAsState()
    val selected by store.selectedCard.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var project by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(InboxFilter.ALL) }
    var timeline by rememberSaveable { mutableStateOf(false) }
    val now = rememberNow()
    val scoped =
        view.rows.filter { row ->
            (project.isEmpty() || row.card?.project_id == project) &&
                Activity.matches(query, row.title, row.project_name, row.board_name)
        }
    fun count(value: InboxFilter) = scoped.count { it.matches(value) }
    val rows = scoped.filter { it.matches(filter) }
    val running = view.summary?.running ?: 0
    val attention = view.summary?.attention ?: 0
    val projectName = workspace.projects.firstOrNull { it.id == project }?.name
    val chrome =
        ScreenChrome(
            "Inbox",
            subtitle =
                listOfNotNull(
                        projectName,
                        when {
                            attention > 0 && running > 0 -> "$attention need you · $running running"
                            attention > 0 -> "$attention need you"
                            running > 0 -> "$running running"
                            workspace.loaded -> "All caught up"
                            else -> null
                        },
                    )
                    .joinToString(" · "),
            large = true,
            actions =
                listOf(
                    ChromeAction(
                        "inbox-filter",
                        "Filter",
                        Glyph.FILTER,
                        menu =
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "project-all",
                                            "All projects",
                                            checked = project.isEmpty(),
                                        ) {
                                            project = ""
                                        }
                                    ) +
                                        workspace.projects.map { item ->
                                            ChromeAction(
                                                "project-${item.id}",
                                                item.name,
                                                checked = item.id == project,
                                            ) {
                                                project = item.id
                                            }
                                        },
                                    title = "Project",
                                ),
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "timeline",
                                            "Activity timeline",
                                            Glyph.TIMELINE,
                                            checked = timeline,
                                        ) {
                                            timeline = !timeline
                                        }
                                    )
                                ),
                            ),
                    )
                ),
            primary = newTaskAction(store),
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("activity-feed"),
            state = listState,
            contentPadding = padding,
        ) {
            titleHeader()
            item("notice") { ConnectionNotice(store) }
            item("search") {
                SearchField(
                    query,
                    { query = it },
                    "Search activity",
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                )
            }
            item("filters") {
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = ScreenMargin, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    InboxFilter.entries.forEach { value ->
                        val total = count(value)
                        FilterPill(
                            if (value == InboxFilter.ALL || total == 0) value.title
                            else "${value.title} $total",
                            filter == value,
                            { filter = value },
                            Modifier.testTag("inbox-filter-${value.name.lowercase()}"),
                        )
                    }
                }
            }
            if (quotas.group_rows.any { it.lowest_remaining >= 0 })
                item("usage") {
                    UsageStrip(quotas) {
                        store.showFrom(
                            MobileRoute.Root(MobileTab.INBOX),
                            MobileRoute.Tool(ToolPage.USAGE),
                        )
                    }
                }
            if (timeline && rows.isNotEmpty())
                item("timeline") { ActivityTimeline(rows, now) { store.openConversation(it) } }
            if (rows.isEmpty())
                item("empty") {
                    EmptyState(
                        if (query.isNotBlank()) Glyph.SEARCH else Glyph.INBOX,
                        when {
                            !workspace.loaded -> "Loading activity…"
                            query.isNotBlank() -> "No results"
                            filter != InboxFilter.ALL -> "Nothing here"
                            else -> "All quiet"
                        },
                        when {
                            query.isNotBlank() -> "No conversations match “$query”."
                            filter == InboxFilter.NEEDS_YOU ->
                                "Nothing needs your attention right now."
                            else -> "Running work, replies and reviews appear here."
                        },
                        Modifier.padding(top = 32.dp),
                    )
                }
            ActivityRow.Section.entries.forEach { section ->
                val sectionRows = rows.filter { it.section == section && it.card != null }
                if (sectionRows.isNotEmpty()) {
                    item("header-$section") {
                        SectionHeader(
                            when (section) {
                                ActivityRow.Section.SECTION_ATTENTION -> "Needs you"
                                ActivityRow.Section.SECTION_RUNNING -> "Running"
                                else -> "Recent"
                            },
                            prominent = true,
                        )
                    }
                    itemsIndexed(sectionRows, key = { _, row -> "row-" + row.card!!.id }) {
                        index,
                        row ->
                        InboxRow(
                            store,
                            row,
                            now,
                            Position.of(index, sectionRows.size),
                            selected = row.card!!.id == selected,
                            machine =
                                session.machines
                                    .takeIf { it.size > 1 }
                                    ?.firstOrNull { it.id == row.card?.owner_daemon_id }
                                    ?.display_name,
                        )
                    }
                }
            }
        }
    }
}

private fun ActivityRow.matches(filter: InboxFilter) =
    when (filter) {
        InboxFilter.ALL -> true
        InboxFilter.NEEDS_YOU -> needs_you
        InboxFilter.RUNNING -> kind == "RUNNING"
        InboxFilter.REVIEW -> kind == "REVIEW"
    }

@Composable
private fun InboxRow(
    store: MobileStore,
    row: ActivityRow,
    now: Instant,
    position: Position,
    selected: Boolean,
    machine: String?,
) {
    val card = row.card ?: return
    val menu = rememberMenuState()
    val tint =
        when {
            row.kind == "FAILED" -> palette.destructive
            row.needs_you -> palette.warning
            row.kind == "RUNNING" -> palette.info
            row.kind == "REVIEW" -> palette.purple
            else -> palette.tertiaryLabel
        }
    MenuAnchor(menu) {
        GroupItem(
            position,
            Modifier.testTag("activity-row-${card.id}"),
            separatorInset = 36.dp,
            onClick = { store.openConversation(card.id) },
            onLongClick = { menu.show(cardMenuSections(store, card, row.can_finish)) },
            selected = selected,
        ) {
            Row(
                Modifier.fillMaxWidth()
                    .padding(start = 14.dp, end = 14.dp, top = 11.dp, bottom = 11.dp)
            ) {
                Box(
                    Modifier.width(22.dp).padding(top = 5.dp),
                    contentAlignment = Alignment.TopCenter,
                ) {
                    if (row.kind == "RUNNING") LiveDot(tint, size = 10.dp)
                    else Box(Modifier.size(9.dp).background(tint, CircleShape))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.Top) {
                        Text(
                            row.title,
                            Modifier.weight(1f),
                            style =
                                if (row.needs_you) type.headline
                                else type.bodyEmphasized.copy(fontWeight = FontWeight.Medium),
                            color = palette.label,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            Activity.age(
                                row.shown_at_millis
                                    .takeIf { it > 0 }
                                    ?.let(Instant::fromEpochMilliseconds),
                                now,
                                suffix = false,
                            ),
                            Modifier.padding(start = 8.dp, top = 2.dp),
                            style = type.footnote,
                            color = palette.secondaryLabel,
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (row.chat) {
                            Icon(Glyph.CHAT, "Chat", tint = palette.secondaryLabel, size = 13.dp)
                            Spacer(Modifier.width(4.dp))
                        }
                        Text(
                            listOfNotNull(
                                    row.project_name.ifEmpty { null },
                                    row.board_name.ifEmpty { null },
                                    machine,
                                )
                                .joinToString(" · "),
                            style = type.subheadline,
                            color = palette.secondaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    val detail = row.detail.ifEmpty { row.kind_label }
                    if (detail.isNotEmpty())
                        Text(
                            detail,
                            style = type.subheadline,
                            color =
                                if (row.needs_you || row.kind == "FAILED")
                                    tint.readableOn(palette.cell)
                                else palette.secondaryLabel,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    if (row.stale.isNotEmpty())
                        Text(
                            row.stale,
                            style = type.footnote,
                            color = palette.warning.readableOn(palette.cell),
                        )
                    if (row.can_finish)
                        DButton(
                            "Mark done",
                            { store.command(Command(finish_card = FinishCard(card.id))) },
                            Modifier.padding(top = 6.dp).testTag("finish-${card.id}"),
                            kind = ButtonKind.TONAL,
                            glyph = Glyph.CHECK,
                        )
                }
            }
        }
    }
}

@Composable
private fun UsageStrip(quotas: QuotasSlice, open: () -> Unit) {
    val groups = quotas.group_rows.filter { it.lowest_remaining >= 0 }
    Row(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 6.dp)
            .clip(RoundedCornerShape(if (apple) 18.dp else 16.dp))
            .background(palette.cell)
            .pressable(onClick = open, highlight = true)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(Glyph.USAGE, null, tint = palette.secondaryLabel, size = 20.dp)
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            groups.take(3).forEach { group ->
                val low = group.lowest_remaining < 20
                Column(Modifier.weight(1f)) {
                    Text(
                        group.provider_name,
                        style = type.caption,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                    )
                    Spacer(Modifier.height(4.dp))
                    ProgressBar(
                        group.lowest_remaining / 100f,
                        color = if (low) palette.warning else palette.success,
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(
                        "${group.lowest_remaining}% left",
                        style = type.caption.copy(fontWeight = FontWeight.Medium),
                        color = palette.label,
                    )
                }
            }
        }
        if (apple)
            Icon(
                Glyph.CHEVRON_RIGHT,
                null,
                tint = palette.tertiaryLabel,
                size = 13.dp,
                weight = GlyphWeight.SEMIBOLD,
            )
    }
}

@Composable
private fun ActivityTimeline(rows: List<ActivityRow>, now: Instant, onOpen: (String) -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 6.dp)
            .clip(RoundedCornerShape(if (apple) 22.dp else 20.dp))
            .background(palette.cell)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row {
            Text("Last 24 hours", Modifier.weight(1f), style = type.headline, color = palette.label)
            Text("Now", style = type.caption, color = palette.secondaryLabel)
        }
        rows.take(12).forEach { row ->
            val span =
                Activity.span(
                    row.started_at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
                    row.at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
                    row.kind == "RUNNING",
                    now,
                    24,
                ) ?: return@forEach
            val tint =
                if (row.kind == "RUNNING") palette.info
                else if (row.needs_you) palette.warning else palette.secondaryLabel
            Row(
                Modifier.fillMaxWidth().pressable(onClick = { row.card?.id?.let(onOpen) }),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    row.title,
                    Modifier.width(118.dp),
                    style = type.footnote,
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.width(10.dp))
                BoxWithConstraints(
                    Modifier.weight(1f).height(16.dp).clip(CircleShape).background(palette.fill)
                ) {
                    Box(
                        Modifier.offset(x = maxWidth * span.from.toFloat())
                            .width((maxWidth * (span.to - span.from).toFloat()).coerceAtLeast(6.dp))
                            .fillMaxHeight()
                            .clip(CircleShape)
                            .background(tint)
                    )
                }
            }
        }
    }
}

/** Long-press and "…" actions shared by inbox rows, chats and board cards. */
internal fun cardMenuSections(
    store: MobileStore,
    card: Card,
    canFinish: Boolean = false,
    onEdit: ((Card) -> Unit)? = null,
): List<MenuSection> {
    val workspace = store.workspace.value
    val board = workspace.boards.firstOrNull { it.id == card.board_id }
    val chat = card.scope == "chat"
    val primary = buildList {
        add(ChromeAction("open-${card.id}", "Open", Glyph.CHAT) { store.openConversation(card.id) })
        if (canFinish)
            add(
                ChromeAction("finish-${card.id}", "Mark done", Glyph.TASK_DONE) {
                    store.command(Command(finish_card = FinishCard(card.id)))
                }
            )
        if (chat)
            add(
                ChromeAction("pin-${card.id}", if (card.pinned) "Unpin" else "Pin", Glyph.PIN) {
                    store.command(Command(set_card_pinned = SetCardPinned(card.id, !card.pinned)))
                }
            )
        if (onEdit != null)
            add(ChromeAction("edit-${card.id}", "Edit…", Glyph.EDIT) { onEdit(card) })
    }
    val organize =
        if (chat || board == null) emptyList()
        else
            listOf(
                ChromeAction(
                    "move-${card.id}",
                    "Move to",
                    Glyph.MOVE,
                    menu =
                        listOf(
                            MenuSection(
                                board.lanes.map { lane ->
                                    ChromeAction(
                                        "lane-${lane.id}",
                                        lane.name,
                                        checked = lane.id == card.lane,
                                        enabled = lane.id != card.lane,
                                    ) {
                                        store.command(
                                            Command(move_card = MoveCard(card.id, lane.id))
                                        )
                                    }
                                }
                            )
                        ),
                ),
                ChromeAction(
                    "labels-${card.id}",
                    "Labels",
                    Glyph.LABEL,
                    enabled = board.labels.isNotEmpty(),
                    menu =
                        listOf(
                            MenuSection(
                                board.labels.map { label ->
                                    ChromeAction(
                                        "label-${label.id}",
                                        label.name,
                                        checked = label.id in card.label_ids,
                                    ) {
                                        store.command(
                                            Command(
                                                set_card_labels =
                                                    SetCardLabels(
                                                        card.id,
                                                        if (label.id in card.label_ids)
                                                            card.label_ids - label.id
                                                        else card.label_ids + label.id,
                                                    )
                                            )
                                        )
                                    }
                                }
                            )
                        ),
                ),
            )
    val more =
        listOf(
            ChromeAction("fork-${card.id}", "Fork conversation", Glyph.FORK) {
                store.action {
                    val fork =
                        store.core.dispatch(Command(fork_card = ForkCard(card.id))).card
                            ?: return@action
                    store.openConversation(fork.id)
                }
            },
            ChromeAction("archive-${card.id}", "Archive", Glyph.ARCHIVE, destructive = true) {
                store.command(Command(archive_card = ArchiveCard(card.id)))
                if (store.selectedCard.value == card.id) store.pop()
            },
        )
    return listOf(MenuSection(primary), MenuSection(organize), MenuSection(more)).filter {
        it.actions.isNotEmpty()
    }
}

// ---------------------------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------------------------

@Composable
internal fun ProjectsScreen(store: MobileStore) {
    val workspace by store.workspace.collectAsState()
    val navigation by store.navigation.collectAsState()
    val session by store.session.collectAsState()
    var search by rememberSaveable { mutableStateOf("") }
    var create by remember { mutableStateOf(false) }
    var editFolder by remember { mutableStateOf<NavigationFolder?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    val layout = navigation.projects
    val order = layout?.order.orEmpty().ifEmpty { workspace.projects.map { it.id } }
    fun matches(id: String) =
        search.isBlank() ||
            workspace.projects.firstOrNull { it.id == id }?.name?.contains(search, true) == true ||
            workspace.boards.any { it.project_id == id && it.name.contains(search, true) }
    val chrome =
        ScreenChrome(
            "Projects",
            subtitle =
                if (workspace.projects.isEmpty()) ""
                else
                    "${workspace.projects.size} project${if (workspace.projects.size == 1) "" else "s"}" +
                        if (!navigation.caught_up) " · Syncing…" else "",
            large = true,
            actions =
                listOf(
                    ChromeAction(
                        "projects-add",
                        "Add",
                        Glyph.ADD,
                        menu =
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "new-project",
                                            "New project",
                                            Glyph.FOLDER_ADD,
                                        ) {
                                            create = true
                                        },
                                        ChromeAction("new-folder", "New folder", Glyph.FOLDER) {
                                            newFolder = true
                                        },
                                    )
                                )
                            ),
                    )
                ),
            primary = newTaskAction(store),
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("projects-list"),
            state = listState,
            contentPadding = padding,
        ) {
            titleHeader()
            item("notice") { ConnectionNotice(store) }
            item("search") {
                SearchField(
                    search,
                    { search = it },
                    "Search projects and boards",
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                )
            }
            val pinned = layout?.pinned.orEmpty().filter(::matches)
            if (pinned.isNotEmpty()) {
                item("pinned-header") { SectionHeader("Pinned", prominent = true) }
                pinned.forEach { id -> projectGroup(store, id, "pinned") }
            }
            layout?.folders.orEmpty().forEach { folder ->
                val ids = folder.item_ids.filter(::matches)
                if (search.isNotBlank() && ids.isEmpty()) return@forEach
                item("folder-${folder.id}") {
                    FolderHeader(store, folder, onEdit = { editFolder = folder })
                }
                if (folder.expanded || search.isNotBlank())
                    ids.forEach { id -> projectGroup(store, id, "folder-${folder.id}") }
            }
            val unfiled = (layout?.unfiled ?: order).filter(::matches)
            if (unfiled.isNotEmpty()) {
                if (pinned.isNotEmpty() || layout?.folders.orEmpty().isNotEmpty())
                    item("all-header") { SectionHeader("All projects", prominent = true) }
                unfiled.forEach { id -> projectGroup(store, id, "unfiled") }
            }
            if (order.isEmpty() && workspace.loaded)
                item("empty") {
                    EmptyState(
                        Glyph.FOLDER_ADD,
                        "No projects yet",
                        if (session.machines.isEmpty())
                            "Enroll a machine, then add one of its Git repositories."
                        else "Add a Git repository from one of your machines.",
                        Modifier.padding(top = 40.dp),
                    ) {
                        DButton("New project", { create = true }, glyph = Glyph.ADD)
                    }
                }
            if (search.isNotBlank() && order.none(::matches))
                item("no-results") {
                    EmptyState(
                        Glyph.SEARCH,
                        "No results",
                        "No projects or boards match “$search”.",
                        Modifier.padding(top = 32.dp),
                    )
                }
        }
    }
    if (create) ProjectEditor(store) { create = false }
    if (newFolder)
        FolderEditor(store, FolderScope.FOLDER_SCOPE_PROJECTS, null) { newFolder = false }
    editFolder?.let { folder ->
        FolderEditor(store, FolderScope.FOLDER_SCOPE_PROJECTS, folder) { editFolder = null }
    }
}

@Composable
private fun FolderHeader(store: MobileStore, folder: NavigationFolder, onEdit: () -> Unit) {
    val menu = rememberMenuState()
    MenuAnchor(menu) {
        Row(
            Modifier.fillMaxWidth()
                .padding(top = 14.dp)
                .pressable(
                    onClick = {
                        store.command(
                            Command(
                                navigation =
                                    NavigationCommand(
                                        set_folder_expanded =
                                            SetFolderExpanded(
                                                FolderScope.FOLDER_SCOPE_PROJECTS,
                                                folder.id,
                                                !folder.expanded,
                                            )
                                    )
                            )
                        )
                    },
                    onLongClick = {
                        menu.show(
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "edit-folder",
                                            "Rename or delete…",
                                            Glyph.EDIT,
                                            onClick = onEdit,
                                        )
                                    )
                                )
                            )
                        )
                    },
                )
                .padding(
                    start = ScreenMargin + 4.dp,
                    end = ScreenMargin + 4.dp,
                    top = 6.dp,
                    bottom = 8.dp,
                )
                .testTag("folder-${folder.id}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Glyph.FOLDER,
                null,
                tint =
                    palette.accent.takeIf { !apple || it != Color.Black } ?: palette.secondaryLabel,
                size = 20.dp,
            )
            Spacer(Modifier.width(10.dp))
            Text(
                folder.name,
                Modifier.weight(1f),
                style = type.title3,
                color = palette.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${folder.item_ids.size}",
                style = type.subheadline,
                color = palette.secondaryLabel,
            )
            Spacer(Modifier.width(8.dp))
            DisclosureChevron(folder.expanded)
        }
    }
}

/** A project as a grouped section: header row, then its boards. */
private fun LazyListScope.projectGroup(store: MobileStore, id: String, context: String) {
    item("project-$context-$id") { ProjectGroup(store, id) }
}

@Composable
private fun ProjectGroup(store: MobileStore, id: String) {
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val navigation by store.navigation.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == id } ?: return
    val boards = workspace.boards.filter { it.project_id == id }
    val count = boards.size + 1
    val machines =
        project.checkouts
            .map { checkout ->
                session.machines.firstOrNull { it.id == checkout.daemon_id }?.display_name
                    ?: checkout.name
            }
            .distinct()
    val menu = rememberMenuState()
    var editing by remember { mutableStateOf("") }
    Column(Modifier.padding(top = 10.dp)) {
        MenuAnchor(menu) {
            GroupItem(
                Position.of(0, count),
                Modifier.testTag("project-$id"),
                separatorInset = 66.dp,
                onClick = {
                    store.showFrom(MobileRoute.Root(MobileTab.PROJECTS), MobileRoute.Project(id))
                },
                onLongClick = { menu.show(projectMenu(store, id, navigation) { editing = it }) },
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ProjectAvatar(id, project.name, 38.dp)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            project.name,
                            style = type.headline,
                            color = palette.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            if (machines.isEmpty()) "No checkouts"
                            else machines.joinToString(" · "),
                            style = type.subheadline,
                            color = palette.secondaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    MenuButton(
                        projectMenu(store, id, navigation) { editing = it },
                        "Project actions",
                    )
                }
            }
        }
        boards.forEachIndexed { index, board ->
            val cards = workspace.cards.count { it.board_id == board.id }
            val attention = workspace.board_attention[board.id] ?: 0
            ListRow(
                board.name,
                Modifier.testTag("board-row-${board.id}"),
                position = Position.of(index + 1, count),
                glyph = Glyph.BOARD,
                glyphTint = labelColor(com.dbpprt.dieter.core.admin.Labels.stable(board.id)),
                value = "$cards",
                accessory = Accessory.CHEVRON,
                trailing =
                    if (attention > 0) ({ CountBadge(attention, color = palette.warning) })
                    else null,
                onClick = {
                    store.showFrom(
                        MobileRoute.Root(MobileTab.PROJECTS),
                        MobileRoute.Board(board.id),
                    )
                },
            )
        }
    }
    if (editing.isNotEmpty()) ProjectActionSheet(store, id, editing) { editing = "" }
}

internal fun projectMenu(
    store: MobileStore,
    id: String,
    navigation: NavigationSlice,
    open: (String) -> Unit,
): List<MenuSection> {
    val pinned = id in navigation.pinned_projects
    return listOf(
        MenuSection(
            listOf(
                ChromeAction("project-open", "Open project", Glyph.FOLDER_OPEN) {
                    store.showFrom(MobileRoute.Root(MobileTab.PROJECTS), MobileRoute.Project(id))
                },
                ChromeAction("project-pin", if (pinned) "Unpin" else "Pin", Glyph.PIN) {
                    store.command(
                        Command(
                            navigation = NavigationCommand(pin_project = PinProject(id, !pinned))
                        )
                    )
                },
                ChromeAction(
                    "project-folder",
                    "Move to folder",
                    Glyph.FOLDER,
                    menu =
                        listOf(
                            MenuSection(
                                listOf(
                                    ChromeAction("folder-none", "No folder") {
                                        store.command(
                                            Command(
                                                navigation =
                                                    NavigationCommand(
                                                        move_to_folder =
                                                            MoveToFolder(
                                                                FolderScope.FOLDER_SCOPE_PROJECTS,
                                                                id,
                                                                "",
                                                            )
                                                    )
                                            )
                                        )
                                    }
                                ) +
                                    navigation.project_folders.map { folder ->
                                        ChromeAction(
                                            "folder-${folder.id}",
                                            folder.name,
                                            checked = id in folder.item_ids,
                                        ) {
                                            store.command(
                                                Command(
                                                    navigation =
                                                        NavigationCommand(
                                                            move_to_folder =
                                                                MoveToFolder(
                                                                    FolderScope
                                                                        .FOLDER_SCOPE_PROJECTS,
                                                                    id,
                                                                    folder.id,
                                                                )
                                                        )
                                                )
                                            )
                                        }
                                    }
                            )
                        ),
                ),
            )
        ),
        MenuSection(
            listOf(
                ChromeAction("project-edit", "Edit project…", Glyph.EDIT) { open("Edit project") },
                ChromeAction("project-board", "New board…", Glyph.BOARD) { open("New board") },
            )
        ),
        MenuSection(
            listOf(
                ChromeAction(
                    "project-archive",
                    "Archive project…",
                    Glyph.ARCHIVE,
                    destructive = true,
                ) {
                    open("Archive project")
                }
            )
        ),
    )
}

// ---------------------------------------------------------------------------------------------
// Project detail
// ---------------------------------------------------------------------------------------------

@Composable
internal fun ProjectScreen(store: MobileStore, projectId: String) {
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val navigation by store.navigation.collectAsState()
    var editing by remember { mutableStateOf("") }
    val project = workspace.projects.firstOrNull { it.id == projectId }
    if (project == null) {
        Screen(ScreenChrome("Project")) {
            Placeholder(
                if (workspace.loaded) "This project is no longer available." else "Loading…"
            )
        }
        return
    }
    val boards = workspace.boards.filter { it.project_id == projectId }
    val chrome =
        ScreenChrome(
            project.name,
            subtitle = project.summary,
            actions =
                listOf(
                    ChromeAction(
                        "project-menu",
                        "Project actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            projectMenu(store, projectId, navigation) { editing = it }
                                .drop(0)
                                .map { section ->
                                    MenuSection(
                                        section.actions.filter { it.id != "project-open" },
                                        section.title,
                                        section.inline,
                                    )
                                } +
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "project-checkouts",
                                            "Checkouts…",
                                            Glyph.MACHINE,
                                        ) {
                                            editing = "Checkouts"
                                        },
                                        ChromeAction(
                                            "project-workspaces",
                                            "Workspaces…",
                                            Glyph.BRANCH,
                                        ) {
                                            editing = "Workspaces"
                                        },
                                        ChromeAction(
                                            "project-conflicts",
                                            "Setting conflicts…",
                                            Glyph.WARNING,
                                        ) {
                                            editing = "Conflicts"
                                        },
                                    )
                                ),
                    )
                ),
            primary = newTaskAction(store),
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("project-detail"),
            state = listState,
            contentPadding = padding,
        ) {
            item { ConnectionNotice(store) }
            item { SectionHeader("Boards") }
            if (boards.isEmpty())
                item {
                    ListRow(
                        "New board",
                        position = Position.SINGLE,
                        glyph = Glyph.ADD,
                        onClick = { editing = "New board" },
                    )
                }
            itemsIndexed(boards, key = { _, board -> board.id }) { index, board ->
                val cards = workspace.cards.filter { it.board_id == board.id }
                val running = cards.count { it.lane == "running" }
                val attention = workspace.board_attention[board.id] ?: 0
                ListRow(
                    board.name,
                    Modifier.testTag("board-row-${board.id}"),
                    position = Position.of(index, boards.size),
                    subtitle =
                        buildList {
                                add("${cards.size} card${if (cards.size == 1) "" else "s"}")
                                if (running > 0) add("$running running")
                            }
                            .joinToString(" · "),
                    glyph = Glyph.BOARD,
                    tile = labelColor(com.dbpprt.dieter.core.admin.Labels.stable(board.id)),
                    accessory = Accessory.CHEVRON,
                    trailing =
                        if (attention > 0) ({ CountBadge(attention, color = palette.warning) })
                        else null,
                    onClick = {
                        store.showFrom(MobileRoute.Project(projectId), MobileRoute.Board(board.id))
                    },
                )
            }
            item { SectionHeader("Workspace") }
            item {
                Group(listOf(ToolPage.FILES, ToolPage.CHANGES, ToolPage.SCHEDULES)) { page, position
                    ->
                    ListRow(
                        page.title,
                        Modifier.testTag("project-tool-${page.name.lowercase()}"),
                        position = position,
                        glyph = page.glyph,
                        tile = page.color,
                        accessory = Accessory.CHEVRON,
                        onClick = {
                            store.showFrom(
                                MobileRoute.Project(projectId),
                                MobileRoute.Tool(page, projectId),
                            )
                        },
                    )
                }
            }
            item { SectionHeader("Checkouts") }
            if (project.checkouts.isEmpty())
                item {
                    ListRow(
                        "Attach a checkout",
                        position = Position.SINGLE,
                        glyph = Glyph.ADD,
                        onClick = { editing = "Checkouts" },
                    )
                }
            itemsIndexed(project.checkouts, key = { _, checkout -> checkout.id }) { index, checkout
                ->
                val machine = session.machines.firstOrNull { it.id == checkout.daemon_id }
                ListRow(
                    machine?.display_name ?: checkout.name,
                    position = Position.of(index, project.checkouts.size),
                    subtitle = checkout.path,
                    glyph = Glyph.MACHINE,
                    trailing = {
                        Box(
                            Modifier.size(8.dp)
                                .background(
                                    if (machine?.online == true) palette.success
                                    else palette.tertiaryLabel,
                                    CircleShape,
                                )
                        )
                    },
                    subtitleMaxLines = 1,
                )
            }
            if (project.base_branch.isNotEmpty() || project.base_remote.isNotEmpty()) {
                item { SectionHeader("Git") }
                item {
                    Group(
                        listOfNotNull(
                            project.base_remote
                                .takeIf { it.isNotEmpty() }
                                ?.let { "Base remote" to it },
                            project.base_branch
                                .takeIf { it.isNotEmpty() }
                                ?.let { "Base branch" to it },
                        )
                    ) { (title, value), position ->
                        ListRow(title, position = position, value = value)
                    }
                }
            }
        }
    }
    if (editing.isNotEmpty()) ProjectActionSheet(store, projectId, editing) { editing = "" }
}

// ---------------------------------------------------------------------------------------------
// Chats
// ---------------------------------------------------------------------------------------------

@Composable
internal fun ChatsScreen(store: MobileStore) {
    val workspace by store.workspace.collectAsState()
    val view by store.chats.collectAsState()
    val selected by store.selectedCard.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var archived by rememberSaveable { mutableStateOf(false) }
    val now = rememberNow()
    fun setArchived(value: Boolean) {
        archived = value
        store.command(
            Command(
                chats = ChatsCommand(scope = MobileStore.CHATS_SCOPE, show_archived = Toggle(value))
            )
        )
    }
    val chrome =
        ScreenChrome(
            if (archived) "Archived chats" else "Chats",
            large = true,
            actions =
                listOf(
                    ChromeAction(
                        "chats-menu",
                        "Chat options",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "chats-live",
                                            "Current chats",
                                            Glyph.CHATS,
                                            checked = !archived,
                                        ) {
                                            setArchived(false)
                                        },
                                        ChromeAction(
                                            "chats-archived",
                                            "Archived chats",
                                            Glyph.ARCHIVE,
                                            checked = archived,
                                        ) {
                                            setArchived(true)
                                        },
                                    )
                                )
                            ),
                    )
                ),
            primary = newTaskAction(store, chat = true),
        )
    fun cardFor(id: String) =
        (if (archived) view.archived else workspace.cards).firstOrNull { it.id == id }
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("chats-list"),
            state = listState,
            contentPadding = padding,
        ) {
            titleHeader()
            item("notice") { ConnectionNotice(store) }
            item("search") {
                SearchField(
                    query,
                    {
                        query = it
                        store.command(
                            Command(
                                chats =
                                    ChatsCommand(
                                        scope = MobileStore.CHATS_SCOPE,
                                        query = ChatsQuery(it),
                                    )
                            )
                        )
                    },
                    "Search chats",
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                )
            }
            fun section(
                key: String,
                title: String?,
                ids: List<String>,
                header: (@Composable () -> Unit)? = null,
            ) {
                val cards = ids.mapNotNull(::cardFor)
                if (title != null) item("h-$key") { SectionHeader(title, prominent = true) }
                if (header != null) item("hh-$key") { header() }
                itemsIndexed(cards, key = { _, card -> "$key-${card.id}" }) { index, card ->
                    ChatRow(
                        store,
                        card,
                        Position.of(index, cards.size),
                        now,
                        archived,
                        selected == card.id,
                    )
                }
            }
            if (archived) section("archived", null, view.archived.map { it.id })
            else {
                if (view.pinned_ids.isNotEmpty()) section("pinned", "Pinned", view.pinned_ids)
                view.folders.forEach { folder ->
                    item("folder-${folder.folder_id}") {
                        CollapsibleHeader(
                            folder.name,
                            folder.chat_ids.size,
                            folder.expanded,
                            Glyph.FOLDER,
                        ) {
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
                    }
                    if (folder.show_chats)
                        section("folder-${folder.folder_id}", null, folder.chat_ids)
                }
                view.projects.forEach { project ->
                    val name =
                        workspace.projects.firstOrNull { it.id == project.project_id }?.name
                            ?: "Project"
                    item("project-${project.project_id}") {
                        CollapsibleHeader(
                            name,
                            project.total,
                            !project.collapsed,
                            null,
                            project.project_id,
                        ) {
                            store.command(
                                Command(
                                    set_chat_section_collapsed =
                                        SetChatSectionCollapsed(
                                            project_id = project.project_id,
                                            collapsed = !project.collapsed,
                                        )
                                )
                            )
                        }
                    }
                    if (project.show_chats)
                        section("project-${project.project_id}", null, project.chat_ids)
                    if (project.toggle_label.isNotEmpty())
                        item("toggle-${project.project_id}") {
                            DButton(
                                project.toggle_label,
                                {
                                    store.command(
                                        Command(
                                            set_chats_show_all =
                                                SetChatsShowAll(
                                                    project_id = project.project_id,
                                                    show_all = !project.show_all,
                                                )
                                        )
                                    )
                                },
                                Modifier.padding(horizontal = ScreenMargin + 4.dp, vertical = 4.dp),
                                kind = ButtonKind.PLAIN,
                            )
                        }
                }
                if (view.other_ids.isNotEmpty())
                    section(
                        "other",
                        if (view.projects.isNotEmpty() || view.folders.isNotEmpty()) "Other"
                        else null,
                        view.other_ids,
                    )
            }
            if ((archived && view.archived.isEmpty()) || (!archived && view.visible_ids.isEmpty()))
                item("empty") {
                    EmptyState(
                        if (archived) Glyph.ARCHIVE else Glyph.CHATS,
                        if (archived) "No archived chats"
                        else if (query.isNotBlank()) "No results" else "No chats yet",
                        if (archived) "Archived chats appear here."
                        else "Start a conversation about any of your projects.",
                        Modifier.padding(top = 32.dp),
                    ) {
                        if (!archived && query.isBlank())
                            DButton(
                                "New chat",
                                { store.newConversation(chat = true) },
                                glyph = Glyph.COMPOSE,
                            )
                    }
                }
        }
    }
}

@Composable
private fun CollapsibleHeader(
    title: String,
    count: Int,
    expanded: Boolean,
    glyph: Glyph?,
    projectId: String? = null,
    toggle: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .padding(top = 12.dp)
            .pressable(onClick = toggle)
            .padding(
                start = ScreenMargin + 4.dp,
                end = ScreenMargin + 4.dp,
                top = 8.dp,
                bottom = 8.dp,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            projectId != null -> ProjectAvatar(projectId, title, 24.dp)
            glyph != null -> Icon(glyph, null, tint = palette.secondaryLabel, size = 20.dp)
        }
        Spacer(Modifier.width(10.dp))
        Text(
            title,
            Modifier.weight(1f),
            style = type.title3,
            color = palette.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text("$count", style = type.subheadline, color = palette.secondaryLabel)
        Spacer(Modifier.width(8.dp))
        DisclosureChevron(expanded)
    }
}

@Composable
private fun ChatRow(
    store: MobileStore,
    card: Card,
    position: Position,
    now: Instant,
    archived: Boolean,
    selected: Boolean,
) {
    val menu = rememberMenuState()
    val project = store.workspace.value.projects.firstOrNull { it.id == card.project_id }
    val running = card.lane == "running" || card.runtime == "running"
    MenuAnchor(menu) {
        GroupItem(
            position,
            Modifier.testTag("chat-${card.id}"),
            separatorInset = 64.dp,
            onClick = { store.openConversation(card.id) },
            onLongClick = {
                menu.show(
                    if (archived)
                        listOf(
                            MenuSection(
                                listOf(
                                    ChromeAction("restore", "Restore", Glyph.UNARCHIVE) {
                                        store.command(
                                            Command(restore_card = RestoreCard(card_id = card.id))
                                        )
                                    }
                                )
                            )
                        )
                    else cardMenuSections(store, card)
                )
            },
            selected = selected,
        ) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp)) {
                Box {
                    Box(
                        Modifier.size(36.dp)
                            .background(
                                if (apple) palette.fill else colors.secondaryContainer,
                                CircleShape,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Glyph.CHAT,
                            null,
                            tint =
                                if (apple) palette.secondaryLabel else colors.onSecondaryContainer,
                            size = 18.dp,
                        )
                    }
                    if (running)
                        Box(
                            Modifier.align(Alignment.BottomEnd)
                                .offset(3.dp, 3.dp)
                                .size(14.dp)
                                .background(palette.cell, CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            LiveDot(palette.info, size = 9.dp)
                        }
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (card.pinned) {
                            Icon(Glyph.PIN, "Pinned", tint = palette.secondaryLabel, size = 13.dp)
                            Spacer(Modifier.width(4.dp))
                        }
                        Text(
                            Activity.title(card),
                            Modifier.weight(1f),
                            style = type.headline,
                            color = palette.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            CardAges.compact(card, now),
                            Modifier.padding(start = 8.dp),
                            style = type.footnote,
                            color = palette.secondaryLabel,
                        )
                    }
                    Text(
                        card.summary.ifBlank { project?.name.orEmpty() },
                        style = type.subheadline,
                        color = palette.secondaryLabel,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
