@file:OptIn(
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package com.getdieter.mobile.workspace

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxDefaults
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.activity.Activity
import com.getdieter.core.activity.InboxSection
import com.getdieter.core.activity.InboxStatus
import com.getdieter.mobile.app.*
import com.getdieter.mobile.board.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The Inbox as a dense chat list in the core's sections: what needs the user, running work, idle
 * pins, then the rest. Each row is two lines; rows swipe right for their quick action (read, done
 * or pin) and left to archive or, while the agent works, to stop it.
 */
@Composable
internal fun InboxScreen(store: MobileStore) {
    val view by store.workspace.activity.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val refreshing by store.session.refreshing.collectAsState()
    val session by store.session.slice.collectAsState()
    val selected by store.conversation.selectedCard.collectAsState()
    val search = rememberListSearch("inbox", "Search activity")
    val query = search.query
    var project by rememberSaveable { mutableStateOf("") }
    var status by rememberSaveable { mutableStateOf(InboxStatus.ALL) }
    var timeline by rememberSaveable { mutableStateOf(false) }
    var rulesOpen by rememberSaveable { mutableStateOf(false) }
    var stopping by remember { mutableStateOf<Card?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val now = rememberNow()
    val scoped =
        view.rows.filter { row ->
            row.card != null &&
                (project.isEmpty() || row.card?.project_id == project) &&
                Activity.matches(query, row.title, row.project_name, row.board_name)
        }
    val rows = scoped.filter(status::matches)
    val counts = InboxStatus.counts(scoped)
    val projectName = workspace.projects.firstOrNull { it.id == project }?.name
    val hidden = view.summary?.hidden ?: 0
    val machines =
        session.machines
            .takeIf { it.size > 1 }
            .orEmpty()
            .associate {
                it.id to it.display_name
            }

    fun offerUndo(message: String, undo: () -> Unit) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            val result =
                snackbar.showSnackbar(
                    message,
                    actionLabel = "Undo",
                    duration = SnackbarDuration.Long,
                )
            if (result == SnackbarResult.ActionPerformed) undo()
        }
    }

    fun perform(action: SwipeAction, row: ActivityRow) {
        val card = row.card ?: return
        when (action) {
            SwipeAction.READ -> store.command(Command(mark_card_read = MarkCardRead(card.id)))
            SwipeAction.DONE -> {
                store.command(Command(finish_card = FinishCard(card.id)))
                offerUndo("Marked “${row.title}” done") {
                    store.command(Command(move_card = MoveCard(card.id, card.lane)))
                }
            }
            SwipeAction.PIN,
            SwipeAction.UNPIN -> store.pinInbox(row)
            SwipeAction.ARCHIVE -> {
                store.command(Command(archive_card = ArchiveCard(card.id)))
                if (selected == card.id) store.pop()
                offerUndo("Archived “${row.title}”") {
                    store.command(Command(restore_card = RestoreCard(card.id, card.board_id)))
                }
            }
            SwipeAction.STOP -> stopping = card
        }
    }

    val filtered = status != InboxStatus.ALL || projectName != null
    val chrome =
        ScreenChrome(
            "Inbox",
            subtitle =
                when {
                    filtered ->
                        listOfNotNull(
                                projectName,
                                status.title.takeIf { status != InboxStatus.ALL },
                                "${rows.size}",
                            )
                            .joinToString(" · ")
                    workspace.loaded -> view.summary?.headline.orEmpty()
                    else -> ""
                },
            // Keep the title beside the toolbar controls and the inbox content near the top.
            large = false,
            actions =
                listOf(
                    search.action(),
                    ChromeAction(
                        "inbox-filter",
                        "Filter",
                        Glyph.FILTER,
                        checked = filtered,
                        menu =
                            listOf(
                                MenuSection(
                                    InboxStatus.entries.map { value ->
                                        ChromeAction(
                                            "inbox-status-${value.name.lowercase()}",
                                            value.title,
                                            checked = value == status,
                                            value = "${counts[value] ?: 0}",
                                        ) {
                                            status = value
                                        }
                                    },
                                    title = "Show",
                                ),
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "project-all",
                                            "All projects",
                                            checked = project.isEmpty(),
                                        ) {
                                            project = ""
                                        }
                                    ) +
                                        workspace.projects.map { item ->
                                            ChromeAction(
                                                "project-${item.id}",
                                                item.name,
                                                checked = item.id == project,
                                            ) {
                                                project = item.id
                                            }
                                        },
                                    title = "Project",
                                ),
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "inbox-rules",
                                            "Inbox rules…",
                                            Glyph.FILTER,
                                            value = if (hidden > 0) "$hidden hidden" else "",
                                        ) {
                                            rulesOpen = true
                                        },
                                        ChromeAction(
                                            "timeline",
                                            "Activity timeline",
                                            Glyph.TIMELINE,
                                            checked = timeline,
                                        ) {
                                            timeline = !timeline
                                        },
                                    )
                                ),
                            ),
                    ),
                ),
            primary = newTaskAction(store),
        )
    Screen(chrome) {
        Box(Modifier.fillMaxSize()) {
            RefreshableList(
                refreshing = refreshing,
                onRefresh = store.session::refresh,
                tag = "inbox-refresh",
                topInset = padding.calculateTopPadding(),
            ) {
                LazyColumn(
                    Modifier.fillMaxSize().testTag("activity-feed"),
                    state = listState,
                    contentPadding = padding,
                ) {
                    titleHeader()
                    item("notice") { ConnectionNotice(store) }
                    if (search.shown) item("search") { search.Field() }
                    if (timeline && rows.isNotEmpty())
                        item("timeline") {
                            ActivityTimeline(rows, now) { store.openConversation(it) }
                        }
                    if (rows.isEmpty())
                        item("empty") {
                            EmptyState(
                                if (query.isNotBlank()) Glyph.SEARCH else Glyph.INBOX,
                                when {
                                    !workspace.loaded -> "Loading activity…"
                                    query.isNotBlank() -> "No results"
                                    filtered -> "Nothing here"
                                    else -> "All quiet"
                                },
                                when {
                                    query.isNotBlank() -> "No conversations match “$query”."
                                    status == InboxStatus.NEEDS_YOU ->
                                        "Nothing needs you right now."
                                    else -> "Running work, replies and reviews appear here."
                                },
                                Modifier.padding(top = 24.dp),
                            )
                        }
                    InboxSection.group(rows).forEach { (section, sectionRows) ->
                        item("header-$section") {
                            ListSectionHeader(
                                section.title,
                                Modifier.testTag("inbox-section-${section.name.lowercase()}"),
                                count = sectionRows.size,
                                tint =
                                    when (section) {
                                        InboxSection.NEEDS_YOU ->
                                            palette.warning.readableOn(palette.background)
                                        InboxSection.RUNNING ->
                                            palette.info.readableOn(palette.background)
                                        InboxSection.PINNED,
                                        InboxSection.RECENT -> palette.secondaryLabel
                                    },
                            )
                        }
                        itemsIndexed(sectionRows, key = { _, row -> "row-" + row.card!!.id }) {
                            index,
                            row ->
                            InboxRow(
                                store,
                                row,
                                now,
                                first = index == 0,
                                wave = index,
                                selected = row.card!!.id == selected,
                                showPin = section != InboxSection.PINNED,
                                machine = machines[row.card?.owner_daemon_id],
                                onSwipe = ::perform,
                            )
                        }
                    }
                    if (hidden > 0)
                        item("hidden") {
                            HiddenByRules(hidden, Modifier.testTag("inbox-hidden")) {
                                rulesOpen = true
                            }
                        }
                }
            }
            SnackbarHost(
                snackbar,
                Modifier.align(Alignment.BottomCenter)
                    .padding(bottom = padding.calculateBottomPadding())
                    .testTag("inbox-snackbar"),
            )
        }
    }
    if (rulesOpen) InboxRulesSheet(store) { rulesOpen = false }
    stopping?.let { card ->
        ConfirmDialog(
            "Stop the agent?",
            "“${Activity.title(card)}” stops after its current step. You can send it a new message later.",
            "Stop",
            {
                stopping = null
                store.command(Command(cancel_card = CancelCard(card.id)))
            },
            { stopping = null },
            destructive = true,
        )
    }
}

