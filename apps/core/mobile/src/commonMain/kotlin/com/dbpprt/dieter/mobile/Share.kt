package com.dbpprt.dieter.mobile

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.board.Cards

/** Where another app's share goes: a new task, or an existing task or chat. */
enum class ShareDestination {
    NEW_TASK,
    TASK,
    CHAT,
}

/**
 * What another app shared into Dieter. [problem] reports items that could not be read; the rest
 * still arrive.
 */
class SharedItems(
    val text: String,
    val attachments: List<MessagePart>,
    val destination: ShareDestination,
    val problem: String = "",
)

/** Picks the task or chat a share goes to; its composer then holds the shared items. */
@Composable
internal fun ShareTargetScreen(store: MobileStore, chat: Boolean) {
    val workspace by store.workspace.collectAsState()
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
            cancel = ChromeAction("cancel-share", "Cancel", Glyph.CLOSE) { store.cancelShare() },
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
                    onClick = { store.shareInto(card.id) },
                )
            }
        }
    }
}
