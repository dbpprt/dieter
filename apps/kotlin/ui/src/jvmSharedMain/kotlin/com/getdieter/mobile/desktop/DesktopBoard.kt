@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.SaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.activity.Activity
import com.getdieter.core.board.CardAges
import com.getdieter.core.board.Cards
import com.getdieter.core.presentation.TokenUsagePresentation
import com.getdieter.core.workspace.WorkspaceBadge
import com.getdieter.mobile.admin.ArchivedCards
import com.getdieter.mobile.admin.BoardSettings
import com.getdieter.mobile.app.ChromeAction
import com.getdieter.mobile.app.MenuSection
import com.getdieter.mobile.board.BoardCardDragState
import com.getdieter.mobile.board.CardEditSheet
import com.getdieter.mobile.board.cardMenuSections
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

/**
 * A project's board, as on the Mac: one toolbar across the window, every lane side by side, and the
 * open conversation in a panel on the right that can be widened over the board.
 */
@Composable
internal fun DesktopBoard(
    store: MobileStore,
    place: DesktopPlace,
    detail: List<MobileRoute>,
    widths: Map<DesktopPane, Float>,
    holder: SaveableStateHolder,
    openUrl: (String) -> Unit,
    modifier: Modifier,
) {
    val workspace by store.workspace.slice.collectAsState()
    val view by store.boards.slice.collectAsState()
    val selectedBoard by store.boards.selectedBoard.collectAsState()
    val boardId = place.boardId
    val board = workspace.boards.firstOrNull { it.id == boardId }
    val ready = selectedBoard == boardId && workspace.loaded
    var settings by remember { mutableStateOf(false) }
    var archived by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<Card?>(null) }
    Column(modifier.fillMaxSize().padding(start = 0.dp)) {
        BoardToolbar(
            store,
            board,
            view,
            ready,
            onSettings = { settings = true },
            onArchived = { archived = true },
        )
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val total = maxWidth.value
            var dragged by remember { mutableStateOf<Float?>(null) }
            val preferred = dragged ?: widths.getValue(DesktopPane.CONVERSATION)
            val panel = DesktopLayout.conversationWidth(total, preferred)
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    when {
                        !ready ->
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Spinner(Modifier.size(22.dp))
                            }
                        view.lanes.isEmpty() ->
                            EmptyState(Glyph.BOARD, "No lanes", "This board has no lanes to show.")
                        else ->
                            Kanban(store, board, view, workspace.cards, onEdit = { editing = it })
                    }
                }
                if (detail.isNotEmpty()) {
                    ResizeHandle(
                        onDrag = {
                            dragged = DesktopPane.CONVERSATION.clamp((dragged ?: preferred) - it)
                        },
                        onEnd = {
                            dragged?.let {
                                store.layout.setDesktopWidth(DesktopPane.CONVERSATION, it)
                            }
                            dragged = null
                        },
                        testTag = "conversation-resize",
                    )
                    DesktopPanel(
                        Modifier.width(panel.dp).fillMaxHeight().testTag("desktop-detail")
                    ) {
                        DetailPane(store, detail, holder, openUrl)
                    }
                }
            }
        }
    }
    if (settings) BoardSettings(store, boardId) { settings = false }
    if (archived) ArchivedCards(store, boardId) { archived = false }
    editing?.let { card -> CardEditSheet(store, card) { editing = null } }
}