/** White or black, whichever reads on [background]. */
private fun contentOn(background: Color) =
    if (background.luminance() > .5f) Color.Black else Color.White

// ---------------------------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------------------------

/** The quiet last row: how many conversations the Inbox rules hide; opens the rules. */
@Composable
private fun HiddenByRules(count: Int, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .padding(start = 10.dp, top = 12.dp, bottom = 8.dp)
            .clip(CircleShape)
            .pressable(onClick = onClick, highlight = true)
            .padding(horizontal = 6.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Glyph.EYE_SLASH, null, tint = palette.secondaryLabel, size = 15.dp)
        Text(
            "$count hidden by Inbox rules",
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = palette.secondaryLabel,
        )
        Icon(
            Glyph.CHEVRON_RIGHT,
            null,
            tint = palette.tertiaryLabel,
            size = 11.dp,
            weight = GlyphWeight.SEMIBOLD,
        )
    }
}

// ---------------------------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------------------------

private enum class SwipeAction(val title: String, val glyph: Glyph) {
    READ("Read", Glyph.MAIL_OPEN),
    DONE("Done", Glyph.TASK_DONE),
    PIN("Pin", Glyph.PIN),
    UNPIN("Unpin", Glyph.PIN),
    ARCHIVE("Archive", Glyph.ARCHIVE),
    STOP("Stop", Glyph.STOP),
}

