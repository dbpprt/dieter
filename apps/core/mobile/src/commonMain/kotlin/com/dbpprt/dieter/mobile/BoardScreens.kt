@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.board.CardAges
import com.dbpprt.dieter.core.board.CardPolicy
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.presentation.TokenCounts
import com.dbpprt.dieter.core.presentation.TokenUsagePresentation
import com.dbpprt.dieter.core.workspace.WorkspaceBadge
import com.dbpprt.dieter.ui.BoardCardDragState
import kotlin.time.Clock
import kotlinx.coroutines.launch

@Composable
internal fun BoardScreen(store: MobileStore, boardId: String) {
    val workspace by store.workspace.collectAsState()
    val view by store.board.collectAsState()
    val selectedBoard by store.selectedBoard.collectAsState()
    val target by store.boardFilter.collectAsState()
    val session by store.session.collectAsState()
    val selectedCard by store.selectedCard.collectAsState()
    val board = workspace.boards.firstOrNull { it.id == boardId }
    val project = workspace.projects.firstOrNull { it.id == board?.project_id }
    var settings by remember { mutableStateOf(false) }
    var archived by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<Card?>(null) }
    val ready = selectedBoard == boardId && workspace.loaded
    val lanes = if (ready) view.lanes else emptyList()
    val chrome =
        ScreenChrome(
            board?.name ?: "Board",
            subtitle =
                listOfNotNull(project?.name, if (ready) "${view.total} cards" else null)
                    .joinToString(" · "),
            actions =
                listOf(
                    boardMenu(store, board, view, target, session) { action ->
                        when (action) {
                            "settings" -> settings = true
                            "archived" -> archived = true
                        }
                    }
                ),
            primary = newTaskAction(store),
        )
    Screen(chrome) {
        Column(Modifier.fillMaxSize().padding(top = padding.calculateTopPadding())) {
            SearchField(
                target.query,
                { store.filterBoard(target.copy(query = it)) },
                "Search cards",
                Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                testTag = "board-search",
            )
            val labels = board?.labels.orEmpty()
            val stateActive = target.state != BoardStateFilter.BOARD_STATE_FILTER_ALL
            if (labels.isNotEmpty() || stateActive || target.machine_id.isNotEmpty())
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = ScreenMargin, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (stateActive)
                        FilterPill(
                            view.state_title,
                            true,
                            {
                                store.filterBoard(
                                    target.copy(state = BoardStateFilter.BOARD_STATE_FILTER_ALL)
                                )
                            },
                            glyph = Glyph.CLOSE,
                        )
                    if (target.machine_id.isNotEmpty())
                        FilterPill(
                            session.machines
                                .firstOrNull { it.id == target.machine_id }
                                ?.display_name ?: "Machine",
                            true,
                            { store.filterBoard(target.copy(machine_id = "")) },
                            glyph = Glyph.CLOSE,
                        )
                    if (labels.isNotEmpty())
                        FilterPill(
                            "All labels",
                            target.label_id.isEmpty(),
                            { store.filterBoard(target.copy(label_id = "")) },
                        )
                    labels.forEach { label ->
                        FilterPill(
                            "${label.name} ${view.label_counts[label.id] ?: 0}",
                            target.label_id == label.id,
                            {
                                store.filterBoard(
                                    target.copy(
                                        label_id = if (target.label_id == label.id) "" else label.id
                                    )
                                )
                            },
                            Modifier.testTag("label-filter-${label.id}"),
                            dot = labelColor(label.color),
                        )
                    }
                }
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    !ready ->
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Spinner(Modifier.size(28.dp))
                        }
                    lanes.isEmpty() ->
                        EmptyState(Glyph.BOARD, "No lanes", "This board has no lanes to show.")
                    maxWidth >= 700.dp ->
                        ParallelLanes(
                            store,
                            lanes,
                            workspace.cards,
                            board,
                            selectedCard,
                            session,
                            padding.calculateBottomPadding(),
                        ) {
                            editing = it
                        }
                    else ->
                        PagedLanes(
                            store,
                            boardId,
                            lanes,
                            workspace.cards,
                            board,
                            selectedCard,
                            session,
                            padding.calculateBottomPadding(),
                        ) {
                            editing = it
                        }
                }
            }
        }
    }
    if (settings) BoardSettings(store, boardId) { settings = false }
    if (archived) ArchivedCards(store, boardId) { archived = false }
    editing?.let { card -> CardEditSheet(store, card) { editing = null } }
}