/** Board picker, label segments, search, filters and New Task. */
@Composable
private fun BoardToolbar(
    store: MobileStore,
    board: Board?,
    view: BoardViewSlice,
    ready: Boolean,
    onSettings: () -> Unit,
    onArchived: () -> Unit,
) {
    val workspace by store.workspace.slice.collectAsState()
    val target by store.boards.filter.collectAsState()
    val session by store.session.slice.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == board?.project_id }
    val toggle = LocalSidebarToggle.current
    Row(
        Modifier.fillMaxWidth().height(DesktopMetrics.titleBand).padding(start = 4.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (toggle != null)
            DesktopIconButton(
                Glyph.LIST,
                "Show sidebar",
                toggle,
                Modifier.testTag("sidebar-show"),
                tooltip = "Show sidebar (Ctrl+B)",
            )
        val picker = rememberMenuState()
        MenuAnchor(picker) {
            Row(
                Modifier.height(DesktopMetrics.control)
                    .border(1.dp, tokens.controlRim, RoundedCornerShape(50))
                    .desktopClickable(
                        {
                            picker.show(
                                workspace.projects.mapNotNull { item ->
                                    val boards =
                                        workspace.boards.filter { it.project_id == item.id }
                                    if (boards.isEmpty()) null
                                    else
                                        MenuSection(
                                            boards.map { b ->
                                                ChromeAction(
                                                    "switch-${b.id}",
                                                    b.name,
                                                    checked = b.id == board?.id,
                                                    value =
                                                        workspace.board_attention[b.id]
                                                            ?.toString()
                                                            .orEmpty(),
                                                ) {
                                                    store.openProject(
                                                        item.id,
                                                        ProjectPage.BOARD,
                                                        b.id,
                                                    )
                                                }
                                            },
                                            title = item.name,
                                        )
                                }
                            )
                        },
                        RoundedCornerShape(50),
                        rest = tokens.control,
                    )
                    .padding(horizontal = 12.dp)
                    .testTag("board-picker"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                project?.let {
                    ProjectMark(it.id, it.name, 16.dp)
                    Spacer(Modifier.width(7.dp))
                }
                Text(
                    board?.name ?: "Board",
                    color = tokens.text,
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    modifier = Modifier.testTag("board-title"),
                )
                if (ready) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "${view.total}",
                        color = tokens.tertiary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
                Spacer(Modifier.width(5.dp))
                Icon(
                    Glyph.CHEVRON_DOWN,
                    null,
                    tint = tokens.tertiary,
                    size = 11.dp,
                    weight = GlyphWeight.BOLD,
                )
            }
        }
        val labels = board?.labels.orEmpty()
        if (labels.isNotEmpty()) {
            val selected = labels.indexOfFirst { it.id == target.label_id } + 1
            DesktopSegments(
                listOf("All") + labels.map { "#${it.name} ${view.label_counts[it.id] ?: 0}" },
                selected,
                { index ->
                    store.boards.filterBoard(
                        target.copy(label_id = if (index == 0) "" else labels[index - 1].id)
                    )
                },
                Modifier.weight(1f, fill = false).horizontalScroll(rememberScrollState()),
                testTagPrefix = "label-segment",
            )
        }
        Spacer(Modifier.weight(1f))
        DesktopSearchField(
            target.query,
            { store.boards.filterBoard(target.copy(query = it)) },
            "Search cards",
            Modifier.width(200.dp),
            testTag = "board-search",
        )
        val filterMenu = rememberMenuState()
        MenuAnchor(filterMenu) {
            DesktopIconButton(
                Glyph.FILTER,
                "Filter",
                {
                    filterMenu.show(
                        listOfNotNull(
                            MenuSection(
                                view.state_options.map { option ->
                                    ChromeAction(
                                        "state-${option.state.name}",
                                        option.title,
                                        checked = option.state == target.state,
                                    ) {
                                        store.boards.filterBoard(target.copy(state = option.state))
                                    }
                                },
                                title = "Show",
                            ),
                            if (view.machine_ids.size > 1 || target.machine_id.isNotEmpty())
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "machine-all",
                                            "All machines",
                                            checked = target.machine_id.isEmpty(),
                                        ) {
                                            store.boards.filterBoard(target.copy(machine_id = ""))
                                        }
                                    ) +
                                        view.machine_ids.map { id ->
                                            ChromeAction(
                                                "machine-$id",
                                                session.machines
                                                    .firstOrNull { it.id == id }
                                                    ?.display_name ?: id,
                                                checked = target.machine_id == id,
                                            ) {
                                                store.boards.filterBoard(
                                                    target.copy(machine_id = id)
                                                )
                                            }
                                        },
                                    title = "Machine",
                                )
                            else null,
                        )
                    )
                },
                Modifier.testTag("board-filter"),
                active =
                    target.state != BoardStateFilter.BOARD_STATE_FILTER_ALL ||
                        target.machine_id.isNotEmpty(),
            )
        }
        DesktopIconButton(
            Glyph.ARCHIVE,
            "Archived cards",
            onArchived,
            Modifier.testTag("board-archived"),
        )
        DesktopIconButton(
            Glyph.SETTINGS,
            "Board settings",
            onSettings,
            Modifier.testTag("board-settings"),
        )
        DesktopCapsule(
            "New Task",
            { store.newConversation(chat = false) },
            Modifier.testTag("chrome-new-task"),
            glyph = Glyph.ADD,
            prominent = true,
        )
    }
}