private val SwipeAction.color: Color
    @Composable
    get() =
        when (this) {
            SwipeAction.READ -> palette.info
            SwipeAction.DONE -> palette.success
            SwipeAction.PIN,
            SwipeAction.UNPIN -> palette.warning
            SwipeAction.ARCHIVE -> palette.purple
            SwipeAction.STOP -> palette.destructive
        }

/** Swiping right: read an unread reply, finish a reviewed or failed card, or pin. */
private val ActivityRow.leadingAction: SwipeAction
    get() =
        when {
            kind == "UNREAD" -> SwipeAction.READ
            can_finish -> SwipeAction.DONE
            pinned -> SwipeAction.UNPIN
            else -> SwipeAction.PIN
        }

/** Swiping left: archive, or stop a working agent (a running card cannot be archived). */
private val ActivityRow.trailingAction: SwipeAction
    get() = if (kind == "RUNNING") SwipeAction.STOP else SwipeAction.ARCHIVE

/** The long-press menu: the Inbox's own actions under where the row comes from, then the card's. */
private fun inboxMenu(
    store: MobileStore,
    row: ActivityRow,
    machine: String?,
    perform: (SwipeAction) -> Unit,
): List<MenuSection> {
    val card = row.card ?: return emptyList()
    val sections = cardMenuSections(store, card, row.can_finish)
    val inbox =
        MenuSection(
            listOfNotNull(
                if (row.stale.isNotEmpty())
                    ChromeAction(
                        "inbox-stale-${card.id}",
                        row.stale,
                        Glyph.OFFLINE,
                        enabled = false,
                    )
                else null,
                ChromeAction(
                    "inbox-pin-${card.id}",
                    if (row.pinned) "Unpin from Inbox" else "Pin in Inbox",
                    Glyph.PIN,
                ) {
                    perform(if (row.pinned) SwipeAction.UNPIN else SwipeAction.PIN)
                },
                if (row.kind == "UNREAD")
                    ChromeAction("inbox-read-${card.id}", "Mark read", Glyph.MAIL_OPEN) {
                        perform(SwipeAction.READ)
                    }
                else null,
                if (row.kind == "RUNNING")
                    ChromeAction(
                        "inbox-stop-${card.id}",
                        "Stop agent",
                        Glyph.STOP,
                        destructive = true,
                    ) {
                        perform(SwipeAction.STOP)
                    }
                else null,
            ),
            title = listOfNotNull(row.project_name.ifEmpty { null }, machine).joinToString(" · "),
        )
    return sections.take(1) + inbox + sections.drop(1)
}