private fun boardMenu(
    store: MobileStore,
    board: Board?,
    view: BoardViewSlice,
    target: BoardViewTarget,
    session: SessionSlice,
    open: (String) -> Unit,
): ChromeAction {
    val workspace = store.workspace.value
    val switch =
        workspace.projects.mapNotNull { project ->
            val boards = workspace.boards.filter { it.project_id == project.id }
            if (boards.isEmpty()) null
            else
                MenuSection(
                    boards.map { item ->
                        ChromeAction(
                            "switch-${item.id}",
                            item.name,
                            checked = item.id == board?.id,
                        ) {
                            store.replaceTop(MobileRoute.Board(item.id))
                        }
                    },
                    title = project.name,
                )
        }
    val states =
        view.state_options.map { option ->
            ChromeAction(
                "state-${option.state.name}",
                option.title,
                checked = option.state == target.state,
            ) {
                store.filterBoard(target.copy(state = option.state))
            }
        }
    val machines =
        if (view.machine_ids.size > 1 || target.machine_id.isNotEmpty())
            listOf(
                ChromeAction("machine-all", "All machines", checked = target.machine_id.isEmpty()) {
                    store.filterBoard(target.copy(machine_id = ""))
                }
            ) +
                view.machine_ids.map { id ->
                    ChromeAction(
                        "machine-$id",
                        session.machines.firstOrNull { it.id == id }?.display_name ?: id,
                        checked = target.machine_id == id,
                    ) {
                        store.filterBoard(target.copy(machine_id = id))
                    }
                }
        else emptyList()
    return ChromeAction(
        "board-menu",
        "Board options",
        Glyph.MORE_HORIZONTAL,
        menu =
            listOfNotNull(
                MenuSection(
                    listOf(
                        ChromeAction("board-switch", "Switch board", Glyph.BOARD, menu = switch),
                        ChromeAction(
                            "board-state",
                            "Show",
                            Glyph.FILTER,
                            menu = listOf(MenuSection(states)),
                        ),
                    ) +
                        if (machines.isNotEmpty())
                            listOf(
                                ChromeAction(
                                    "board-machines",
                                    "Machine",
                                    Glyph.MACHINE,
                                    menu = listOf(MenuSection(machines)),
                                )
                            )
                        else emptyList()
                ),
                MenuSection(
                    listOf(
                        ChromeAction("board-archived", "Archived cards", Glyph.ARCHIVE) {
                            open("archived")
                        },
                        ChromeAction("board-settings", "Board settings", Glyph.SETTINGS) {
                            open("settings")
                        },
                    )
                ),
            ),
    )
}

@Composable
private fun PagedLanes(
    store: MobileStore,
    boardId: String,
    lanes: List<BoardLaneView>,
    cards: List<Card>,
    board: Board?,
    selected: String,
    session: SessionSlice,
    bottom: androidx.compose.ui.unit.Dp,
    edit: (Card) -> Unit,
) {
    val initial = lanes.indexOfFirst { it.lane_id == "running" }.coerceAtLeast(0)
    val pager = rememberPagerState(initialPage = initial) { lanes.size }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize()) {
        if (apple) {
            if (lanes.size <= 4)
                Segmented(
                    lanes.map {
                        if (it.card_ids.isEmpty()) it.name else "${it.name} ${it.card_ids.size}"
                    },
                    pager.currentPage.coerceIn(0, lanes.size - 1),
                    { scope.launch { pager.animateScrollToPage(it) } },
                    Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                    testTagPrefix = "lane",
                )
            else
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = ScreenMargin, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    lanes.forEachIndexed { index, lane ->
                        FilterPill(
                            if (lane.card_ids.isEmpty()) lane.name
                            else "${lane.name} ${lane.card_ids.size}",
                            index == pager.currentPage,
                            { scope.launch { pager.animateScrollToPage(index) } },
                            Modifier.testTag("lane-$index"),
                        )
                    }
                }
        } else {
            val tabs: @Composable () -> Unit = {
                lanes.forEachIndexed { index, lane ->
                    Tab(
                        selected = index == pager.currentPage,
                        onClick = { scope.launch { pager.animateScrollToPage(index) } },
                        modifier = Modifier.testTag("lane-$index"),
                        text = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(lane.name, maxLines = 1)
                                if (lane.card_ids.isNotEmpty()) {
                                    Spacer(Modifier.width(6.dp))
                                    Badge(
                                        containerColor =
                                            if (index == pager.currentPage) colors.primary
                                            else colors.surfaceContainerHighest,
                                        contentColor =
                                            if (index == pager.currentPage) colors.onPrimary
                                            else colors.onSurfaceVariant,
                                    ) {
                                        Text("${lane.card_ids.size}")
                                    }
                                }
                            }
                        },
                    )
                }
            }
            // Fixed tabs only while every lane name and count fit; narrow panes scroll instead.
            val measurer = rememberTextMeasurer()
            val tabStyle = MaterialTheme.typography.titleSmall
            val density = LocalDensity.current
            val widest =
                remember(lanes.map { it.name }, tabStyle, density) {
                    with(density) {
                        lanes.maxOfOrNull { measurer.measure(it.name, tabStyle).size.width.toDp() }
                            ?: 0.dp
                    }
                }
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                // Name, badge and the tab's own 16 dp side padding.
                if (lanes.size <= 4 && widest + 56.dp <= maxWidth / lanes.size)
                    PrimaryTabRow(
                        pager.currentPage.coerceIn(0, lanes.size - 1),
                        containerColor = palette.background,
                    ) {
                        tabs()
                    }
                else
                    PrimaryScrollableTabRow(
                        pager.currentPage.coerceIn(0, lanes.size - 1),
                        containerColor = palette.background,
                        edgePadding = 12.dp,
                    ) {
                        tabs()
                    }
            }
        }
        HorizontalPager(
            pager,
            Modifier.weight(1f).fillMaxWidth(),
            key = { lanes.getOrNull(it)?.lane_id ?: it },
            beyondViewportPageCount = 1,
        ) { page ->
            val lane = lanes[page]
            LaneList(store, boardId, lane, cards, board, selected, session, bottom, null, edit)
        }
    }
}

