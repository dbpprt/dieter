package com.getdieter.mobile.desktop

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.*
import com.getdieter.client.v1.Tone as CoreTone
import com.getdieter.core.activity.Activity
import com.getdieter.mobile.admin.ProjectEditor
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.time.Instant

/**
 * The navigation as a floating card: destinations, projects with their live conversations, then
 * machines and quotas, as the Mac sidebar. [onNavigate] runs after any choice, e.g. to close a
 * floating sidebar.
 */
@Composable
internal fun DesktopSidebar(
    store: MobileStore,
    place: DesktopPlace,
    onPalette: () -> Unit,
    onHide: () -> Unit,
    modifier: Modifier = Modifier,
    onNavigate: () -> Unit = {},
) {
    var addProject by remember { mutableStateOf(false) }
    DesktopPanel(modifier.testTag("desktop-sidebar"), radius = DesktopMetrics.sidebarRadius) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().height(44.dp).padding(start = 14.dp, end = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(20.dp).clip(RoundedCornerShape(6.dp)).background(tokens.text),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Glyph.SPARKLES, null, tint = tokens.panel, size = 12.dp)
                }
                Spacer(Modifier.width(8.dp))
                Text(
                    "Dieter",
                    Modifier.weight(1f),
                    style = type.title2.copy(fontSize = 14.sp),
                    color = tokens.text,
                )
                DesktopIconButton(
                    Glyph.SEARCH,
                    "Search",
                    onPalette,
                    Modifier.testTag("sidebar-search"),
                    tooltip = "Search and commands (Ctrl+K)",
                )
                DesktopIconButton(
                    Glyph.LIST,
                    "Hide sidebar",
                    onHide,
                    Modifier.testTag("sidebar-hide"),
                    tooltip = "Hide sidebar (Ctrl+B)",
                )
            }
            Destinations(store, place) { onNavigate() }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                Projects(store, place, onAdd = { addProject = true }, onNavigate = onNavigate)
                Spacer(Modifier.height(8.dp))
                StatusPanel(store, place, onNavigate)
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Row(
                    Modifier.weight(1f)
                        .height(30.dp)
                        .desktopClickable({ addProject = true })
                        .padding(horizontal = 9.dp)
                        .testTag("sidebar-add-project"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Glyph.ADD,
                        null,
                        tint = tokens.subtle,
                        size = 13.dp,
                        weight = GlyphWeight.SEMIBOLD,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "Add a project",
                        color = tokens.subtle,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
                DesktopIconButton(
                    Glyph.SETTINGS,
                    "Settings",
                    {
                        store.openSection(DesktopSection.SETTINGS)
                        onNavigate()
                    },
                    Modifier.testTag("sidebar-settings"),
                    active = place.section == DesktopSection.SETTINGS,
                    tooltip = "Settings (Ctrl+,)",
                )
            }
        }
    }
    if (addProject) ProjectEditor(store) { addProject = false }
}

