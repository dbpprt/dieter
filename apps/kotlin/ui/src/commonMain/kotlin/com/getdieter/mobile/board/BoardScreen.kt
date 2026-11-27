@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.board

import androidx.compose.foundation.background
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
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.mobile.admin.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.launch

@Composable
internal fun BoardScreen(store: MobileStore, boardId: String) {
    val workspace by store.workspace.slice.collectAsState()
    val view by store.boards.slice.collectAsState()
    val selectedBoard by store.boards.selectedBoard.collectAsState()
    val target by store.boards.filter.collectAsState()
    val session by store.session.slice.collectAsState()
    val selectedCard by store.conversation.selectedCard.collectAsState()
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
                { store.boards.filterBoard(target.copy(query = it)) },
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
                                store.boards.filterBoard(
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
                            { store.boards.filterBoard(target.copy(machine_id = "")) },
                            glyph = Glyph.CLOSE,
                        )
                    if (labels.isNotEmpty())
                        FilterPill(
                            "All labels",
                            target.label_id.isEmpty(),
                            { store.boards.filterBoard(target.copy(label_id = "")) },
                        )
                    labels.forEach { label ->
                        FilterPill(
                            "${label.name} ${view.label_counts[label.id] ?: 0}",
                            target.label_id == label.id,
                            {
                                store.boards.filterBoard(
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
    val workspace = store.workspace.slice.value
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
                store.boards.filterBoard(target.copy(state = option.state))
            }
        }
    val machines =
        if (view.machine_ids.size > 1 || target.machine_id.isNotEmpty())
            listOf(
                ChromeAction("machine-all", "All machines", checked = target.machine_id.isEmpty()) {
                    store.boards.filterBoard(target.copy(machine_id = ""))
                }
            ) +
                view.machine_ids.map { id ->
                    ChromeAction(
                        "machine-$id",
                        session.machines.firstOrNull { it.id == id }?.display_name ?: id,
                        checked = target.machine_id == id,
                    ) {
                        store.boards.filterBoard(target.copy(machine_id = id))
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
