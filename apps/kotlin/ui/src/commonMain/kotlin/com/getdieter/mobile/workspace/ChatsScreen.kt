@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
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

@Composable
internal fun ChatsScreen(store: MobileStore) {
    val workspace by store.workspace.slice.collectAsState()
    val refreshing by store.session.refreshing.collectAsState()
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
                                    Modifier.padding(
                                        horizontal = ScreenMargin + 4.dp,
                                        vertical = 4.dp,
                                    ),
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
    val project = store.workspace.slice.value.projects.firstOrNull { it.id == card.project_id }
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
