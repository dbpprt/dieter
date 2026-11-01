package com.getdieter.mobile.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.SearchCommand
import com.getdieter.client.v1.SearchHit
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.delay

/** One palette row: a command, a place or a conversation. */
@Immutable
internal class PaletteEntry(
    val id: String,
    val title: String,
    val subtitle: String,
    val glyph: Glyph,
    val shortcut: String = "",
    val run: () -> Unit,
)

/** The palette's commands, in the order an empty query lists them. */
internal fun paletteCommands(store: MobileStore): List<PaletteEntry> =
    listOf(
        PaletteEntry(
            "new-task",
            "New task",
            "Start an agent on the current board",
            Glyph.COMPOSE,
            DesktopShortcut.NEW_TASK.keys,
        ) {
            store.newConversation(chat = false)
        },
        PaletteEntry(
            "new-chat",
            "New chat",
            "A conversation outside any board",
            Glyph.CHAT,
            DesktopShortcut.NEW_CHAT.keys,
        ) {
            store.newConversation(chat = true)
        },
        PaletteEntry("open-inbox", "Open Inbox", "", Glyph.INBOX, DesktopShortcut.INBOX.keys) {
            store.openSection(DesktopSection.INBOX)
        },
        PaletteEntry("open-mail", "Open Mail", "", Glyph.MAIL, DesktopShortcut.MAIL.keys) {
            store.openSection(DesktopSection.MAIL)
        },
        PaletteEntry(
            "open-channels",
            "Open Channels",
            "",
            Glyph.TAG,
            DesktopShortcut.CHANNELS.keys,
        ) {
            store.openSection(DesktopSection.CHANNELS)
        },
        PaletteEntry("open-chats", "Open all chats", "", Glyph.CHATS, DesktopShortcut.CHATS.keys) {
            store.openSection(DesktopSection.CHATS)
        },
        PaletteEntry(
            "open-terminals",
            "Open terminals",
            "",
            Glyph.TERMINAL,
            DesktopShortcut.TERMINALS.keys,
        ) {
            store.openSection(DesktopSection.TERMINALS)
        },
        PaletteEntry("open-projects", "Browse projects", "", Glyph.PROJECTS) {
            store.openSection(DesktopSection.PROJECTS)
        },
        PaletteEntry("open-usage", "Provider usage", "", Glyph.USAGE) {
            store.openSection(DesktopSection.USAGE)
        },
        PaletteEntry("open-devices", "Devices", "", Glyph.DEVICES) {
            store.openSection(DesktopSection.DEVICES)
        },
        PaletteEntry(
            "open-settings",
            "Settings",
            "",
            Glyph.SETTINGS,
            DesktopShortcut.SETTINGS.keys,
        ) {
            store.openSection(DesktopSection.SETTINGS)
        },
        PaletteEntry("mark-mail-read", "Mark all mail read", "", Glyph.MAIL_OPEN) {
            store.mail.markAllRead()
        },
        PaletteEntry("refresh", "Refresh", "", Glyph.REFRESH, DesktopShortcut.REFRESH.keys) {
            store.session.refresh()
        },
        PaletteEntry(
            "sidebar",
            "Show or hide the sidebar",
            "",
            Glyph.LIST,
            DesktopShortcut.SIDEBAR.keys,
        ) {
            store.layout.setSidebarHidden(!store.layout.sidebarHidden.value)
        },
        PaletteEntry(
            "touch",
            "Use the touch interface",
            "Leave the desktop layout for this device",
            Glyph.PHONE,
        ) {
            store.layout.setInterfaceMode(InterfaceMode.TOUCH)
        },
    )

/**
 * What [query] finds, best first: conversations from the core's search, then projects, boards and
 * machines named like it, then matching commands. An empty query lists the commands and the Inbox's
 * latest work.
 */
internal fun paletteEntries(
    store: MobileStore,
    query: String,
    hits: List<SearchHit>,
): List<PaletteEntry> {
    val commands = paletteCommands(store)
    val text = query.trim()
    val workspace = store.workspace.slice.value
    if (text.isEmpty()) {
        val recent =
            store.workspace.activity.value.rows
                .filter { it.card != null }
                .take(6)
                .map { row ->
                    PaletteEntry(
                        "card-${row.card!!.id}",
                        row.title,
                        listOf(row.project_name, row.board_name)
                            .filter { it.isNotEmpty() }
                            .joinToString(" · ")
                            .ifEmpty { row.kind_label },
                        if (row.chat) Glyph.CHAT else Glyph.BOARD,
                    ) {
                        store.openCard(row.card!!.id)
                    }
                }
        return commands.take(7) + recent + commands.drop(7)
    }
    fun named(value: String) = value.contains(text, ignoreCase = true)
    val conversations = hits.map { hit ->
        PaletteEntry(
            "card-${hit.card_id}",
            hit.title,
            hit.location.ifEmpty { "Chat" },
            if (hit.chat) Glyph.CHAT else Glyph.BOARD,
        ) {
            store.openCard(hit.card_id)
        }
    }
    val projects =
        workspace.projects
            .filter { !it.archived && named(it.name) }
            .map { project ->
                PaletteEntry("project-${project.id}", project.name, "Project", Glyph.PROJECTS) {
                    store.openProject(project.id)
                }
            }
    val boards =
        workspace.boards
            .filter { named(it.name) }
            .map { board ->
                val project = workspace.projects.firstOrNull { it.id == board.project_id }
                PaletteEntry(
                    "board-${board.id}",
                    board.name,
                    listOfNotNull(project?.name, "Board").joinToString(" · "),
                    Glyph.BOARD,
                ) {
                    store.openProject(board.project_id, ProjectPage.BOARD, board.id)
                }
            }
    val machines =
        store.session.slice.value.machines
            .filter { named(it.display_name) }
            .map { machine ->
                PaletteEntry(
                    "machine-${machine.id}",
                    machine.display_name,
                    "Machine · ${machine.presence}",
                    Glyph.MACHINE,
                ) {
                    store.openMachine(machine.id)
                }
            }
    return conversations +
        projects +
        boards +
        machines +
        commands.filter { named(it.title) || named(it.subtitle) }
}