@Composable
private fun InboxRow(
    store: MobileStore,
    row: ActivityRow,
    now: Instant,
    first: Boolean,
    wave: Int,
    selected: Boolean,
    showPin: Boolean,
    machine: String?,
    onSwipe: (SwipeAction, ActivityRow) -> Unit,
) {
    val card = row.card ?: return
    val menu = rememberMenuState()
    MenuAnchor(menu, atPress = true) {
        SwipeRow(row, Modifier.testTag("activity-row-${card.id}"), onSwipe = { onSwipe(it, row) }) {
            InboxRowContent(
                row,
                now,
                first,
                wave,
                selected,
                showPin,
                machine,
                onOpen = { store.openConversation(card.id) },
                onMenu = { menu.show(inboxMenu(store, row, machine) { onSwipe(it, row) }) },
            )
        }
    }
}

/**
 * Two lines beside the project avatar: the title and its time, then `project:` and what the agent
 * does or said last, with one status badge. A working agent rings its avatar. While its machine is
 * being asked for its current state ([ActivityRow.refreshing]) a mark spins by the time and light
 * sweeps over the second line, travelling down the list from row [wave].
 */
@Composable
private fun InboxRowContent(
    row: ActivityRow,
    now: Instant,
    first: Boolean,
    wave: Int,
    selected: Boolean,
    showPin: Boolean,
    machine: String?,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
) {
    val card = row.card ?: return
    val running = row.kind == "RUNNING"
    val surface = listRowSurface(selected, tinted = row.pinned)
    val accent = row.accent(surface)
    // An unfiled chat has no project, so its machine says where it runs.
    val source = row.project_name.ifEmpty { machine.orEmpty() }
    val label = palette.label
    val secondary = palette.secondaryLabel
    val preview = buildAnnotatedString {
        if (source.isNotEmpty())
            withStyle(SpanStyle(color = label, fontWeight = FontWeight.Medium)) {
                append("$source: ")
            }
        append(row.preview.ifEmpty { row.detail })
        if (running && row.agents.isNotEmpty())
            withStyle(SpanStyle(color = secondary)) { append(" · ${row.agents}") }
    }
    ListRow(
        onClick = onOpen,
        modifier = if (row.pinned) Modifier.testTag("inbox-pinned-${card.id}") else Modifier,
        onLongClick = onMenu,
        surface = surface,
        first = first,
        leading = { InboxAvatar(row) },
        meta = {
            if (row.stale.isNotEmpty())
                Icon(
                    Glyph.OFFLINE,
                    row.stale,
                    Modifier.padding(start = 6.dp),
                    tint = palette.warning.readableOn(surface),
                    size = 13.dp,
                )
            if (row.refreshing)
                RefreshingMark(
                    palette.info.readableOn(surface),
                    Modifier.padding(start = 6.dp).testTag("inbox-refreshing-${card.id}"),
                )
            ListMeta(
                row.age(now),
                color =
                    when {
                        row.refreshing -> palette.tertiaryLabel
                        running || row.needs_you -> accent
                        else -> palette.secondaryLabel
                    },
            )
        },
        subtitle = {
            val emphasized = running || row.kind == "FAILED"
            ListSubtitle(
                preview,
                Modifier.refreshShimmer(
                    row.refreshing,
                    if (emphasized) palette.label else palette.info.readableOn(surface),
                    wave,
                ),
                color =
                    when {
                        emphasized -> accent
                        row.needs_you -> palette.label
                        else -> palette.secondaryLabel
                    },
            )
        },
        badge = { InboxBadge(row, showPin, surface, ListBadgeGap) },
    ) {
        if (row.chat)
            Icon(
                Glyph.CHAT,
                "Chat",
                Modifier.padding(end = 4.dp),
                tint = palette.secondaryLabel,
                size = 13.dp,
            )
        ListTitle(row.title)
    }
}

