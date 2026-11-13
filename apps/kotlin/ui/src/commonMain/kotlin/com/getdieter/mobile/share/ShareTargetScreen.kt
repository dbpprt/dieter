package com.getdieter.mobile.share

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.core.activity.Activity
import com.getdieter.core.board.Cards
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*

/** Picks the task or chat a share goes to; its composer then holds the shared items. */
@Composable
internal fun ShareTargetScreen(store: MobileStore, chat: Boolean) {
    val workspace by store.workspace.slice.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    val matches =
        workspace.cards.filter { card ->
            Cards.isChat(card) == chat &&
                Activity.matches(
                    query,
                    card.title,
                    workspace.projects.firstOrNull { it.id == card.project_id }?.name,
                    workspace.boards.firstOrNull { it.id == card.board_id }?.name,
                )
        }
    val chrome =
        ScreenChrome(
            if (chat) "Choose Chat" else "Choose Task",
            cancel = ChromeAction("cancel-share", "Cancel", Glyph.CLOSE) { store.sharing.cancel() },
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("share-targets"),
            state = listState,
            contentPadding = padding,
        ) {
            item("search") {
                SearchField(
                    query,
                    { query = it },
                    if (chat) "Search chats" else "Search tasks",
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                )
            }
            if (matches.isEmpty())
                item("empty") {
                    EmptyState(
                        if (chat) Glyph.CHATS else Glyph.CHECKLIST,
                        when {
                            query.isNotBlank() -> "No results"
                            chat -> "No chats"
                            else -> "No tasks"
                        },
                        if (query.isNotBlank()) "Nothing matches “$query”."
                        else "Create one in Dieter, then share this item again.",
                    )
                }
            itemsIndexed(matches, key = { _, card -> card.id }) { index, card ->
                ListRow(
                    Activity.title(card),
                    Modifier.testTag("share-target-${card.id}"),
                    position = Position.of(index, matches.size),
                    subtitle = workspace.projects.firstOrNull { it.id == card.project_id }?.name,
                    accessory = Accessory.CHEVRON,
                    onClick = { store.sharing.shareInto(card.id) },
                )
            }
        }
    }
}

/**
 * "Save to folder…": picks the synced folder on this device that another app's files are saved
 * into. Folders that are download only here are not offered.
 */
@Composable
internal fun SaveToFolderScreen(store: MobileStore) {
    val list by store.folders.list.collectAsState()
    val shared by store.sharing.target.collectAsState()
    val busy by store.busy.collectAsState()
    val folders = list.folders.filter { it.accepts_files }
    val files = shared?.files.orEmpty()
    val chrome =
        ScreenChrome(
            "Save to Folder",
            subtitle =
                when (files.size) {
                    0 -> ""
                    1 -> files.single().name
                    else -> "${files.size} files"
                },
            cancel = ChromeAction("cancel-share", "Cancel", Glyph.CLOSE) { store.sharing.cancel() },
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("share-folders"),
            state = listState,
            contentPadding = padding,
        ) {
            if (files.isEmpty())
                item("nothing") {
                    EmptyState(
                        Glyph.FILE,
                        "Nothing to save",
                        "Only files can be saved to a folder. Share files from the other app.",
                    )
                }
            else if (folders.isEmpty())
                item("empty") {
                    EmptyState(
                        Glyph.FOLDER,
                        if (list.loading) "Loading folders" else "No folder takes files here",
                        "Keep a folder on this device, two-way or upload only, then share again.",
                    )
                }
            else
                item("header") {
                    SectionHeader("Folders on this device")
                }
            if (files.isNotEmpty())
                itemsIndexed(folders, key = { _, row -> row.id }) { index, row ->
                    ListRow(
                        row.name,
                        Modifier.testTag("share-folder-${row.id}"),
                        position = Position.of(index, folders.size),
                        subtitle =
                            listOf(row.direction, row.status)
                                .filter { it.isNotBlank() }
                                .joinToString(" · "),
                        glyph = Glyph.FOLDER,
                        enabled = !busy,
                        accessory = Accessory.CHEVRON,
                        onClick = { store.sharing.saveInto(row.id) },
                    )
                }
        }
    }
}
