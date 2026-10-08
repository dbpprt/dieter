@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.ExperimentalFoundationApi::class,
)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.board.BoardCardState
import com.dbpprt.dieter.core.board.CardAges
import com.dbpprt.dieter.core.board.CardPolicy
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.presentation.TokenCounts
import com.dbpprt.dieter.core.presentation.TokenUsagePresentation
import com.dbpprt.dieter.core.workspace.WorkspaceBadge
import com.dbpprt.dieter.mobile.icons.*
import com.dbpprt.dieter.ui.BoardCardDragState
import kotlin.time.Clock

@Composable
internal fun BoardScreen(store: MobileStore) {
    val workspace by store.workspace.collectAsState()
    val view by store.board.collectAsState()
    val selected by store.selectedBoard.collectAsState()
    val target by store.boardFilter.collectAsState()
    val session by store.session.collectAsState()
    val board = workspace.boards.firstOrNull { it.id == selected }
    val project = workspace.projects.firstOrNull { it.id == board?.project_id }
    var lane by rememberSaveable(selected) { mutableStateOf("running") }
    var picker by remember { mutableStateOf(false) }
    var actions by remember { mutableStateOf<Card?>(null) }
    var actionMode by remember { mutableStateOf("") }
    var settings by remember { mutableStateOf(false) }
    var archived by remember { mutableStateOf(false) }
    val drag = remember(selected) { BoardCardDragState() }
    Column(Modifier.fillMaxSize()) {
        PageHeader(
            board?.name ?: "Board",
            "${project?.name.orEmpty()} · ${view.total} cards",
            back = { store.navigate(MobileTab.PROJECTS) },
        ) {
            IconButton(onClick = { archived = true }) {
                Icon(Icons.Outlined.Archive, "Archived cards")
            }
            IconButton(onClick = { settings = true }) {
                Icon(Icons.Outlined.Settings, "Board settings")
            }
            IconButton(onClick = { picker = true }) {
                Icon(Icons.Outlined.KeyboardArrowDown, "Switch board")
            }
            IconButton(onClick = { store.newConversation() }) {
                Icon(Icons.Outlined.Add, "New task")
            }
        }
        MobileTextField(
            target.query,
            { store.filterBoard(target.copy(query = it)) },
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            placeholder = { Text("Search cards") },
            leadingIcon = { Icon(Icons.Outlined.Search, null) },
            singleLine = true,
            shape = RoundedCornerShape(12.dp),
        )
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(
                target.label_id.isEmpty(),
                { store.filterBoard(target.copy(label_id = "")) },
                label = { Text("All cards · ${view.total}") },
            )
            board?.labels.orEmpty().forEach { label ->
                FilterChip(
                    target.label_id == label.id,
                    { store.filterBoard(target.copy(label_id = label.id)) },
                    label = { Text("${label.name} · ${view.label_counts[label.id] ?: 0}") },
                    leadingIcon = {
                        Box(Modifier.size(7.dp).background(labelColor(label.color), CircleShape))
                    },
                )
            }
            ChoiceChip(
                view.state_title.ifEmpty { "All states" },
                view.state_options.map { it.state.name to it.title },
            ) { key ->
                view.state_options
                    .firstOrNull { it.state.name == key }
                    ?.let { store.filterBoard(target.copy(state = it.state)) }
            }
            if (view.machine_ids.size > 1 || target.machine_id.isNotEmpty())
                ChoiceChip(
                    session.machines.firstOrNull { it.id == target.machine_id }?.display_name
                        ?: "All machines",
                    listOf("" to "All machines") +
                        view.machine_ids.map { id ->
                            id to (session.machines.firstOrNull { it.id == id }?.display_name ?: id)
                        },
                ) {
                    store.filterBoard(target.copy(machine_id = it))
                }
        }
        BoxWithConstraints(Modifier.weight(1f)) {
            val parallel = maxWidth >= 700.dp
            val visible = view.lanes.firstOrNull { it.lane_id == lane } ?: view.lanes.firstOrNull()
            Column {
                if (!parallel && view.lanes.isNotEmpty())
                    PrimaryScrollableTabRow(
                        selectedTabIndex = view.lanes.indexOf(visible).coerceAtLeast(0),
                        edgePadding = 12.dp,
                        containerColor = colors.background,
                    ) {
                        view.lanes.forEach { item ->
                            Tab(
                                item == visible,
                                { lane = item.lane_id },
                                modifier =
                                    Modifier.onGloballyPositioned {
                                        drag.registerLane(item.lane_id, it.boundsInRoot())
                                    },
                                text = {
                                    Text("${item.name}  ${item.card_ids.size}", fontSize = 13.sp)
                                },
                            )
                        }
                    }
                if (!workspace.loaded)
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                else if (parallel)
                    Row(
                        Modifier.horizontalScroll(rememberScrollState()).padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        view.lanes.forEach { item ->
                            Column(
                                Modifier.width(280.dp)
                                    .fillMaxHeight()
                                    .onGloballyPositioned {
                                        drag.registerLane(item.lane_id, it.boundsInRoot())
                                    }
                                    .background(
                                        if (drag.targetLaneId == item.lane_id)
                                            colors.primaryContainer
                                        else Color.Transparent,
                                        RoundedCornerShape(12.dp),
                                    )
                            ) {
                                LaneHeader(store, item, selected)
                                LaneCards(
                                    store,
                                    item,
                                    workspace.cards,
                                    board,
                                    drag,
                                    actions = { card, mode ->
                                        actions = card
                                        actionMode = mode
                                    },
                                )
                            }
                        }
                    }
                else if (visible == null || visible.card_ids.isEmpty())
                    Empty("No cards in this lane", "Create a card or change the filters.")
                else
                    Column {
                        LaneHeader(store, visible, selected)
                        LaneCards(
                            store,
                            visible,
                            workspace.cards,
                            board,
                            drag,
                            actions = { card, mode ->
                                actions = card
                                actionMode = mode
                            },
                        )
                    }
            }
        }
    }
    if (picker)
        ModalBottomSheet(onDismissRequest = { picker = false }) {
            Column(
                Modifier.fillMaxWidth().padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("Switch board", style = MaterialTheme.typography.titleLarge)
                workspace.boards.forEach { item ->
                    ListItem(
                        headlineContent = { Text(item.name) },
                        supportingContent = {
                            Text(
                                workspace.projects
                                    .firstOrNull { it.id == item.project_id }
                                    ?.name
                                    .orEmpty()
                            )
                        },
                        modifier =
                            Modifier.clickable {
                                store.chooseBoard(item.id)
                                picker = false
                            },
                    )
                }
            }
        }
    actions?.let {
        CardActions(store, it, initialMode = actionMode, onDismiss = { actions = null })
    }
    if (settings) BoardSettings(store) { settings = false }
    if (archived) ArchivedCards(store, selected) { archived = false }
}