/** The colour that says what a row waits for, readable on [surface]. */
@Composable
private fun ActivityRow.accent(surface: Color): Color =
    when (kind) {
        "FAILED" -> palette.destructive
        "ANSWER" -> palette.warning
        "UNREAD" -> palette.accent
        "RUNNING" -> palette.info
        "REVIEW" -> palette.purple
        else -> palette.secondaryLabel
    }.readableOn(surface)

/**
 * One status mark: a question for the user, an unread reply, a failure, a review, else a pin.
 * Running and finished rows have none; the ring and the preview already say it.
 */
@Composable
private fun InboxBadge(row: ActivityRow, showPin: Boolean, surface: Color, modifier: Modifier) {
    val tag = Modifier.testTag("inbox-badge-${row.kind.lowercase()}")
    when (row.kind) {
        "ANSWER" -> FilledBadge("?", palette.warning, "Waiting for your answer", modifier.then(tag))
        "FAILED" -> FilledBadge("!", palette.destructive, "Agent failed", modifier.then(tag))
        "UNREAD" ->
            Box(
                modifier
                    .then(tag)
                    .padding(horizontal = 5.dp)
                    .size(12.dp)
                    .background(palette.accent, CircleShape)
                    .semantics { contentDescription = "New reply" }
            )
        "REVIEW" ->
            Icon(
                Glyph.EYE,
                "Ready for review",
                modifier.then(tag),
                tint = palette.purple.readableOn(surface),
                size = 17.dp,
                weight = GlyphWeight.SEMIBOLD,
            )
        else ->
            if (row.pinned && showPin)
                Icon(Glyph.PIN, "Pinned", modifier, tint = palette.tertiaryLabel, size = 15.dp)
    }
}

@Composable
private fun FilledBadge(text: String, color: Color, description: String, modifier: Modifier) {
    Box(
        modifier.size(22.dp).background(color, CircleShape).semantics {
            contentDescription = description
        },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            style = type.footnote.copy(fontWeight = FontWeight.Bold),
            color = contentOn(color),
            maxLines = 1,
        )
    }
}

/** The project's avatar, or a chat bubble for an unfiled chat; a working agent spins a ring. */
@Composable
private fun InboxAvatar(row: ActivityRow) {
    val card = row.card ?: return
    val running = row.kind == "RUNNING"
    val size = 52.dp
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        val inner: Dp = if (running) 42.dp else 46.dp
        if (running) RunningRing(palette.info, size, inner * .28f + 4.dp)
        if (row.project_name.isEmpty())
            Box(
                Modifier.size(inner)
                    .clip(RoundedCornerShape(inner * .28f))
                    .background(palette.fill),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Glyph.CHAT, null, tint = palette.secondaryLabel, size = inner * .48f)
            }
        else ProjectAvatar(card.project_id, row.project_name, inner)
    }
}

/** Reveals the row's swipe actions; a row that leaves the Inbox goes with its swipe. */
@Composable
private fun SwipeRow(
    row: ActivityRow,
    modifier: Modifier,
    onSwipe: (SwipeAction) -> Unit,
    content: @Composable () -> Unit,
) {
    // Not saveable: the list restores saved item state by key, so a row archived mid-swipe would
    // come back (after Undo) still swiped away.
    val threshold = SwipeToDismissBoxDefaults.positionalThreshold
    val state = remember { SwipeToDismissBoxState(SwipeToDismissBoxValue.Settled, threshold) }
    val scope = rememberCoroutineScope()
    val leading = row.leadingAction
    val trailing = row.trailingAction
    SwipeToDismissBox(
        state,
        modifier = modifier,
        backgroundContent = {
            when (state.dismissDirection) {
                SwipeToDismissBoxValue.StartToEnd -> SwipeBackground(leading, Alignment.CenterStart)
                SwipeToDismissBoxValue.EndToStart -> SwipeBackground(trailing, Alignment.CenterEnd)
                SwipeToDismissBoxValue.Settled -> {}
            }
        },
        onDismiss = { direction ->
            val action =
                when (direction) {
                    SwipeToDismissBoxValue.StartToEnd -> leading
                    SwipeToDismissBoxValue.EndToStart -> trailing
                    SwipeToDismissBoxValue.Settled -> null
                }
            action?.let(onSwipe)
            scope.launch {
                if (action == SwipeAction.ARCHIVE) delay(450)
                state.reset()
            }
        },
    ) {
        content()
    }
}