/** Inbox, Mail, Channels, Chats and Terminals; each count observes its own source. */
@Composable
private fun Destinations(store: MobileStore, place: DesktopPlace, onNavigate: () -> Unit) {
    val activity by store.workspace.activity.collectAsState()
    val mail by store.mail.slice.collectAsState()
    val channels by store.channels.slice.collectAsState()
    val chats by store.workspace.chats.collectAsState()
    val terminals by store.terminals.overview.collectAsState()
    Column(Modifier.padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        DesktopDestinations.forEachIndexed { index, section ->
            NavRow(
                section.title,
                section.glyph,
                place.section == section,
                Modifier.testTag("sidebar-${section.name.lowercase()}"),
                shortcut = "Ctrl+${index + 1}",
                onClick = {
                    store.openSection(section)
                    onNavigate()
                },
            ) {
                when (section) {
                    DesktopSection.INBOX -> {
                        val attention = activity.summary?.attention ?: 0
                        if (attention > 0) {
                            StatusDot(tokens.attention, size = 6.dp)
                            Spacer(Modifier.width(5.dp))
                            Text(
                                "$attention",
                                color = tokens.tertiary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        } else if ((activity.summary?.running ?: 0) > 0)
                            Text(
                                "${activity.summary?.running}",
                                color = tokens.tertiary,
                                fontSize = 11.sp,
                            )
                    }
                    DesktopSection.MAIL ->
                        DesktopCount(mail.unread, tokens.action, mail.unread_label)
                    DesktopSection.CHANNELS ->
                        DesktopCount(channels.unread, tokens.coral, channels.unread_label)
                    DesktopSection.CHATS ->
                        chats.visible_ids.size
                            .takeIf { it > 0 }
                            ?.let {
                                Text("$it", color = tokens.tertiary, fontSize = 11.sp)
                            }
                    DesktopSection.TERMINALS ->
                        terminals.entries.size
                            .takeIf { it > 0 }
                            ?.let {
                                Text("$it", color = tokens.tertiary, fontSize = 11.sp)
                            }
                    else -> Unit
                }
            }
        }
    }
}

internal val DesktopSection.glyph: Glyph
    get() =
        when (this) {
            DesktopSection.INBOX -> Glyph.INBOX
            DesktopSection.MAIL -> Glyph.MAIL
            DesktopSection.CHANNELS -> Glyph.TAG
            DesktopSection.CHATS -> Glyph.CHATS
            DesktopSection.TERMINALS -> Glyph.TERMINAL
            DesktopSection.FOLDERS -> Glyph.FOLDER
            DesktopSection.PROJECTS,
            DesktopSection.PROJECT -> Glyph.PROJECTS
            DesktopSection.MACHINE -> Glyph.MACHINE
            DesktopSection.USAGE -> Glyph.USAGE
            DesktopSection.DEVICES -> Glyph.DEVICES
            DesktopSection.SETTINGS -> Glyph.SETTINGS
            DesktopSection.PLACES -> Glyph.TOOLS
        }

/** A 29 dp navigation row: glyph, title and a trailing count. */
@Composable
internal fun NavRow(
    title: String,
    glyph: Glyph?,
    selected: Boolean,
    modifier: Modifier = Modifier,
    shortcut: String = "",
    leading: (@Composable () -> Unit)? = null,
    onSecondary: (() -> Unit)? = null,
    onClick: () -> Unit,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    val row: @Composable () -> Unit = {
        Row(
            modifier
                .fillMaxWidth()
                .height(DesktopMetrics.rowHeight)
                .desktopClickable(onClick, selected = selected, onSecondary = onSecondary)
                .padding(horizontal = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            when {
                leading != null -> leading()
                glyph != null ->
                    Icon(
                        glyph,
                        null,
                        tint = if (selected) tokens.text else tokens.subtle,
                        size = 15.dp,
                        weight = GlyphWeight.MEDIUM,
                    )
            }
            Spacer(Modifier.width(9.dp))
            Text(
                title,
                Modifier.weight(1f),
                color = tokens.text.copy(alpha = if (selected) 1f else .88f),
                fontSize = 12.5.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, content = trailing)
        }
    }
    if (shortcut.isEmpty()) row() else DesktopTooltip("$title ($shortcut)", row)
}

/** Live work of one project for its row: running, waiting, failed and review. */
private data class ProjectActivity(val rows: List<ActivityRow>) {
    val strip: List<ActivityRow>
        get() = rows.filter { it.kind != "RECENT" }.take(5)
}

@Composable
private fun Projects(
    store: MobileStore,
    place: DesktopPlace,
    onAdd: () -> Unit,
    onNavigate: () -> Unit,
) {
    val workspace by store.workspace.slice.collectAsState()
    val navigation by store.workspace.navigation.collectAsState()
    val activity by store.workspace.activity.collectAsState()
    val layout = navigation.projects
    val byId = workspace.projects.filter { !it.archived }.associateBy { it.id }
    val order =
        (layout?.order.orEmpty().mapNotNull { byId[it] }).ifEmpty {
            workspace.projects.filter { !it.archived }
        }
    val grouped = activity.rows.groupBy { it.card?.project_id.orEmpty() }
    val expanded = layout?.expanded.orEmpty().toSet()
    val now = rememberNow()
    val selectedProject =
        place.projectId
            .ifEmpty {
                workspace.boards.firstOrNull { it.id == place.boardId }?.project_id.orEmpty()
            }
            .takeIf { place.section == DesktopSection.PROJECT }
    val headerHover = remember { MutableInteractionSource() }
    val hovering by headerHover.collectIsHoveredAsState()
    Column(Modifier.padding(start = 8.dp, end = 8.dp, top = 14.dp)) {
        DesktopSectionHeader("Projects", Modifier.hoverable(headerHover)) {
            if (hovering) DesktopIconButton(Glyph.ADD, "Add a project", onAdd, size = 20.dp)
            else if (activity.rows.any { it.kind == "RUNNING" || it.needs_you }) {
                StatusDot(tokens.running, size = 5.dp)
                Text(" running  ", color = tokens.tertiary, fontSize = 10.5.sp)
                StatusDot(tokens.attention, size = 5.dp)
                Text(" waiting", color = tokens.tertiary, fontSize = 10.5.sp)
            }
        }
        fun row(project: Project): @Composable () -> Unit = {
            ProjectRow(
                store,
                project,
                ProjectActivity(grouped[project.id].orEmpty()),
                expanded = project.id in expanded,
                selected = project.id == selectedProject,
                page = place.page.takeIf { project.id == selectedProject },
                boardId = place.boardId,
                now = now,
                onNavigate = onNavigate,
            )
        }
        val folders = layout?.folders.orEmpty()
        if (folders.isEmpty()) order.forEach { row(it)() }
        else {
            folders.forEach { folder ->
                val projects = folder.item_ids.mapNotNull { byId[it] }
                NavRow(
                    folder.name,
                    null,
                    selected = false,
                    modifier = Modifier.testTag("sidebar-folder-${folder.id}"),
                    leading = {
                        Chevron(folder.expanded)
                        Spacer(Modifier.width(4.dp))
                        Icon(Glyph.FOLDER, null, tint = tokens.subtle, size = 14.dp)
                    },
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
                ) {
                    Text("${projects.size}", color = tokens.tertiary, fontSize = 11.sp)
                }
                if (folder.expanded)
                    Column(Modifier.padding(start = 10.dp)) { projects.forEach { row(it)() } }
            }
            layout?.unfiled.orEmpty().mapNotNull { byId[it] }.forEach { row(it)() }
        }
        if (order.isEmpty() && workspace.loaded)
            Text(
                "No projects yet",
                Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                color = tokens.tertiary,
                fontSize = 11.5.sp,
            )
    }
}

@Composable
private fun Chevron(expanded: Boolean) {
    val angle by animateFloatAsState(if (expanded) 90f else 0f, label = "chevron")
    Icon(
        Glyph.CHEVRON_RIGHT,
        null,
        Modifier.rotate(angle),
        tint = tokens.tertiary,
        size = 11.dp,
        weight = GlyphWeight.BOLD,
    )
}

@Composable
private fun ProjectRow(
    store: MobileStore,
    project: Project,
    activity: ProjectActivity,
    expanded: Boolean,
    selected: Boolean,
    page: ProjectPage?,
    boardId: String,
    now: Instant,
    onNavigate: () -> Unit,
) {
    val workspace by store.workspace.slice.collectAsState()
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    fun toggle() =
        store.command(Command(set_project_expanded = SetProjectExpanded(project.id, !expanded)))
    Row(
        Modifier.fillMaxWidth()
            .height(31.dp)
            .hoverable(interaction)
            .desktopClickable(
                {
                    store.openProject(project.id)
                    if (!expanded) toggle()
                    onNavigate()
                },
                RoundedCornerShape(9.dp),
                selected = selected && page == ProjectPage.BOARD && !expanded,
            )
            .padding(start = 6.dp, end = 6.dp)
            .testTag("sidebar-project-${project.id}")
            .semantics { contentDescription = "Project ${project.name}" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(18.dp)
                .clip(RoundedCornerShape(5.dp))
                .desktopClickable(::toggle, RoundedCornerShape(5.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Chevron(expanded)
        }
        Spacer(Modifier.width(4.dp))
        ProjectMark(project.id, project.name)
        Spacer(Modifier.width(8.dp))
        Text(
            project.name,
            Modifier.weight(1f),
            color = tokens.text.copy(alpha = if (selected) 1f else .88f),
            fontSize = 12.5.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (hovered)
            DesktopIconButton(
                Glyph.ADD,
                "New task in ${project.name}",
                {
                    store.openProject(project.id)
                    store.newConversation(chat = false)
                },
                size = 20.dp,
            )
        else if (activity.strip.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                activity.strip.forEach { row ->
                    Box(
                        Modifier.size(width = 7.dp, height = 2.5.dp)
                            .background(row.tint(), RoundedCornerShape(50))
                    )
                }
            }
            Spacer(Modifier.width(5.dp))
            Text("${activity.strip.size}", color = tokens.tertiary, fontSize = 10.5.sp)
        }
    }
    if (!expanded) return
    Column(Modifier.padding(start = 8.dp, top = 2.dp, bottom = 6.dp)) {
        PageTrack(project.id, page.takeIf { selected }) { chosen ->
            store.openProject(project.id, chosen)
            onNavigate()
        }
        val boards = workspace.boards.filter { it.project_id == project.id }
        if (boards.size > 1)
            boards.forEach { board ->
                NavRow(
                    board.name,
                    Glyph.BOARD,
                    selected = selected && page == ProjectPage.BOARD && board.id == boardId,
                    Modifier.testTag("sidebar-board-${board.id}"),
                    onClick = {
                        store.openProject(project.id, ProjectPage.BOARD, board.id)
                        onNavigate()
                    },
                ) {
                    workspace.board_attention[board.id]?.let { DesktopCount(it, tokens.attention) }
                }
            }
        activity.rows
            .filter { it.kind != "RECENT" || it.pinned }
            .take(8)
            .forEach { row ->
                val card = row.card ?: return@forEach
                NavRow(
                    row.title,
                    null,
                    selected = false,
                    Modifier.testTag("sidebar-card-${card.id}"),
                    leading = {
                        Box(Modifier.width(15.dp), contentAlignment = Alignment.Center) {
                            if (row.kind == "RUNNING") LiveDot(row.tint(), size = 6.dp)
                            else StatusDot(row.tint(), size = 6.dp)
                        }
                    },
                    onClick = {
                        store.openCard(card.id)
                        onNavigate()
                    },
                ) {
                    Text(
                        Activity.age(
                            row.shown_at_millis
                                .takeIf { it > 0 }
                                ?.let(Instant::fromEpochMilliseconds),
                            now,
                            suffix = false,
                        ),
                        style = MonoSmall,
                        color = tokens.tertiary,
                    )
                }
            }
    }
}

/** Board, Files, Changes and Schedules as four vertical segments. */
@Composable
private fun PageTrack(projectId: String, selected: ProjectPage?, onSelect: (ProjectPage) -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .padding(end = 2.dp, bottom = 4.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(tokens.inset)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        ProjectPage.entries.forEach { page ->
            val on = page == selected
            Column(
                Modifier.weight(1f)
                    .heightIn(min = 38.dp)
                    .desktopClickable(
                        { onSelect(page) },
                        RoundedCornerShape(8.dp),
                        selected = on,
                        selectedFill = tokens.segmentThumb,
                    )
                    .padding(vertical = 4.dp)
                    .testTag("project-page-${page.name.lowercase()}-$projectId"),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(
                    when (page) {
                        ProjectPage.BOARD -> Glyph.BOARD
                        ProjectPage.FILES -> Glyph.FOLDER
                        ProjectPage.CHANGES -> Glyph.CHANGES
                        ProjectPage.SCHEDULES -> Glyph.SCHEDULES
                    },
                    page.title,
                    tint = if (on) tokens.text else tokens.subtle,
                    size = 13.dp,
                )
                Text(
                    page.title,
                    color = if (on) tokens.text else tokens.subtle,
                    fontSize = 9.5.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                )
            }
        }
    }
}

/** An activity row's status color: amber waits, green runs, coral failed, blue review. */
@Composable
internal fun ActivityRow.tint(): Color =
    when {
        kind == "FAILED" -> tokens.coral
        needs_you -> tokens.attention
        kind == "RUNNING" -> tokens.running
        kind == "REVIEW" -> tokens.action
        else -> tokens.tertiary
    }

/** Machines with their connection, then provider quotas, in a recessed well. */
@Composable
private fun StatusPanel(store: MobileStore, place: DesktopPlace, onNavigate: () -> Unit) {
    val session by store.session.slice.collectAsState()
    val quotas by store.machines.quotas.collectAsState()
    LaunchedEffect(Unit) { store.machines.loadQuotas() }
    Column(
        Modifier.fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(tokens.inset)
            .padding(vertical = 4.dp)
            .testTag("sidebar-status")
    ) {
        DesktopSectionHeader("Machines") {
            StatusDot(session.tone.color(), size = 6.dp)
            Spacer(Modifier.width(5.dp))
            Text(session.phase_label, color = tokens.tertiary, fontSize = 10.5.sp, maxLines = 1)
        }
        session.machines.forEach { machine ->
            Row(
                Modifier.fillMaxWidth()
                    .padding(horizontal = 4.dp)
                    .heightIn(min = 26.dp)
                    .desktopClickable(
                        {
                            store.openMachine(machine.id)
                            onNavigate()
                        },
                        RoundedCornerShape(7.dp),
                        selected =
                            place.section == DesktopSection.MACHINE &&
                                place.machineId == machine.id,
                    )
                    .padding(horizontal = 8.dp)
                    .testTag("sidebar-machine-${machine.id}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                StatusDot(
                    if (machine.available) tokens.running
                    else if (machine.online) tokens.attention else tokens.tertiary.copy(.6f),
                    size = 6.dp,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    machine.display_name,
                    Modifier.weight(1f),
                    color = tokens.text,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    machine.sync_label.ifEmpty { machine.presence },
                    style = MonoSmall,
                    color = tokens.tertiary,
                    maxLines = 1,
                )
            }
        }
        val rows = quotas.group_rows.filter { it.lowest_remaining >= 0 }
        if (rows.isNotEmpty()) {
            Box(
                Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(tokens.hairline)
            )
            DesktopSectionHeader("Quotas")
            rows.forEach { group ->
                Row(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = 4.dp)
                        .height(24.dp)
                        .desktopClickable(
                            {
                                store.openSection(DesktopSection.USAGE)
                                onNavigate()
                            },
                            RoundedCornerShape(7.dp),
                        )
                        .padding(horizontal = 8.dp)
                        .testTag("sidebar-quota-${group.provider_name.lowercase()}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        group.provider_name,
                        Modifier.weight(1f),
                        color = tokens.subtle,
                        fontSize = 11.5.sp,
                        maxLines = 1,
                    )
                    val fraction = group.lowest_remaining / 100f
                    Box(
                        Modifier.size(width = 44.dp, height = 4.dp)
                            .clip(RoundedCornerShape(50))
                            .background(tokens.hairline)
                    ) {
                        Box(
                            Modifier.fillMaxHeight()
                                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                                .background(
                                    when {
                                        group.lowest_remaining < 15 -> tokens.coral
                                        group.lowest_remaining < 35 -> tokens.attention
                                        else -> tokens.running
                                    }
                                )
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                    Text("${group.lowest_remaining}%", style = MonoSmall, color = tokens.tertiary)
                }
            }
        }
    }
}

@Composable
internal fun CoreTone.color(): Color =
    when (this) {
        CoreTone.TONE_SUCCESS -> tokens.running
        CoreTone.TONE_ACTIVE -> tokens.action
        CoreTone.TONE_WARNING -> tokens.attention
        CoreTone.TONE_DANGER -> tokens.coral
        else -> tokens.tertiary
    }

/** A project's initial on its stable label color, small enough for a sidebar row. */
@Composable
internal fun ProjectMark(id: String, name: String, size: androidx.compose.ui.unit.Dp = 16.dp) {
    Box(
        Modifier.size(size)
            .clip(RoundedCornerShape(size * .3f))
            .background(labelColor(com.getdieter.core.admin.Labels.stable(id))),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            name.trim().take(1).uppercase(),
            color = Color.White,
            fontSize = (size.value * .58f).sp,
            fontWeight = FontWeight.Bold,
        )
    }
}
