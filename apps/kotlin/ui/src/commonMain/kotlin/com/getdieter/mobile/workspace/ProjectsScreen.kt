@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.admin.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

@Composable
internal fun ProjectsScreen(store: MobileStore) {
    val workspace by store.workspace.slice.collectAsState()
    val navigation by store.workspace.navigation.collectAsState()
    val session by store.session.slice.collectAsState()
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
    val workspace by store.workspace.slice.collectAsState()
    val session by store.session.slice.collectAsState()
    val navigation by store.workspace.navigation.collectAsState()
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
                glyphTint = labelColor(com.getdieter.core.admin.Labels.stable(board.id)),
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
                    tile = labelColor(com.getdieter.core.admin.Labels.stable(board.id)),
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
                // A checkout opens its own Files, so the machine is never a guess.
                ListRow(
                    machine?.display_name ?: checkout.name,
                    Modifier.testTag("project-checkout-${checkout.id}"),
                    position = Position.of(index, project.checkouts.size),
                    subtitle = checkout.path,
                    glyph = Glyph.MACHINE,
                    accessory = if (checkout.detached) Accessory.NONE else Accessory.CHEVRON,
                    enabled = !checkout.detached,
                    onClick = {
                        store.showFrom(
                            MobileRoute.Project(projectId),
                            MobileRoute.Tool(ToolPage.FILES, projectId, checkout.id),
                        )
                    },
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
