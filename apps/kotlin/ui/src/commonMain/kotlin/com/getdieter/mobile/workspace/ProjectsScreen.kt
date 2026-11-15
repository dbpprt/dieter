@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Board
import com.getdieter.client.v1.*
import com.getdieter.mobile.admin.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

/**
 * Projects in the user's layout: pinned ones, folders, then the rest. Each project is a row with
 * its machines, followed by a row per board.
 */
@Composable
internal fun ProjectsScreen(store: MobileStore) {
    val workspace by store.workspace.slice.collectAsState()
    val navigation by store.workspace.navigation.collectAsState()
    val session by store.session.slice.collectAsState()
    val search = rememberListSearch("projects", "Search projects and boards")
    val query = search.query
    var create by remember { mutableStateOf(false) }
    var editFolder by remember { mutableStateOf<NavigationFolder?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    val layout = navigation.projects
    val order = layout?.order.orEmpty().ifEmpty { workspace.projects.map { it.id } }
    fun matches(id: String) =
        query.isBlank() ||
            workspace.projects.firstOrNull { it.id == id }?.name?.contains(query, true) == true ||
            workspace.boards.any { it.project_id == id && it.name.contains(query, true) }
    val chrome =
        ScreenChrome(
            "Projects",
            subtitle =
                if (workspace.projects.isEmpty()) ""
                else
                    "${workspace.projects.size} project${if (workspace.projects.size == 1) "" else "s"}" +
                        if (!navigation.caught_up) " · Syncing…" else "",
            large = false,
            actions =
                listOf(
                    search.action(),
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
                    ),
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
            if (search.shown) item("search") { search.Field() }
            val pinned = layout?.pinned.orEmpty().filter(::matches)
            if (pinned.isNotEmpty()) {
                item("pinned-header") { ListSectionHeader("Pinned", count = pinned.size) }
                projectGroups(store, pinned, "pinned")
            }
            layout?.folders.orEmpty().forEach { folder ->
                val ids = folder.item_ids.filter(::matches)
                if (query.isNotBlank() && ids.isEmpty()) return@forEach
                item("folder-${folder.id}") {
                    FolderHeader(store, folder, onEdit = { editFolder = folder })
                }
                if (folder.expanded || query.isNotBlank())
                    projectGroups(store, ids, "folder-${folder.id}")
            }
            val unfiled = (layout?.unfiled ?: order).filter(::matches)
            if (unfiled.isNotEmpty()) {
                if (pinned.isNotEmpty() || layout?.folders.orEmpty().isNotEmpty())
                    item("all-header") { ListSectionHeader("All projects", count = unfiled.size) }
                projectGroups(store, unfiled, "unfiled")
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
            if (query.isNotBlank() && order.none(::matches))
                item("no-results") {
                    EmptyState(
                        Glyph.SEARCH,
                        "No results",
                        "No projects or boards match “$query”.",
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

/** A folder's section header: tapping collapses or expands it, a long press renames it. */
@Composable
private fun FolderHeader(store: MobileStore, folder: NavigationFolder, onEdit: () -> Unit) {
    val menu = rememberMenuState()
    MenuAnchor(menu) {
        ListSectionHeader(
            folder.name,
            Modifier.pressable(
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
                .testTag("folder-${folder.id}"),
            count = folder.item_ids.size,
            trailing = {
                Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                    DisclosureChevron(folder.expanded)
                }
            },
        )
    }
}

/** Each project of a section: its row, then its boards. */
private fun LazyListScope.projectGroups(store: MobileStore, ids: List<String>, context: String) {
    ids.forEachIndexed { index, id ->
        item("project-$context-$id") { ProjectGroup(store, id, first = index == 0) }
    }
}

@Composable
private fun ProjectGroup(store: MobileStore, id: String, first: Boolean) {
    val workspace by store.workspace.slice.collectAsState()
    val session by store.session.slice.collectAsState()
    val navigation by store.workspace.navigation.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == id } ?: return
    val boards = workspace.boards.filter { it.project_id == id }
    val machines =
        project.checkouts
            .map { checkout ->
                session.machines.firstOrNull { it.id == checkout.daemon_id }?.display_name
                    ?: checkout.name
            }
            .distinct()
    val menu = rememberMenuState()
    var editing by remember { mutableStateOf("") }
    Column {
        MenuAnchor(menu) {
            ListRow(
                onClick = {
                    store.showFrom(MobileRoute.Root(MobileTab.PROJECTS), MobileRoute.Project(id))
                },
                modifier = Modifier.testTag("project-$id"),
                onLongClick = { menu.show(projectMenu(store, id, navigation) { editing = it }) },
                first = first,
                leading = { ProjectAvatar(id, project.name, ListTile) },
                subtitle = {
                    ListSubtitle(
                        if (machines.isEmpty()) "No checkouts" else machines.joinToString(" · ")
                    )
                },
            ) {
                ListTitle(project.name)
            }
        }
        boards.forEach { board ->
            val cards = workspace.cards.count { it.board_id == board.id }
            val attention = workspace.board_attention[board.id] ?: 0
            ListRow(
                onClick = {
                    store.showFrom(
                        MobileRoute.Root(MobileTab.PROJECTS),
                        MobileRoute.Board(board.id),
                    )
                },
                modifier = Modifier.testTag("board-row-${board.id}"),
                // A board's smaller tile sets it under its project.
                leading = { ListIconTile(Glyph.BOARD, board.tint, size = BoardTile) },
                meta = { ListMeta("$cards") },
                // Without a second line the badge follows the meta at the row's own spacing.
                badge = { CountBadge(attention, color = palette.warning) },
            ) {
                ListTitle(board.name)
            }
        }
    }
    if (editing.isNotEmpty()) ProjectActionSheet(store, id, editing) { editing = "" }
}

/** A board row's tile in the projects list, smaller than its project's avatar. */
private val BoardTile = 32.dp

/** A row that adds the section's first item, e.g. a board or a checkout. */
@Composable
private fun AddRow(title: String, first: Boolean, onClick: () -> Unit) {
    ListRow(onClick, first = first, leading = { ListIconTile(Glyph.ADD, palette.accent) }) {
        ListTitle(title, color = palette.accent)
    }
}

/** A board's stable label colour. */
private val Board.tint: Color
    @Composable get() = labelColor(com.getdieter.core.admin.Labels.stable(id))

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

@Composable
internal fun ProjectScreen(store: MobileStore, projectId: String) {
    val workspace by store.workspace.slice.collectAsState()
    val session by store.session.slice.collectAsState()
    val navigation by store.workspace.navigation.collectAsState()
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
            item { ListSectionHeader("Boards", count = boards.size.takeIf { it > 0 }) }
            if (boards.isEmpty())
                item { AddRow("New board", first = true) { editing = "New board" } }
            itemsIndexed(boards, key = { _, board -> board.id }) { index, board ->
                val cards = workspace.cards.filter { it.board_id == board.id }
                val running = cards.count { it.lane == "running" }
                val attention = workspace.board_attention[board.id] ?: 0
                ListRow(
                    onClick = {
                        store.showFrom(MobileRoute.Project(projectId), MobileRoute.Board(board.id))
                    },
                    modifier = Modifier.testTag("board-row-${board.id}"),
                    first = index == 0,
                    leading = { ListIconTile(Glyph.BOARD, board.tint) },
                    subtitle = {
                        ListSubtitle(
                            buildList {
                                    add("${cards.size} card${if (cards.size == 1) "" else "s"}")
                                    if (running > 0) add("$running running")
                                }
                                .joinToString(" · ")
                        )
                    },
                    badge = { CountBadge(attention, ListBadgeGap, color = palette.warning) },
                ) {
                    ListTitle(board.name)
                }
            }
            item { ListSectionHeader("Workspace") }
            itemsIndexed(listOf(ToolPage.FILES, ToolPage.CHANGES, ToolPage.SCHEDULES)) { index, page
                ->
                ListRow(
                    onClick = {
                        store.showFrom(
                            MobileRoute.Project(projectId),
                            MobileRoute.Tool(page, projectId),
                        )
                    },
                    modifier = Modifier.testTag("project-tool-${page.name.lowercase()}"),
                    first = index == 0,
                    leading = { ListIconTile(page.glyph, page.color) },
                ) {
                    ListTitle(page.title)
                }
            }
            item {
                ListSectionHeader(
                    "Checkouts",
                    count = project.checkouts.size.takeIf { it > 0 },
                )
            }
            if (project.checkouts.isEmpty())
                item { AddRow("Attach a checkout", first = true) { editing = "Checkouts" } }
            itemsIndexed(project.checkouts, key = { _, checkout -> checkout.id }) { index, checkout
                ->
                val machine = session.machines.firstOrNull { it.id == checkout.daemon_id }
                // A checkout opens its own Files, so the machine is never a guess.
                ListRow(
                    onClick = {
                        if (!checkout.detached)
                            store.showFrom(
                                MobileRoute.Project(projectId),
                                MobileRoute.Tool(ToolPage.FILES, projectId, checkout.id),
                            )
                    },
                    modifier = Modifier.testTag("project-checkout-${checkout.id}"),
                    first = index == 0,
                    leading = { ListIconTile(Glyph.MACHINE) },
                    subtitle = { ListSubtitle(checkout.path) },
                    badge = {
                        Box(
                            ListBadgeGap.size(8.dp)
                                .background(
                                    if (machine?.online == true) palette.success
                                    else palette.tertiaryLabel,
                                    CircleShape,
                                )
                        )
                    },
                ) {
                    ListTitle(
                        machine?.display_name ?: checkout.name,
                        color = if (checkout.detached) palette.tertiaryLabel else palette.label,
                    )
                }
            }
            val git =
                listOfNotNull(
                    project.base_remote
                        .takeIf { it.isNotEmpty() }
                        ?.let { Triple("Base remote", it, Glyph.GLOBE) },
                    project.base_branch
                        .takeIf { it.isNotEmpty() }
                        ?.let { Triple("Base branch", it, Glyph.BRANCH) },
                )
            if (git.isNotEmpty()) {
                item { ListSectionHeader("Git") }
                itemsIndexed(git) { index, (title, value, glyph) ->
                    ListRow(
                        onClick = null,
                        first = index == 0,
                        leading = { ListIconTile(glyph) },
                        subtitle = { ListSubtitle(value) },
                    ) {
                        ListTitle(title)
                    }
                }
            }
        }
    }
    if (editing.isNotEmpty()) ProjectActionSheet(store, projectId, editing) { editing = "" }
}
