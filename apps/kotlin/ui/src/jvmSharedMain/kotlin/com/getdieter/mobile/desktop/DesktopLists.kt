package com.getdieter.mobile.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.activity.Activity
import com.getdieter.core.board.CardAges
import com.getdieter.mobile.app.ChromeAction
import com.getdieter.mobile.app.MenuSection
import com.getdieter.mobile.board.cardMenuSections
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import com.getdieter.mobile.workspace.InboxRulesSheet
import com.getdieter.mobile.workspace.InboxSection
import com.getdieter.mobile.workspace.inboxSections
import kotlin.time.Instant

/** A list column's band: sidebar toggle, title and count, then its actions. */
@Composable
internal fun ListBand(
    title: String,
    count: String = "",
    actions: @Composable RowScope.() -> Unit = {},
) {
    val toggle = LocalSidebarToggle.current
    Row(
        Modifier.fillMaxWidth().height(DesktopMetrics.titleBand).padding(start = 4.dp, end = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (toggle != null)
            DesktopIconButton(
                Glyph.LIST,
                "Show sidebar",
                toggle,
                Modifier.testTag("sidebar-show"),
                tooltip = "Show sidebar (Ctrl+B)",
            )
        Text(
            title,
            color = tokens.text,
            style = type.title2,
            maxLines = 1,
            modifier = Modifier.testTag("desktop-title"),
        )
        if (count.isNotEmpty())
            Text(count, color = tokens.tertiary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.weight(1f))
        actions()
    }
}

private enum class InboxFilter(val title: String) {
    ALL("All"),
    NEEDS_YOU("Needs you"),
    RUNNING("Running"),
    REVIEW("Review"),
}

private fun ActivityRow.matches(filter: InboxFilter) =
    when (filter) {
        InboxFilter.ALL -> true
        InboxFilter.NEEDS_YOU -> needs_you
        InboxFilter.RUNNING -> kind == "RUNNING"
        InboxFilter.REVIEW -> kind == "REVIEW"
    }

/** The Inbox as the Mac's feed: a summary, search, filters, then sections of compact tiles. */
@Composable
internal fun DesktopInbox(store: MobileStore) {
    val view by store.workspace.activity.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val session by store.session.slice.collectAsState()
    val selected by store.conversation.selectedCard.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(InboxFilter.ALL) }
    var project by rememberSaveable { mutableStateOf("") }
    var rules by remember { mutableStateOf(false) }
    val now = rememberNow()
    val scoped =
        view.rows.filter { row ->
            (project.isEmpty() || row.card?.project_id == project) &&
                Activity.matches(query, row.title, row.project_name, row.board_name)
        }
    val rows = scoped.filter { it.matches(filter) }
    val running = view.summary?.running ?: 0
    val attention = view.summary?.attention ?: 0
    Column(Modifier.fillMaxSize().testTag("activity-feed")) {
        ListBand("Inbox", "${view.rows.size}") {
            val menu = rememberMenuState()
            MenuAnchor(menu) {
                DesktopIconButton(
                    Glyph.FILTER,
                    "Filter",
                    {
                        menu.show(
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
                                        ChromeAction("inbox-rules", "Inbox rules…", Glyph.FILTER) {
                                            rules = true
                                        }
                                    )
                                ),
                            )
                        )
                    },
                    Modifier.testTag("inbox-filter"),
                    active = project.isNotEmpty(),
                )
            }
            DesktopCapsule(
                "New Task",
                { store.newConversation(chat = false) },
                Modifier.testTag("chrome-new-task"),
                glyph = Glyph.ADD,
                prominent = true,
            )
        }
        Row(Modifier.padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            StatusDot(tokens.running, size = 6.dp)
            Text(" $running running", color = tokens.subtle, fontSize = 11.sp)
            Text("  ·  ", color = tokens.tertiary, fontSize = 11.sp)
            StatusDot(tokens.attention, size = 6.dp)
            Text(" $attention need attention", color = tokens.subtle, fontSize = 11.sp)
            val hidden = view.summary?.hidden ?: 0
            if (hidden > 0)
                Text(
                    "  ·  $hidden hidden",
                    Modifier.desktopClickable({ rules = true }, RoundedCornerShape(4.dp))
                        .testTag("inbox-hidden"),
                    color = tokens.tertiary,
                    fontSize = 11.sp,
                )
        }
        DesktopSearchField(
            query,
            { query = it },
            "Search activity",
            Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 8.dp),
            testTag = "inbox-search",
        )
        DesktopSegments(
            InboxFilter.entries.map { value ->
                val total = scoped.count { it.matches(value) }
                if (value == InboxFilter.ALL || total == 0) value.title else "${value.title} $total"
            },
            filter.ordinal,
            { filter = InboxFilter.entries[it] },
            Modifier.padding(start = 4.dp, top = 8.dp, bottom = 4.dp),
            testTagPrefix = "inbox-filter",
        )
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 4.dp, end = 4.dp, top = 4.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
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
                        "Running work, replies and reviews appear here.",
                        Modifier.padding(top = 40.dp),
                    )
                }
            inboxSections(rows).forEach { (section, sectionRows) ->
                item("header-$section") {
                    DesktopSectionHeader(
                        when (section) {
                            InboxSection.RUNNING -> "Running"
                            InboxSection.PINNED -> "Pinned"
                            InboxSection.ATTENTION -> "Needs attention"
                            InboxSection.REVIEW -> "Ready for review"
                            InboxSection.RECENT -> "Recent"
                        },
                        Modifier.padding(top = 6.dp),
                    ) {
                        Text("${sectionRows.size}", style = MonoSmall, color = tokens.tertiary)
                    }
                }
                items(sectionRows, key = { "row-" + it.card!!.id }) { row ->
                    InboxTile(
                        store,
                        row,
                        now,
                        selected = row.card?.id == selected,
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
    if (rules) InboxRulesSheet(store) { rules = false }
}

@Composable
private fun InboxTile(
    store: MobileStore,
    row: ActivityRow,
    now: Instant,
    selected: Boolean,
    machine: String?,
) {
    val card = row.card ?: return
    val menu = rememberMenuState()
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val accent = row.tint()
    val shape = RoundedCornerShape(DesktopMetrics.tileRadius)
    MenuAnchor(menu) {
        Row(
            Modifier.fillMaxWidth()
                .height(IntrinsicSize.Min)
                .border(1.dp, if (selected) tokens.tileRimSelected else tokens.tileRim, shape)
                .hoverable(interaction)
                .desktopClickable(
                    { store.openConversation(card.id) },
                    shape,
                    selected = selected,
                    rest = tokens.tile,
                    onSecondary = { menu.show(cardMenuSections(store, card, row.can_finish)) },
                )
                .testTag("activity-row-${card.id}")
        ) {
            Box(
                Modifier.width(3.dp)
                    .fillMaxHeight()
                    .padding(vertical = 8.dp)
                    .background(accent, RoundedCornerShape(50))
            )
            Column(
                Modifier.weight(1f).padding(start = 9.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        row.title,
                        Modifier.weight(1f),
                        color = tokens.text,
                        fontSize = 13.sp,
                        lineHeight = 17.sp,
                        fontWeight =
                            if (row.kind == "RECENT") FontWeight.Medium else FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (hovered || row.pinned)
                        DesktopIconButton(
                            Glyph.PIN,
                            if (row.pinned) "Unpin from inbox" else "Pin in inbox",
                            {
                                store.command(
                                    Command(
                                        navigation =
                                            NavigationCommand(
                                                pin_inbox_card = PinInboxCard(card.id, !row.pinned)
                                            )
                                    )
                                )
                            },
                            Modifier.testTag("inbox-pin-${card.id}"),
                            active = row.pinned,
                            size = 20.dp,
                        )
                }
                Text(
                    listOfNotNull(
                            row.project_name.ifEmpty { null },
                            row.board_name.ifEmpty { if (row.chat) "Chat" else null },
                            machine,
                        )
                        .joinToString(" · "),
                    color = tokens.tertiary,
                    fontSize = 10.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (row.detail.isNotEmpty())
                    Text(
                        row.detail,
                        color = tokens.subtle,
                        fontSize = 11.5.sp,
                        lineHeight = 15.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                if (row.stale.isNotEmpty())
                    Text(row.stale, color = tokens.attention, fontSize = 10.5.sp)
                Row(Modifier.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (row.kind == "RUNNING") LiveDot(accent, size = 6.dp)
                    else StatusDot(accent, size = 6.dp)
                    Spacer(Modifier.width(5.dp))
                    Text(
                        row.kind_label,
                        color = accent,
                        fontSize = 10.5.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                    )
                    Spacer(Modifier.width(6.dp))
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
                    Spacer(Modifier.weight(1f))
                    if (row.can_finish)
                        DesktopCapsule(
                            "Finish",
                            { store.command(Command(finish_card = FinishCard(card.id))) },
                            Modifier.testTag("finish-${card.id}"),
                            glyph = Glyph.CHECK,
                            height = 22.dp,
                        )
                }
            }
        }
    }
}

/** Chats grouped as the core lays them out: pinned, folders, projects, then the rest. */
@Composable
internal fun DesktopChats(store: MobileStore) {
    val workspace by store.workspace.slice.collectAsState()
    val view by store.workspace.chats.collectAsState()
    val selected by store.conversation.selectedCard.collectAsState()
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
    fun cardFor(id: String) =
        (if (archived) view.archived else workspace.cards).firstOrNull { it.id == id }
    Column(Modifier.fillMaxSize().testTag("chats-list")) {
        ListBand(
            if (archived) "Archived chats" else "Chats",
            "${if (archived) view.archived.size else view.visible_ids.size}",
        ) {
            DesktopIconButton(
                Glyph.ARCHIVE,
                if (archived) "Current chats" else "Archived chats",
                { setArchived(!archived) },
                Modifier.testTag("chats-archived"),
                active = archived,
            )
            DesktopCapsule(
                "New Chat",
                { store.newConversation(chat = true) },
                Modifier.testTag("chrome-new-chat"),
                glyph = Glyph.ADD,
                prominent = true,
            )
        }
        DesktopSearchField(
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
            "Search chats",
            Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, bottom = 6.dp),
            testTag = "chats-search",
        )
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 4.dp, end = 4.dp, bottom = 16.dp),
        ) {
            fun LazyListScope.group(key: String, ids: List<String>) {
                val cards = ids.mapNotNull(::cardFor)
                if (cards.isEmpty()) return
                item("g-$key") {
                    Column(
                        Modifier.fillMaxWidth()
                            .padding(bottom = 6.dp)
                            .background(tokens.tile, RoundedCornerShape(12.dp))
                            .border(1.dp, tokens.tileRim, RoundedCornerShape(12.dp))
                            .padding(3.dp)
                    ) {
                        cards.forEachIndexed { index, card ->
                            if (index > 0)
                                Box(
                                    Modifier.padding(start = 27.dp)
                                        .fillMaxWidth()
                                        .height(1.dp)
                                        .background(tokens.hairline)
                                )
                            ChatLine(store, card, now, archived, card.id == selected)
                        }
                    }
                }
            }
            if (archived) group("archived", view.archived.map { it.id })
            else {
                if (view.pinned_ids.isNotEmpty()) {
                    item("h-pinned") { DesktopSectionHeader("Pinned") }
                    group("pinned", view.pinned_ids)
                }
                view.folders.forEach { folder ->
                    item("h-folder-${folder.folder_id}") {
                        GroupHeader(
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
                    if (folder.show_chats) group("folder-${folder.folder_id}", folder.chat_ids)
                }
                view.projects.forEach { section ->
                    val name =
                        workspace.projects.firstOrNull { it.id == section.project_id }?.name
                            ?: "Project"
                    item("h-project-${section.project_id}") {
                        GroupHeader(name, section.total, !section.collapsed, null) {
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
                    }
                    if (section.show_chats) group("project-${section.project_id}", section.chat_ids)
                    if (section.toggle_label.isNotEmpty())
                        item("t-${section.project_id}") {
                            Text(
                                section.toggle_label,
                                Modifier.padding(start = 10.dp, bottom = 6.dp)
                                    .desktopClickable(
                                        {
                                            store.command(
                                                Command(
                                                    set_chats_show_all =
                                                        SetChatsShowAll(
                                                            project_id = section.project_id,
                                                            show_all = !section.show_all,
                                                        )
                                                )
                                            )
                                        },
                                        RoundedCornerShape(5.dp),
                                    )
                                    .padding(horizontal = 4.dp, vertical = 2.dp),
                                color = tokens.action,
                                fontSize = 11.5.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                }
                if (view.other_ids.isNotEmpty()) {
                    item("h-other") { DesktopSectionHeader("Other") }
                    group("other", view.other_ids)
                }
            }
            if ((archived && view.archived.isEmpty()) || (!archived && view.visible_ids.isEmpty()))
                item("empty") {
                    EmptyState(
                        if (archived) Glyph.ARCHIVE else Glyph.CHATS,
                        if (archived) "No archived chats"
                        else if (query.isNotBlank()) "No results" else "No chats yet",
                        if (archived) "Archived chats appear here."
                        else "Start a conversation about any of your projects.",
                        Modifier.padding(top = 40.dp),
                    )
                }
        }
    }
}

@Composable
private fun GroupHeader(
    title: String,
    count: Int,
    expanded: Boolean,
    glyph: Glyph?,
    onToggle: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .height(24.dp)
            .desktopClickable(onToggle, RoundedCornerShape(6.dp))
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (expanded) Glyph.CHEVRON_DOWN else Glyph.CHEVRON_RIGHT,
            null,
            tint = tokens.tertiary,
            size = 11.dp,
            weight = GlyphWeight.BOLD,
        )
        Spacer(Modifier.width(5.dp))
        if (glyph != null) {
            Icon(glyph, null, tint = tokens.subtle, size = 13.dp)
            Spacer(Modifier.width(5.dp))
        }
        Text(
            title,
            Modifier.weight(1f),
            color = tokens.subtle,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
        Text("$count", color = tokens.tertiary, fontSize = 11.sp)
    }
}

@Composable
private fun ChatLine(
    store: MobileStore,
    card: Card,
    now: Instant,
    archived: Boolean,
    selected: Boolean,
) {
    val menu = rememberMenuState()
    val running = card.lane == "running" || card.runtime == "running"
    val unread = card.response_seq > card.seen_response_seq
    val project = store.workspace.slice.value.projects.firstOrNull { it.id == card.project_id }
    val sections = {
        if (archived)
            listOf(
                MenuSection(
                    listOf(
                        ChromeAction("restore", "Restore", Glyph.UNARCHIVE) {
                            store.command(Command(restore_card = RestoreCard(card_id = card.id)))
                        }
                    )
                )
            )
        else cardMenuSections(store, card)
    }
    MenuAnchor(menu) {
        Row(
            Modifier.fillMaxWidth()
                .desktopClickable(
                    { store.openConversation(card.id) },
                    RoundedCornerShape(7.dp),
                    selected = selected,
                    selectedFill = tokens.selection,
                    onSecondary = { menu.show(sections()) },
                )
                .padding(horizontal = 8.dp, vertical = 6.dp)
                .testTag("chat-${card.id}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(15.dp), contentAlignment = Alignment.Center) {
                Box(
                    Modifier.size(11.dp)
                        .border(
                            1.5.dp,
                            (if (running) tokens.running else tokens.tertiary).copy(alpha = .7f),
                            CircleShape,
                        )
                )
                if (running) LiveDot(tokens.running, size = 5.dp)
                else Box(Modifier.size(5.dp).background(tokens.tertiary.copy(.5f), CircleShape))
            }
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (card.pinned) {
                        Icon(Glyph.PIN, "Pinned", tint = tokens.tertiary, size = 10.dp)
                        Spacer(Modifier.width(3.dp))
                    }
                    Text(
                        Activity.title(card),
                        Modifier.weight(1f),
                        color = tokens.text,
                        fontSize = 12.5.sp,
                        fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    if (running) "Running" else card.summary.ifBlank { project?.name.orEmpty() },
                    color = if (running) tokens.running else tokens.tertiary,
                    fontSize = 10.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (unread) {
                StatusDot(tokens.action, size = 6.5.dp)
                Spacer(Modifier.width(6.dp))
            }
            Text(CardAges.compact(card, now), style = MonoSmall, color = tokens.tertiary)
        }
    }
}
