@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.board

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.activity.Activity
import com.getdieter.core.board.CardAges
import com.getdieter.core.board.Cards
import com.getdieter.core.presentation.TokenCounts
import com.getdieter.core.presentation.TokenUsagePresentation
import com.getdieter.core.workspace.WorkspaceBadge
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlin.time.Clock

/** A task card: labels, title, summary, workspace badges, agent status and actions. */
@Composable
internal fun WorkCard(
    store: MobileStore,
    card: Card,
    board: Board?,
    selected: Boolean = false,
    machine: String,
    modifier: Modifier = Modifier,
    drag: BoardCardDragState? = null,
    onEdit: (Card) -> Unit = {},
) {
    val outbox by store.workspace.outbox.collectAsState()
    val view by store.boards.slice.collectAsState()
    val flags = view.cards[card.id]
    val pending = card.id in outbox.pending_card_ids
    val age = CardAges.compact(card, Clock.System.now())
    val badge = WorkspaceBadge.of(card)
    val menu = rememberMenuState()
    var bounds by remember { mutableStateOf(Rect.Zero) }
    val sections = { cardMenuSections(store, card, onEdit = onEdit) }
    val labels = board?.labels.orEmpty().filter { it.id in card.label_ids }
    val tone =
        when (flags?.tone) {
            RuntimeTone.RUNTIME_TONE_ACTIVE -> palette.info
            RuntimeTone.RUNTIME_TONE_ATTENTION -> palette.warning
            RuntimeTone.RUNTIME_TONE_FAILED -> palette.destructive
            RuntimeTone.RUNTIME_TONE_DONE -> palette.success
            else -> palette.secondaryLabel
        }
    MenuAnchor(menu, modifier) {
        ContentCard(
            Modifier.onGloballyPositioned { bounds = it.boundsInRoot() }
                .then(
                    if (drag != null)
                        Modifier.pointerInput(card.id) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = { point -> drag.start(card, bounds.topLeft + point) },
                                onDrag = { change, amount ->
                                    change.consume()
                                    drag.moveTo(drag.pointerInRoot + amount)
                                },
                                onDragCancel = drag::reset,
                                onDragEnd = {
                                    drag.finish()?.let { drop ->
                                        store.command(
                                            Command(move_card = MoveCard(drop.cardId, drop.laneId))
                                        )
                                    }
                                },
                            )
                        }
                    else Modifier
                )
                .testTag("card-${card.id}"),
            selected = selected,
            onClick = { store.openConversation(card.id) },
            onLongClick = if (drag == null) ({ menu.show(sections()) }) else null,
            contentPadding = PaddingValues(start = 16.dp, end = 8.dp, top = 14.dp, bottom = 10.dp),
        ) {
            Column(Modifier.padding(end = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (labels.isNotEmpty())
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        labels.take(3).forEach { label -> LabelPill(label.name, label.color) }
                        if (labels.size > 3)
                            Text(
                                "+${labels.size - 3}",
                                style = type.caption,
                                color = palette.secondaryLabel,
                            )
                    }
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        Activity.title(card),
                        Modifier.weight(1f),
                        style = type.headline,
                        color = palette.label,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (age.isNotEmpty())
                        Text(
                            age,
                            Modifier.padding(start = 10.dp, top = 2.dp).semantics {
                                contentDescription = "Last activity $age"
                            },
                            style = type.footnote,
                            color = palette.secondaryLabel,
                        )
                }
                if (card.summary.isNotBlank())
                    Text(
                        card.summary,
                        style = type.subheadline,
                        color = palette.secondaryLabel,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(5.dp),
                    modifier = Modifier.padding(top = 2.dp),
                ) {
                    if (store.session.slice.value.machines.size > 1)
                        MetaPill(machine, Glyph.MACHINE, accessibility = "Machine $machine")
                    badge?.let {
                        MetaPill(
                            it.title,
                            Glyph.BRANCH,
                            tint =
                                if (it.conflicted) palette.destructive else palette.secondaryLabel,
                            accessibility = it.accessibilityLabel,
                        )
                    }
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(top = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    val status =
                        flags
                            ?.takeIf {
                                it.tone != RuntimeTone.RUNTIME_TONE_IDLE || it.badge.isNotEmpty()
                            }
                            ?.runtime_label
                            ?.ifEmpty { flags.badge }
                            .orEmpty()
                            .ifEmpty { if (pending) "Syncing…" else "" }
                    if (status.isNotEmpty())
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (flags?.tone == RuntimeTone.RUNTIME_TONE_ACTIVE)
                                LiveDot(tone, size = 8.dp)
                            else Box(Modifier.size(7.dp).background(tone, CircleShape))
                            Spacer(Modifier.width(6.dp))
                            Text(
                                status,
                                style = type.footnote.copy(fontWeight = FontWeight.Medium),
                                color = tone.readableOn(palette.cell),
                                maxLines = 1,
                            )
                        }
                    Text(
                        listOfNotNull(
                                Cards.agent(card),
                                card.token_usage
                                    ?.let(::TokenUsagePresentation)
                                    ?.takeIf { it.reported }
                                    ?.label(),
                            )
                            .joinToString(" · "),
                        style = type.footnote,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier =
                            Modifier.semantics {
                                card.token_usage
                                    ?.let(::TokenUsagePresentation)
                                    ?.takeIf { it.reported }
                                    ?.let { contentDescription = TokenCounts.detail(it.usage) }
                            },
                    )
                }
                if (
                    flags?.can_start == true ||
                        (flags == null &&
                            card.lane == "todo" &&
                            card.initial_prompt_sent_at.isEmpty())
                )
                    DButton(
                        if (flags?.starting == true) "Starting…" else "Start",
                        { store.command(Command(start_card = StartCard(card.id))) },
                        Modifier.padding(start = 8.dp).testTag("start-${card.id}"),
                        kind = ButtonKind.PROMINENT,
                        glyph = Glyph.PLAY,
                        enabled = flags?.starting != true,
                    )
                MenuButton(sections(), "Card actions", Modifier.testTag("card-menu-${card.id}"))
            }
        }
    }
}
