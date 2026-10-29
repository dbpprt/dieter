@file:OptIn(
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package com.getdieter.mobile.board

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.board.CardPolicy
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*

/** Long-press and "…" actions shared by inbox rows, chats and board cards. */
internal fun cardMenuSections(
    store: MobileStore,
    card: Card,
    canFinish: Boolean = false,
    onEdit: ((Card) -> Unit)? = null,
): List<MenuSection> {
    val workspace = store.workspace.slice.value
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
                if (store.conversation.selectedCard.value == card.id) store.pop()
            },
        )
    return listOf(MenuSection(primary), MenuSection(organize), MenuSection(more)).filter {
        it.actions.isNotEmpty()
    }
}

/** Edits a card's title, and its task while it has not been sent. */
@Composable
internal fun CardEditSheet(store: MobileStore, card: Card, onDismiss: () -> Unit) {
    var title by remember(card.id) { mutableStateOf(card.title) }
    var prompt by remember(card.id) { mutableStateOf(card.initial_prompt) }
    val editable = CardPolicy.canEditDraft(card)
    val valid =
        if (editable) CardPolicy.draftProblem(card, title, prompt, null) == null
        else title.isNotBlank()
    Sheet(
        "Edit card",
        onDismiss,
        confirm =
            ChromeAction("save-card", "Save", Glyph.CHECK, enabled = valid) {
                store.command(
                    if (editable)
                        Command(
                            update_card_draft =
                                UpdateCardDraft(card_id = card.id, title = title, prompt = prompt)
                        )
                    else Command(rename_card = RenameCard(card.id, title))
                )
                onDismiss()
            },
    ) {
        Column(
            Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            MobileTextField(
                title,
                { title = it },
                Modifier.fillMaxWidth().testTag("edit-title"),
                label = { Text("Title") },
                singleLine = true,
            )
            MobileTextField(
                prompt,
                { prompt = it },
                Modifier.fillMaxWidth().heightIn(min = 140.dp).testTag("edit-prompt"),
                label = { Text("Task") },
                readOnly = !editable,
                minLines = 5,
                supportingText =
                    if (!editable) ({ Text("This task was already sent to the agent.") }) else null,
            )
        }
    }
}