/** Every lane side by side: equal widths filling the board, at least 264 dp, else scrolling. */
@Composable
private fun Kanban(
    store: MobileStore,
    board: Board?,
    view: BoardViewSlice,
    cards: List<Card>,
    onEdit: (Card) -> Unit,
) {
    val drag = remember(board?.id) { BoardCardDragState() }
    val selected by store.conversation.selectedCard.collectAsState()
    val session by store.session.slice.collectAsState()
    val byId = remember(cards) { cards.associateBy { it.id } }
    BoxWithConstraints(Modifier.fillMaxSize().testTag("desktop-kanban")) {
        val gap = 9f
        val lane = DesktopLayout.laneWidth(maxWidth.value - 4f, view.lanes.size, gap)
        Row(
            Modifier.fillMaxSize().horizontalScroll(rememberScrollState()).padding(end = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(gap.dp),
        ) {
            view.lanes.forEach { item ->
                Lane(store, board, item, byId, view.cards, lane, drag, selected, session, onEdit)
            }
        }
        // The dragged card follows the pointer above the lanes.
        drag.card?.let { card ->
            val pointer = drag.pointerInRoot
            var origin by remember { mutableStateOf(Offset.Zero) }
            Box(
                Modifier.fillMaxSize().onGloballyPositioned { origin = it.boundsInRoot().topLeft }
            ) {
                if (pointer.isSpecifiedOffset())
                    Box(
                        Modifier.graphicsLayer {
                                translationX = pointer.x - origin.x - 40f
                                translationY = pointer.y - origin.y - 20f
                                alpha = .9f
                                rotationZ = -1.5f
                            }
                            .width((lane * .9f).dp)
                    ) {
                        DesktopCard(
                            store,
                            card,
                            board,
                            view.cards[card.id],
                            false,
                            "",
                            null,
                            {},
                            dragging = true,
                        )
                    }
            }
        }
    }
}

private fun Offset.isSpecifiedOffset() = this != Offset.Unspecified

@Composable
private fun Lane(
    store: MobileStore,
    board: Board?,
    lane: BoardLaneView,
    cards: Map<String, Card>,
    flags: Map<String, BoardCardFlags>,
    width: Float,
    drag: BoardCardDragState,
    selected: String,
    session: SessionSlice,
    onEdit: (Card) -> Unit,
) {
    val target =
        drag.targetLaneId == lane.lane_id && drag.card?.lane?.equals(lane.lane_id, true) == false
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier.width(width.dp)
            .fillMaxHeight()
            .onGloballyPositioned { drag.registerLane(lane.lane_id, it.boundsInRoot()) }
            .clip(shape)
            .then(
                if (target)
                    Modifier.background(tokens.tile).border(1.dp, tokens.action.copy(.5f), shape)
                else Modifier
            )
            .testTag("board-lane-${lane.lane_id}")
    ) {
        Row(
            Modifier.fillMaxWidth().height(30.dp).padding(start = 6.dp, end = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            StatusDot(lane.kind.tint(), size = 6.dp)
            Spacer(Modifier.width(7.dp))
            Text(
                lane.name,
                color = tokens.text,
                fontSize = 13.5.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                modifier =
                    Modifier.semantics {
                        contentDescription = "${lane.name}, ${lane.card_ids.size} cards"
                    },
            )
            Spacer(Modifier.width(6.dp))
            DesktopCount(lane.card_ids.size, label = lane.card_ids.size.toString())
            Spacer(Modifier.weight(1f))
            DesktopIconButton(
                Glyph.SORT,
                if (lane.descending) "Newest first" else "Oldest first",
                {
                    store.command(
                        Command(
                            set_lane_descending =
                                SetLaneDescending(
                                    board_id = board?.id.orEmpty(),
                                    lane_id = lane.lane_id,
                                    descending = !lane.descending,
                                )
                        )
                    )
                },
                Modifier.testTag("sort-${lane.lane_id}"),
                size = 22.dp,
            )
        }
        val dash = tokens.tertiary.copy(alpha = .45f)
        if (lane.card_ids.isEmpty())
            Box(
                Modifier.fillMaxWidth().height(72.dp).padding(top = 2.dp).drawBehind {
                    drawRoundRect(
                        dash,
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(10.dp.toPx()),
                        style =
                            Stroke(
                                1.dp.toPx(),
                                pathEffect =
                                    PathEffect.dashPathEffect(
                                        floatArrayOf(4.dp.toPx(), 4.dp.toPx())
                                    ),
                            ),
                    )
                },
                contentAlignment = Alignment.Center,
            ) {
                Text("Drop cards here", color = tokens.tertiary, fontSize = 11.5.sp)
            }
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(top = 2.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            items(lane.card_ids, key = { it }) { id ->
                val card = cards[id] ?: return@items
                DesktopCard(
                    store,
                    card,
                    board,
                    flags[id],
                    selected = selected == id,
                    machine =
                        if (session.machines.size > 1)
                            session.machines
                                .firstOrNull { it.id == card.owner_daemon_id }
                                ?.display_name
                                .orEmpty()
                        else "",
                    drag = drag,
                    onEdit = onEdit,
                )
            }
        }
    }
}

@Composable
private fun BoardLaneKind.tint(): Color =
    when (this) {
        BoardLaneKind.BOARD_LANE_KIND_RUNNING -> tokens.running
        BoardLaneKind.BOARD_LANE_KIND_REVIEW -> tokens.action
        BoardLaneKind.BOARD_LANE_KIND_DONE -> tokens.tertiary
        else -> tokens.subtle.copy(alpha = .7f)
    }

/**
 * A board card as on the Mac: status dot and title, the waiting callout, summary, agent and label
 * chips, then branch, diff and age. Click opens it at once (a double-click would delay every
 * click), right-click or "…" opens its menu, and a drag moves it to another lane.
 */
@Composable
internal fun DesktopCard(
    store: MobileStore,
    card: Card,
    board: Board?,
    flags: BoardCardFlags?,
    selected: Boolean,
    machine: String,
    drag: BoardCardDragState?,
    onEdit: (Card) -> Unit,
    dragging: Boolean = false,
) {
    val menu = rememberMenuState()
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    var bounds by remember { mutableStateOf(Rect.Zero) }
    val now = rememberNow()
    val tone =
        when (flags?.tone) {
            RuntimeTone.RUNTIME_TONE_ACTIVE -> tokens.running
            RuntimeTone.RUNTIME_TONE_ATTENTION -> tokens.attention
            RuntimeTone.RUNTIME_TONE_FAILED -> tokens.coral
            else -> null
        }
    val shape = RoundedCornerShape(DesktopMetrics.tileRadius)
    val labels = board?.labels.orEmpty().filter { it.id in card.label_ids }
    val sections = { cardMenuSections(store, card, onEdit = onEdit) }
    val runningLine = tokens.running
    MenuAnchor(menu) {
        Column(
            Modifier.fillMaxWidth()
                .onGloballyPositioned { bounds = it.boundsInRoot() }
                .then(
                    if (drag?.card?.id == card.id && !dragging)
                        Modifier.graphicsLayer { alpha = .35f }
                    else Modifier
                )
                .border(1.dp, if (selected) tokens.tileRimSelected else tokens.tileRim, shape)
                .hoverable(interaction)
                .then(
                    if (drag != null)
                        Modifier.cardDrag(card, drag, { bounds }) { drop ->
                            store.command(Command(move_card = MoveCard(drop.cardId, drop.laneId)))
                        }
                    else Modifier
                )
                .desktopClickable(
                    { store.openConversation(card.id) },
                    shape,
                    selected = selected,
                    rest = if (tokens.dark) tokens.tile else tokens.tile.copy(alpha = .9f),
                    onSecondary = { menu.show(sections()) },
                )
                .drawBehind {
                    if (flags?.tone == RuntimeTone.RUNTIME_TONE_ACTIVE)
                        drawLine(
                            runningLine,
                            Offset(10.dp.toPx(), size.height - 1.dp.toPx()),
                            Offset(size.width - 10.dp.toPx(), size.height - 1.dp.toPx()),
                            strokeWidth = 2.dp.toPx(),
                        )
                }
                .padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 9.dp)
                .testTag("card-${card.id}"),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(verticalAlignment = Alignment.Top) {
                if (tone != null) {
                    Box(Modifier.padding(top = 5.dp, end = 7.dp)) {
                        if (flags?.tone == RuntimeTone.RUNTIME_TONE_ACTIVE)
                            LiveDot(tone, size = 7.dp)
                        else StatusDot(tone)
                    }
                }
                Text(
                    Activity.title(card),
                    Modifier.weight(1f),
                    color = tokens.text,
                    fontSize = 13.sp,
                    lineHeight = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Box(
                    Modifier.size(width = 22.dp, height = 18.dp),
                    contentAlignment = Alignment.TopEnd,
                ) {
                    if (hovered && !dragging)
                        DesktopIconButton(
                            Glyph.MORE_HORIZONTAL,
                            "Card actions",
                            { menu.show(sections()) },
                            Modifier.testTag("card-menu-${card.id}"),
                            size = 20.dp,
                        )
                }
            }
            if (
                flags?.tone == RuntimeTone.RUNTIME_TONE_ATTENTION &&
                    flags.runtime_label.isNotEmpty()
            )
                Text(
                    flags.runtime_label,
                    Modifier.fillMaxWidth()
                        .background(tokens.attention.copy(.13f), RoundedCornerShape(8.dp))
                        .border(1.dp, tokens.attention.copy(.32f), RoundedCornerShape(8.dp))
                        .padding(horizontal = 8.dp, vertical = 5.dp),
                    color = tokens.attention,
                    fontSize = 11.5.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 2,
                )
            if (card.summary.isNotBlank())
                Text(
                    card.summary,
                    color = tokens.subtle,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                Chip(Cards.agent(card))
                labels.take(2).forEach { label ->
                    Text(
                        "#${label.name}",
                        color = labelColor(label.color),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                    )
                }
                if (labels.size > 2)
                    Text("+${labels.size - 2}", color = tokens.tertiary, fontSize = 11.sp)
                if (machine.isNotEmpty())
                    Text(machine, color = tokens.tertiary, fontSize = 11.sp, maxLines = 1)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                val badge = WorkspaceBadge.of(card)
                val runtime =
                    flags?.runtime_label.orEmpty().takeIf {
                        flags?.tone != RuntimeTone.RUNTIME_TONE_ATTENTION
                    }
                when {
                    badge != null -> {
                        Icon(
                            Glyph.BRANCH,
                            null,
                            tint = if (badge.conflicted) tokens.coral else tokens.tertiary,
                            size = 11.dp,
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            badge.title,
                            style = MonoSmall.copy(fontSize = 10.5.sp),
                            color = if (badge.conflicted) tokens.coral else tokens.subtle,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                    }
                    !runtime.isNullOrEmpty() ->
                        Text(
                            runtime,
                            color = tone ?: tokens.subtle,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                        )
                }
                card.workspace
                    ?.takeIf { it.additions + it.deletions > 0 }
                    ?.let { diff ->
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "+${diff.additions}",
                            style = MonoSmall.copy(fontSize = 10.5.sp),
                            color = tokens.running,
                        )
                        Spacer(Modifier.width(3.dp))
                        Text(
                            "−${diff.deletions}",
                            style = MonoSmall.copy(fontSize = 10.5.sp),
                            color = tokens.coral,
                        )
                    }
                card.active_subagents.size
                    .takeIf { it > 0 }
                    ?.let {
                        Spacer(Modifier.width(8.dp))
                        Text("$it agents", color = tokens.tertiary, fontSize = 10.5.sp)
                    }
                card.token_usage
                    ?.let(::TokenUsagePresentation)
                    ?.takeIf { it.reported }
                    ?.let {
                        Spacer(Modifier.width(8.dp))
                        Text(it.label(), color = tokens.tertiary, fontSize = 10.5.sp, maxLines = 1)
                    }
                Spacer(Modifier.weight(1f))
                if (flags?.can_start == true && !dragging)
                    DesktopCapsule(
                        if (flags.starting) "Starting…" else "Start",
                        { store.command(Command(start_card = StartCard(card.id))) },
                        Modifier.padding(end = 6.dp).testTag("start-${card.id}"),
                        glyph = Glyph.PLAY,
                        prominent = true,
                        enabled = !flags.starting,
                        height = 22.dp,
                    )
                Text(
                    CardAges.compact(card, now),
                    style = MonoSmall.copy(fontSize = 10.5.sp),
                    color = tokens.tertiary,
                )
            }
        }
    }
}

/**
 * Moves [card] between lanes: a mouse drags it at once, a finger after a long press, so touch still
 * scrolls the lane.
 */
private fun Modifier.cardDrag(
    card: Card,
    drag: BoardCardDragState,
    bounds: () -> Rect,
    onDrop: (com.getdieter.mobile.board.BoardCardLaneDrop) -> Unit,
): Modifier =
    pointerInput(card.id) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                if (down.type != PointerType.Mouse) return@awaitEachGesture
                var started = false
                var travelled = Offset.Zero
                while (true) {
                    val change =
                        awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) {
                        if (started) drag.finish()?.let(onDrop)
                        break
                    }
                    val delta = change.positionChange()
                    if (!started) {
                        travelled += delta
                        if (travelled.getDistance() > viewConfiguration.touchSlop) {
                            started = true
                            drag.start(card, bounds().topLeft + change.position)
                            change.consume()
                        }
                    } else {
                        drag.moveTo(drag.pointerInRoot + delta)
                        change.consume()
                    }
                }
            }
        }
        .pointerInput(card.id) {
            detectDragGesturesAfterLongPress(
                onDragStart = { point -> drag.start(card, bounds().topLeft + point) },
                onDrag = { change, amount ->
                    change.consume()
                    drag.moveTo(drag.pointerInRoot + amount)
                },
                onDragCancel = drag::reset,
                onDragEnd = { drag.finish()?.let(onDrop) },
            )
        }

/** The harness chip, e.g. "codex · gpt-5". */
@Composable
private fun Chip(text: String) {
    if (text.isEmpty()) return
    Text(
        text,
        Modifier.height(19.dp)
            .background(tokens.inset, RoundedCornerShape(5.dp))
            .border(1.dp, tokens.controlRim, RoundedCornerShape(5.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
        color = tokens.subtle,
        fontSize = 10.5.sp,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
    )
}