/** The command palette over the workspace: type, move with ↑↓, open with ↵, close with esc. */
@Composable
internal fun DesktopCommandPalette(store: MobileStore, onClose: () -> Unit) {
    var query by remember { mutableStateOf("") }
    var hits by remember { mutableStateOf<List<SearchHit>>(emptyList()) }
    var index by remember { mutableStateOf(0) }
    val focus = remember { FocusRequester() }
    val list = rememberLazyListState()
    LaunchedEffect(query) {
        index = 0
        if (query.isBlank()) {
            hits = emptyList()
            return@LaunchedEffect
        }
        delay(120)
        hits =
            runCatching {
                    store.core
                        .dispatch(Command(search = SearchCommand(query)))
                        .search_results
                        ?.hits
                        .orEmpty()
                }
                .getOrDefault(emptyList())
    }
    val entries = paletteEntries(store, query, hits)
    LaunchedEffect(index) {
        if (entries.isNotEmpty()) list.animateScrollToItem(index.coerceIn(0, entries.lastIndex))
    }
    fun open(entry: PaletteEntry) {
        onClose()
        entry.run()
    }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Box(
        Modifier.fillMaxSize()
            .background(Color.Black.copy(alpha = if (tokens.dark) .35f else .16f))
            .clickable(remember { MutableInteractionSource() }, null, onClick = onClose),
        contentAlignment = Alignment.TopCenter,
    ) {
        DesktopPanel(
            Modifier.padding(top = 72.dp)
                .widthIn(max = 600.dp)
                .fillMaxWidth(.9f)
                .heightIn(max = 430.dp)
                .clickable(remember { MutableInteractionSource() }, null) {}
                .onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    when (event.key) {
                        Key.DirectionDown ->
                            index = (index + 1).coerceAtMost((entries.size - 1).coerceAtLeast(0))
                        Key.DirectionUp -> index = (index - 1).coerceAtLeast(0)
                        Key.Enter,
                        Key.NumPadEnter -> entries.getOrNull(index)?.let(::open)
                        Key.Escape -> onClose()
                        else -> return@onPreviewKeyEvent false
                    }
                    true
                }
                .testTag("command-palette"),
            radius = 18.dp,
        ) {
            Column {
                Row(
                    Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    DesktopSearchField(
                        query,
                        { query = it },
                        "Search tasks, chats, projects and commands",
                        Modifier.weight(1f),
                        testTag = "palette-search",
                        focusRequester = focus,
                        height = 34.dp,
                        onSubmit = { entries.getOrNull(index)?.let(::open) },
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "esc",
                        Modifier.background(tokens.inset, RoundedCornerShape(5.dp))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                        color = tokens.tertiary,
                        fontSize = 10.sp,
                    )
                }
                BandRule()
                LazyColumn(
                    Modifier.weight(1f, fill = false),
                    state = list,
                    contentPadding = PaddingValues(6.dp),
                ) {
                    if (entries.isEmpty())
                        item("none") {
                            Text(
                                "Nothing matches “$query”.",
                                Modifier.padding(16.dp),
                                color = tokens.tertiary,
                                fontSize = 12.5.sp,
                            )
                        }
                    itemsIndexed(entries, key = { _, entry -> entry.id }) { position, entry ->
                        val on = position == index
                        Row(
                            Modifier.fillMaxWidth()
                                .height(40.dp)
                                .desktopClickable(
                                    { open(entry) },
                                    RoundedCornerShape(10.dp),
                                    selected = on,
                                    selectedFill = tokens.selection,
                                )
                                .padding(horizontal = 10.dp)
                                .testTag("palette-${entry.id}"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(
                                Modifier.size(24.dp)
                                    .background(tokens.inset, RoundedCornerShape(6.dp)),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(entry.glyph, null, tint = tokens.subtle, size = 14.dp)
                            }
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    entry.title,
                                    color = tokens.text,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (entry.subtitle.isNotEmpty())
                                    Text(
                                        entry.subtitle,
                                        color = tokens.tertiary,
                                        fontSize = 11.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                            }
                            if (entry.shortcut.isNotEmpty())
                                Text(entry.shortcut, style = MonoSmall, color = tokens.tertiary)
                            if (on)
                                Icon(
                                    Glyph.RETURN,
                                    null,
                                    Modifier.padding(start = 8.dp),
                                    tint = tokens.tertiary,
                                    size = 13.dp,
                                )
                        }
                    }
                }
                BandRule()
                Row(
                    Modifier.padding(horizontal = 16.dp, vertical = 7.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Glyph.ARROW_UP, null, tint = tokens.tertiary, size = 10.dp)
                    Icon(Glyph.ARROW_DOWN, null, tint = tokens.tertiary, size = 10.dp)
                    Text("Navigate", color = tokens.tertiary, fontSize = 10.sp)
                    Spacer(Modifier.width(10.dp))
                    Icon(Glyph.RETURN, null, tint = tokens.tertiary, size = 10.dp)
                    Text("Open", color = tokens.tertiary, fontSize = 10.sp)
                    Spacer(Modifier.width(10.dp))
                    Text("esc  Close", color = tokens.tertiary, fontSize = 10.sp)
                }
            }
        }
    }
}