@Composable
private fun LaneList(
    store: MobileStore,
    boardId: String,
    lane: BoardLaneView,
    cards: List<Card>,
    board: Board?,
    selected: String,
    session: SessionSlice,
    bottom: androidx.compose.ui.unit.Dp,
    drag: BoardCardDragState?,
    edit: (Card) -> Unit,
) {
    LazyColumn(
        Modifier.fillMaxSize().testTag("board-lane-${lane.lane_id}"),
        contentPadding =
            PaddingValues(
                start = ScreenMargin,
                end = ScreenMargin,
                top = 4.dp,
                bottom = bottom + 16.dp,
            ),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item("lane-header") {
            Row(
                Modifier.fillMaxWidth().padding(start = 4.dp, top = 2.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "${lane.card_ids.size} ${if (lane.card_ids.size == 1) "card" else "cards"}",
                    Modifier.weight(1f).semantics {
                        contentDescription = "${lane.name}, ${lane.card_ids.size} cards"
                    },
                    style = type.footnote.copy(fontWeight = FontWeight.Medium),
                    color = palette.secondaryLabel,
                )
                Row(
                    Modifier.clip(CircleShape)
                        .pressable(
                            onClick = {
                                store.command(
                                    Command(
                                        set_lane_descending =
                                            SetLaneDescending(
                                                board_id = boardId,
                                                lane_id = lane.lane_id,
                                                descending = !lane.descending,
                                            )
                                    )
                                )
                            }
                        )
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                        .testTag("sort-${lane.lane_id}"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Glyph.SORT, null, tint = palette.secondaryLabel, size = 14.dp)
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (lane.descending) "Newest first" else "Oldest first",
                        style = type.footnote,
                        color = palette.secondaryLabel,
                    )
                }
            }
        }
        if (lane.card_ids.isEmpty())
            item("empty") {
                EmptyState(
                    Glyph.BOARD,
                    "No ${lane.name.lowercase()} cards",
                    "Cards you move here appear in this lane.",
                    Modifier.padding(top = 24.dp),
                )
            }
        items(lane.card_ids, key = { it }) { id ->
            val card = cards.firstOrNull { it.id == id } ?: return@items
            WorkCard(
                store,
                card,
                board,
                selected = selected == id,
                machine =
                    session.machines.firstOrNull { it.id == card.owner_daemon_id }?.display_name
                        ?: "Unassigned",
                drag = drag,
                onEdit = edit,
            )
        }
    }
}

@Composable
private fun ParallelLanes(
    store: MobileStore,
    lanes: List<BoardLaneView>,
    cards: List<Card>,
    board: Board?,
    selected: String,
    session: SessionSlice,
    bottom: androidx.compose.ui.unit.Dp,
    edit: (Card) -> Unit,
) {
    val drag = remember(board?.id) { BoardCardDragState() }
    Row(
        Modifier.fillMaxSize()
            .horizontalScroll(rememberScrollState())
            .padding(start = ScreenMargin, top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        lanes.forEach { lane ->
            val target = drag.targetLaneId == lane.lane_id
            Column(
                Modifier.width(300.dp)
                    .fillMaxHeight()
                    .onGloballyPositioned { drag.registerLane(lane.lane_id, it.boundsInRoot()) }
                    .clip(RoundedCornerShape(if (apple) 26.dp else 24.dp))
                    .background(
                        if (target) palette.accentContainer
                        else palette.fill.copy(alpha = palette.fill.alpha * .6f)
                    )
            ) {
                Row(
                    Modifier.fillMaxWidth()
                        .padding(start = 18.dp, end = 12.dp, top = 14.dp, bottom = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        lane.name,
                        Modifier.weight(1f),
                        style = type.headline,
                        color = palette.label,
                    )
                    Text(
                        "${lane.card_ids.size}",
                        style = type.subheadline,
                        color = palette.secondaryLabel,
                    )
                }
                LaneList(
                    store,
                    board?.id.orEmpty(),
                    lane,
                    cards,
                    board,
                    selected,
                    session,
                    bottom,
                    drag,
                    edit,
                )
            }
        }
        Spacer(Modifier.width(2.dp))
    }
}

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
    val outbox by store.outbox.collectAsState()
    val view by store.board.collectAsState()
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
                    if (store.session.value.machines.size > 1)
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