@Composable
private fun LaneHeader(store: MobileStore, lane: BoardLaneView, boardId: String) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(lane.name, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
        Text(
            "${lane.card_ids.size}",
            style = MaterialTheme.typography.labelMedium,
            color = colors.onSurfaceVariant,
        )
        IconButton(
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
        ) {
            Icon(
                if (lane.descending) Icons.Outlined.ArrowDownward else Icons.Outlined.ArrowUpward,
                "Sort ${lane.name}",
                Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun LaneCards(
    store: MobileStore,
    lane: BoardLaneView,
    cards: List<Card>,
    board: Board?,
    drag: BoardCardDragState,
    actions: (Card, String) -> Unit,
) {
    val session by store.session.collectAsState()
    val selected by store.selectedCard.collectAsState()
    LazyColumn(
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxSize().testTag("board-lane-${lane.lane_id}"),
    ) {
        items(lane.card_ids, key = { it }) { id ->
            cards
                .firstOrNull { it.id == id }
                ?.let { card ->
                    SwipeWorkCard(
                        store,
                        card,
                        board,
                        selected == id,
                        session.machines.firstOrNull { it.id == card.owner_daemon_id }?.display_name
                            ?: "Unassigned",
                        drag,
                        { mode -> actions(card, mode) },
                    )
                }
        }
    }
}

/** Same 12 dp card, compact labels, age, machine/branch badges and footer as Android. */
@Composable
internal fun WorkCard(
    store: MobileStore,
    card: Card,
    board: Board?,
    selected: Boolean = false,
    machine: String,
    modifier: Modifier = Modifier,
    onActions: () -> Unit,
    onOpen: () -> Unit = { store.openCard(card.id) },
) {
    val outbox by store.outbox.collectAsState()
    val pending = card.id in outbox.pending_card_ids
    val state = BoardCardState.of(card, board, operation = null, pending = pending)
    val shape = RoundedCornerShape(12.dp)
    val age = CardAges.compact(card, Clock.System.now())
    val badge = WorkspaceBadge.of(card)
    Surface(
        shape = shape,
        color = if (selected) colors.primaryContainer else colors.surfaceContainerHigh,
        modifier =
            modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onOpen, onLongClick = onActions)
                .testTag("card-${card.id}"),
        border = if (selected) BorderStroke(1.dp, colors.primary) else null,
    ) {
        Column(
            Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            val labels = board?.labels.orEmpty().filter { it.id in card.label_ids }
            if (labels.isNotEmpty())
                FlowRow(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    labels.take(3).forEach { label -> LabelPill(label.name, label.color) }
                    if (labels.size > 3)
                        Text("+${labels.size - 3}", style = MaterialTheme.typography.labelSmall)
                }
            Row(verticalAlignment = Alignment.Top) {
                Text(
                    Activity.title(card),
                    Modifier.weight(1f),
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (age.isNotEmpty())
                    Text(
                        age,
                        fontSize = 11.sp,
                        color = colors.onSurfaceVariant,
                        modifier =
                            Modifier.padding(start = 10.dp, top = 2.dp).semantics {
                                contentDescription = "Last activity $age"
                            },
                    )
            }
            if (card.summary.isNotBlank())
                Text(
                    card.summary,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    color = colors.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                CompactBadge(machine, Icons.Outlined.Computer, "Machine $machine")
                badge?.let {
                    CompactBadge(
                        it.title,
                        Icons.Outlined.AccountTree,
                        it.accessibilityLabel,
                        danger = it.conflicted,
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        Cards.agent(card),
                        color = colors.onSurfaceVariant,
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    card.token_usage
                        ?.let(::TokenUsagePresentation)
                        ?.takeIf { it.reported }
                        ?.let { usage ->
                            Text(
                                usage.label(),
                                color = colors.onSurfaceVariant,
                                fontSize = 10.sp,
                                modifier =
                                    Modifier.semantics {
                                        contentDescription = TokenCounts.detail(usage.usage)
                                    },
                            )
                        }
                }
                if (state.canStart)
                    FilledTonalButton(
                        onClick = { store.command(Command(start_card = StartCard(card.id))) },
                        contentPadding = PaddingValues(horizontal = 12.dp),
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Icon(Icons.Outlined.PlayArrow, null, Modifier.size(16.dp))
                        Text("Start", fontSize = 12.sp)
                    }
                else
                    state.badge?.let {
                        Text(
                            it,
                            color = colors.secondary,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                IconButton(onClick = onActions, Modifier.size(36.dp)) {
                    Icon(Icons.Outlined.MoreHoriz, "Card actions", Modifier.size(18.dp))
                }
            }
        }
    }
}

@Composable
private fun SwipeWorkCard(
    store: MobileStore,
    card: Card,
    board: Board?,
    selected: Boolean,
    machine: String,
    drag: BoardCardDragState,
    actions: (String) -> Unit,
) {
    var offset by remember(card.id) { mutableFloatStateOf(0f) }
    var bounds by remember { mutableStateOf(Rect.Zero) }
    val reveal = with(LocalDensity.current) { 240.dp.toPx() }
    Box(Modifier.clip(RoundedCornerShape(12.dp)).background(colors.surface)) {
        Row(Modifier.matchParentSize(), horizontalArrangement = Arrangement.End) {
            listOf(
                    "Edit" to Icons.Outlined.Edit,
                    "Move" to Icons.Outlined.SwapHoriz,
                    "Archive" to Icons.Outlined.Archive,
                )
                .forEach { (label, icon) ->
                    Surface(
                        onClick = { actions(label + " card") },
                        modifier = Modifier.width(80.dp).fillMaxHeight(),
                        color = colors.primaryContainer,
                    ) {
                        Column(
                            Modifier.fillMaxHeight(),
                            verticalArrangement = Arrangement.Center,
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Icon(icon, null)
                            Text(label, style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
        }
        WorkCard(
            store,
            card,
            board,
            selected,
            machine,
            Modifier.onGloballyPositioned { bounds = it.boundsInRoot() }
                .pointerInput(card.id) {
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
                .offset { IntOffset(offset.toInt(), 0) }
                .draggable(
                    rememberDraggableState { offset = (offset + it).coerceIn(-reveal, 0f) },
                    Orientation.Horizontal,
                    onDragStopped = { offset = if (offset < -reveal / 2) -reveal else 0f },
                ),
            { actions("") },
        )
    }
}

@Composable
internal fun CompactBadge(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    accessibility: String = title,
    danger: Boolean = false,
) {
    val tint = if (danger) colors.error else colors.onSurfaceVariant
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = colors.surface,
        modifier = Modifier.widthIn(max = 180.dp).semantics { contentDescription = accessibility },
    ) {
        Row(
            Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, null, Modifier.size(13.dp), tint = tint)
            Text(
                title,
                fontSize = 11.sp,
                lineHeight = 14.sp,
                color = tint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
internal fun labelColor(value: String): Color = runCatching {
    Color(("FF" + value.removePrefix("#")).toLong(16))
}
    .getOrDefault(colors.primary)

@Composable
internal fun LabelPill(name: String, color: String) {
    val tint = labelColor(color)
    val contrast =
        (maxOf(tint.luminance(), colors.surfaceContainerHigh.luminance()) + .05f) /
            (minOf(tint.luminance(), colors.surfaceContainerHigh.luminance()) + .05f)
    val foreground = if (contrast >= 3) tint else colors.onSurface
    Row(
        Modifier.clip(RoundedCornerShape(5.dp))
            .background(tint.copy(alpha = .18f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).background(tint, CircleShape))
        Spacer(Modifier.width(5.dp))
        Text(name, color = foreground, fontSize = 11.sp, maxLines = 1)
    }
}

@Composable
internal fun ChoiceChip(
    title: String,
    options: List<Pair<String, String>>,
    enabled: Boolean = true,
    onSelect: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        if (LocalApplePresentation.current)
            TextButton(onClick = { open = true }, enabled = enabled) {
                Text(title)
                Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.size(16.dp))
            }
        else
            AssistChip(
                onClick = { open = true },
                enabled = enabled,
                label = { Text(title) },
                trailingIcon = {
                    Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.size(16.dp))
                },
            )
        DropdownMenu(open, { open = false }) {
            options.forEach { (key, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = {
                        onSelect(key)
                        open = false
                    },
                )
            }
        }
    }
}

@Composable
internal fun CardActions(
    store: MobileStore,
    card: Card,
    initialMode: String = "",
    onDismiss: () -> Unit,
) {
    val workspace by store.workspace.collectAsState()
    val current = workspace.cards.firstOrNull { it.id == card.id } ?: card
    val board = workspace.boards.firstOrNull { it.id == current.board_id }
    var mode by remember(card.id) { mutableStateOf(initialMode) }
    var title by remember(card.id) { mutableStateOf(card.title) }
    var prompt by remember(card.id) { mutableStateOf(card.initial_prompt) }
    val editable = CardPolicy.canEditDraft(card)
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                if (mode.isEmpty()) Activity.title(card) else mode,
                style = MaterialTheme.typography.titleLarge,
            )
            when (mode) {
                "Edit card" -> {
                    MobileTextField(
                        title,
                        { title = it },
                        label = { Text("Card title") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    MobileTextField(
                        prompt,
                        { prompt = it },
                        label = { Text("Agent task") },
                        readOnly = !editable,
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 4,
                    )
                    if (!editable)
                        Text(
                            "The task has already been sent to the agent.",
                            color = colors.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    Button(
                        onClick = {
                            store.command(
                                if (editable)
                                    Command(
                                        update_card_draft =
                                            UpdateCardDraft(
                                                card_id = card.id,
                                                title = title,
                                                prompt = prompt,
                                            )
                                    )
                                else Command(rename_card = RenameCard(card.id, title))
                            )
                            onDismiss()
                        },
                        enabled =
                            if (editable) CardPolicy.draftProblem(card, title, prompt, null) == null
                            else title.isNotBlank(),
                    ) {
                        Text("Save")
                    }
                }
                "Move card" ->
                    board?.lanes.orEmpty().forEach { lane ->
                        ListItem(
                            headlineContent = { Text(lane.name) },
                            trailingContent = { if (lane.id == card.lane) Text("Current") },
                            modifier =
                                Modifier.clickable(enabled = lane.id != card.lane) {
                                    store.command(Command(move_card = MoveCard(card.id, lane.id)))
                                    onDismiss()
                                },
                        )
                    }
                "Labels" ->
                    board?.labels.orEmpty().forEach { label ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                store.command(
                                    Command(
                                        set_card_labels =
                                            SetCardLabels(
                                                card.id,
                                                if (label.id in current.label_ids)
                                                    current.label_ids - label.id
                                                else current.label_ids + label.id,
                                            )
                                    )
                                )
                            },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(label.id in current.label_ids, null)
                            LabelPill(label.name, label.color)
                        }
                    }
                "Archive card" -> {
                    Text("Archive this conversation? You can restore it from the archive.")
                    Button(
                        onClick = {
                            store.command(Command(archive_card = ArchiveCard(card.id)))
                            if (store.selectedCard.value == card.id) store.back()
                            onDismiss()
                        }
                    ) {
                        Text("Archive")
                    }
                }
                else -> {
                    listOf("Edit card", "Move card", "Labels", "Archive card")
                        .filter { card.scope != "chat" || it !in listOf("Move card", "Labels") }
                        .forEach { label ->
                            TextButton(
                                onClick = { mode = label },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(label)
                            }
                        }
                    if (card.scope == "chat")
                        TextButton(
                            onClick = {
                                store.command(
                                    Command(set_card_pinned = SetCardPinned(card.id, !card.pinned))
                                )
                                onDismiss()
                            }
                        ) {
                            Text(if (card.pinned) "Unpin" else "Pin")
                        }
                    TextButton(
                        onClick = {
                            store.action {
                                val fork =
                                    store.core.dispatch(Command(fork_card = ForkCard(card.id))).card
                                        ?: return@action
                                store.openCard(fork.id)
                                onDismiss()
                            }
                        }
                    ) {
                        Text("Fork conversation")
                    }
                }
            }
        }
    }
}
