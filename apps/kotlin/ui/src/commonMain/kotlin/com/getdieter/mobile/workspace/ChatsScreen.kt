@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.activity.Activity
import com.getdieter.core.board.CardAges
import com.getdieter.mobile.app.*
import com.getdieter.mobile.board.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlin.time.Instant
import kotlinx.coroutines.flow.drop

/**
 * Chats grouped by project (and the user's chat folders), each group a collapsible section of dense
 * rows: the project's avatar, the title and its age, then the last summary.
 */
@Composable
internal fun ChatsScreen(store: MobileStore) {
    val workspace by store.workspace.slice.collectAsState()
    val refreshing by store.session.refreshing.collectAsState()
    val view by store.workspace.chats.collectAsState()
    val selected by store.conversation.selectedCard.collectAsState()
    val search = rememberListSearch("chats", "Search chats")
    val query = search.query
    var archived by rememberSaveable { mutableStateOf(false) }
    val now = rememberNow()
    // The core filters the chats; it keeps the query, so only changes are sent.
    LaunchedEffect(store) {
        snapshotFlow { search.query }
            .drop(1)
            .collect {
                store.command(
                    Command(
                        chats =
                            ChatsCommand(scope = MobileStore.CHATS_SCOPE, query = ChatsQuery(it))
                    )
                )
            }
    }
    fun setArchived(value: Boolean) {
        archived = value
        store.command(
            Command(
                chats = ChatsCommand(scope = MobileStore.CHATS_SCOPE, show_archived = Toggle(value))
            )
        )
    }
    val shown = if (archived) view.archived.size else view.visible_ids.size
    val chrome =
        ScreenChrome(
            if (archived) "Archived chats" else "Chats",
            subtitle = if (shown == 0) "" else "$shown chat${if (shown == 1) "" else "s"}",
            large = false,
            actions =
                listOf(
                    search.action(),
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
                    ),
                ),
            primary = newTaskAction(store, chat = true),
        )
    fun cardFor(id: String) =
        (if (archived) view.archived else workspace.cards).firstOrNull { it.id == id }
    Screen(chrome) {
        RefreshableList(
            refreshing = refreshing || view.loading,
            onRefresh = store.session::refresh,
            tag = "chats-refresh",
            topInset = padding.calculateTopPadding(),
        ) {
            LazyColumn(
                Modifier.fillMaxSize().testTag("chats-list"),
                state = listState,
                contentPadding = padding,
            ) {
                titleHeader()
                item("notice") { ConnectionNotice(store) }
                if (search.shown) item("search") { search.Field() }
                fun section(key: String, title: String?, ids: List<String>) {
                    val cards = ids.mapNotNull(::cardFor)
                    if (title != null)
                        item("h-$key") { ListSectionHeader(title, count = cards.size) }
                    itemsIndexed(cards, key = { _, card -> "$key-${card.id}" }) { index, card ->
                        Box(Modifier.animateItem(placementSpec = Motion.settle())) {
                            ChatRow(store, card, index == 0, now, archived, selected == card.id)
                        }
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
                            CollapsibleHeader(name, project.total, !project.collapsed) {
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
                                    // Under the rows' titles.
                                    Modifier.padding(start = 12.dp + ListLeading, top = 2.dp),
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
                if (
                    (archived && view.archived.isEmpty()) ||
                        (!archived && view.visible_ids.isEmpty())
                )
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
}

/** A folder's or project's section header; tapping it collapses or expands the section. */
@Composable
private fun CollapsibleHeader(title: String, count: Int, expanded: Boolean, toggle: () -> Unit) {
    ListSectionHeader(
        title,
        Modifier.pressable(onClick = toggle),
        count = count,
        trailing = {
            Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                DisclosureChevron(expanded)
            }
        },
    )
}

@Composable
private fun ChatRow(
    store: MobileStore,
    card: Card,
    first: Boolean,
    now: Instant,
    archived: Boolean,
    selected: Boolean,
) {
    val menu = rememberMenuState()
    val project = store.workspace.slice.value.projects.firstOrNull { it.id == card.project_id }
    val running = card.lane == "running" || card.runtime == "running"
    val surface = listRowSurface(selected)
    val summary = card.summary.ifBlank { project?.name.orEmpty() }
    MenuAnchor(menu) {
        ListRow(
            onClick = { store.openConversation(card.id) },
            modifier = Modifier.testTag("chat-${card.id}"),
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
            surface = surface,
            first = first,
            leading = { ChatAvatar(card.project_id, project?.name, running, surface) },
            meta = { ListMeta(CardAges.compact(card, now)) },
            subtitle = if (summary.isEmpty()) null else ({ ListSubtitle(summary) }),
        ) {
            if (card.pinned)
                Icon(
                    Glyph.PIN,
                    "Pinned",
                    Modifier.padding(end = 4.dp),
                    tint = palette.secondaryLabel,
                    size = 13.dp,
                )
            ListTitle(Activity.title(card))
        }
    }
}

/** The chat's project avatar, or a chat bubble without a project; a working agent adds a dot. */
@Composable
private fun ChatAvatar(projectId: String, projectName: String?, running: Boolean, surface: Color) {
    Box(Modifier.size(ListLeading), contentAlignment = Alignment.Center) {
        if (projectName != null) ProjectAvatar(projectId, projectName, ListTile)
        else ListIconTile(Glyph.CHAT)
        if (running)
            Box(
                Modifier.align(Alignment.BottomEnd).size(16.dp).background(surface, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                LiveDot(palette.info, size = 11.dp)
            }
    }
}