@Composable
private fun SwipeBackground(action: SwipeAction, alignment: Alignment) {
    val color = action.color
    val content = contentOn(color)
    Box(
        Modifier.fillMaxSize().background(color).padding(horizontal = 24.dp),
        contentAlignment = alignment,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(action.glyph, null, tint = content, size = 22.dp, weight = GlyphWeight.SEMIBOLD)
            Spacer(Modifier.height(3.dp))
            Text(
                action.title,
                style = type.caption.copy(fontWeight = FontWeight.SemiBold),
                color = content,
            )
        }
    }
}

private fun ActivityRow.age(now: Instant) =
    Activity.age(
        shown_at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
        now,
        suffix = false,
    )

/** A comet running around the avatar's rounded square while the agent works. */
@Composable
private fun RunningRing(tint: Color, size: Dp, corner: Dp) {
    val head by
        rememberInfiniteTransition()
            .animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing)))
    Canvas(Modifier.size(size)) {
        val width = 2.dp.toPx()
        val inset = width / 2
        val box = Size(this.size.width - width, this.size.height - width)
        val radius = CornerRadius(corner.toPx())
        drawRoundRect(
            tint.copy(alpha = .16f),
            Offset(inset, inset),
            box,
            radius,
            style = Stroke(width),
        )
        // The tail fades over the 40 % of the turn behind the head.
        val stops =
            (0..24).map { step ->
                val at = step / 24f
                val behind = ((head - at) % 1f + 1f) % 1f
                at to tint.copy(alpha = (1f - behind / .4f).coerceIn(0f, 1f))
            }
        drawRoundRect(
            Brush.sweepGradient(*stops.toTypedArray()),
            Offset(inset, inset),
            box,
            radius,
            style = Stroke(width, cap = StrokeCap.Round),
        )
    }
}

@Composable
private fun ActivityTimeline(rows: List<ActivityRow>, now: Instant, onOpen: (String) -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 6.dp)
            .clip(RoundedCornerShape(if (apple) 22.dp else 20.dp))
            .background(palette.cell)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row {
            Text("Last 24 hours", Modifier.weight(1f), style = type.headline, color = palette.label)
            Text("Now", style = type.caption, color = palette.secondaryLabel)
        }
        rows.take(12).forEach { row ->
            val span =
                Activity.span(
                    row.started_at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
                    row.at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
                    row.kind == "RUNNING",
                    now,
                    24,
                ) ?: return@forEach
            val tint =
                if (row.kind == "RUNNING") palette.info
                else if (row.needs_you) palette.warning else palette.secondaryLabel
            Row(
                Modifier.fillMaxWidth().pressable(onClick = { row.card?.id?.let(onOpen) }),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    row.title,
                    Modifier.width(118.dp),
                    style = type.footnote,
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.width(10.dp))
                BoxWithConstraints(
                    Modifier.weight(1f).height(16.dp).clip(CircleShape).background(palette.fill)
                ) {
                    Box(
                        Modifier.offset(x = maxWidth * span.from.toFloat())
                            .width((maxWidth * (span.to - span.from).toFloat()).coerceAtLeast(6.dp))
                            .fillMaxHeight()
                            .clip(CircleShape)
                            .background(tint)
                    )
                }
            }
        }
    }
}

private fun MobileStore.pinInbox(row: ActivityRow) {
    val card = row.card ?: return
    command(
        Command(navigation = NavigationCommand(pin_inbox_card = PinInboxCard(card.id, !row.pinned)))
    )
}
