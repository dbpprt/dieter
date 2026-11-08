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
import androidx.compose.foundation.border
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.api.v1.Card
import com.getdieter.client.v1.*
import com.getdieter.core.activity.Activity
import com.getdieter.mobile.app.*
import com.getdieter.mobile.board.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class InboxFilter(val title: String, val glyph: Glyph) {
    ALL("All", Glyph.INBOX),
    RUNNING("Running", Glyph.BOLT),
    NEEDS_YOU("Needs you", Glyph.CHAT),
    REVIEW("Review", Glyph.EYE),
}

/**
 * Running work first, then pins, what needs the user and the rest. Live and waiting work sits on
 * raised cards; finished work is a quiet grouped list. Rows swipe: right for the row's quick action
 * (read, done or pin), left to archive or, while the agent works, to stop it.
 */
@Composable
internal fun InboxScreen(store: MobileStore) {
    val view by store.workspace.activity.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val refreshing by store.session.refreshing.collectAsState()
    val session by store.session.slice.collectAsState()
    val quotas by store.machines.quotas.collectAsState()
    val selected by store.conversation.selectedCard.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var searching by rememberSaveable { mutableStateOf(false) }
    var project by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(InboxFilter.ALL) }
    var timeline by rememberSaveable { mutableStateOf(false) }
    var rulesOpen by rememberSaveable { mutableStateOf(false) }
    var stopping by remember { mutableStateOf<Card?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val now = rememberNow()
    val scoped =
        view.rows.filter { row ->
            (project.isEmpty() || row.card?.project_id == project) &&
                Activity.matches(query, row.title, row.project_name, row.board_name)
        }
    val rows = scoped.filter { it.matches(filter) }
    val projectName = workspace.projects.firstOrNull { it.id == project }?.name
    val quiet = workspace.loaded && scoped.none { it.needs_you || it.kind == "RUNNING" }

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

    val chrome =
        ScreenChrome(
            "Inbox",
            subtitle =
                listOfNotNull(projectName, "All caught up".takeIf { quiet }).joinToString(" · "),
            // Keep the title beside the toolbar controls and the inbox content near the top.
            large = false,
            actions =
                listOf(
                    ChromeAction("inbox-search", "Search", Glyph.SEARCH, checked = searching) {
                        if (searching) query = ""
                        searching = !searching
                    },
                    ChromeAction(
                        "inbox-filter",
                        "Filter",
                        Glyph.FILTER,
                        checked = project.isNotEmpty(),
                        menu =
                            listOf(
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
                                        ChromeAction("inbox-rules", "Inbox rules…", Glyph.FILTER) {
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
                    if (searching || query.isNotEmpty())
                        item("search") {
                            SearchField(
                                query,
                                { query = it },
                                "Search activity",
                                Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                                testTag = "inbox-search-field",
                            )
                        }
                    item("pulse") {
                        InboxPulse(
                            InboxFilter.entries.associateWith { value ->
                                scoped.count { it.matches(value) }
                            },
                            filter,
                        ) {
                            filter = it
                        }
                    }
                    if (quotas.group_rows.any { it.lowest_remaining >= 0 })
                        item("usage") {
                            UsageStrip(quotas) {
                                store.showFrom(
                                    MobileRoute.Root(MobileTab.INBOX),
                                    MobileRoute.Tool(ToolPage.USAGE),
                                )
                            }
                        }
                    val hidden = view.summary?.hidden ?: 0
                    if (hidden > 0)
                        item("hidden") {
                            HiddenByRules(hidden, Modifier.testTag("inbox-hidden")) {
                                rulesOpen = true
                            }
                        }
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
                                    filter != InboxFilter.ALL -> "Nothing here"
                                    else -> "All quiet"
                                },
                                when {
                                    query.isNotBlank() -> "No conversations match “$query”."
                                    filter == InboxFilter.NEEDS_YOU ->
                                        "Nothing needs your attention right now."
                                    else -> "Running work, replies and reviews appear here."
                                },
                                Modifier.padding(top = 24.dp),
                            )
                        }
                    inboxSections(rows).forEach { (section, sectionRows) ->
                        item("header-$section") { InboxSectionHeader(section, sectionRows.size) }
                        itemsIndexed(sectionRows, key = { _, row -> "row-" + row.card!!.id }) {
                            index,
                            row ->
                            val machine =
                                session.machines
                                    .takeIf { it.size > 1 }
                                    ?.firstOrNull { it.id == row.card?.owner_daemon_id }
                                    ?.display_name
                            InboxRow(
                                store,
                                row,
                                now,
                                compact =
                                    section == InboxSection.REVIEW ||
                                        section == InboxSection.RECENT,
                                position = Position.of(index, sectionRows.size),
                                selected = row.card!!.id == selected,
                                machine = machine,
                                onSwipe = ::perform,
                            )
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

private fun ActivityRow.matches(filter: InboxFilter) =
    when (filter) {
        InboxFilter.ALL -> true
        InboxFilter.NEEDS_YOU -> needs_you
        InboxFilter.RUNNING -> kind == "RUNNING"
        InboxFilter.REVIEW -> kind == "REVIEW"
    }

private val ActivityRow.tint: Color
    @Composable
    get() =
        when {
            kind == "FAILED" -> palette.destructive
            needs_you -> palette.warning
            kind == "RUNNING" -> palette.info
            kind == "REVIEW" -> palette.purple
            else -> palette.secondaryLabel
        }

private val InboxFilter.tint: Color
    @Composable
    get() =
        when (this) {
            InboxFilter.RUNNING -> palette.info
            InboxFilter.NEEDS_YOU -> palette.warning
            InboxFilter.REVIEW -> palette.purple
            InboxFilter.ALL -> palette.accent
        }

/** White or black, whichever reads on [background]. */
private fun contentOn(background: Color) =
    if (background.luminance() > .5f) Color.Black else Color.White

/** A raised card's fill: lifted towards white in light mode so it stands off the background. */
private val cardFill: Color
    @Composable get() = if (palette.dark) palette.cell else lerp(palette.cell, Color.White, .75f)

// ---------------------------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------------------------

/** Running, needs-you and review counts as tiles; tapping one filters the Inbox to it. */
@Composable
private fun InboxPulse(
    counts: Map<InboxFilter, Int>,
    filter: InboxFilter,
    onFilter: (InboxFilter) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = ScreenMargin, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        listOf(InboxFilter.RUNNING, InboxFilter.NEEDS_YOU, InboxFilter.REVIEW).forEach { value ->
            PulseTile(value, counts[value] ?: 0, filter == value, Modifier.weight(1f)) {
                onFilter(if (filter == value) InboxFilter.ALL else value)
            }
        }
    }
}

@Composable
private fun PulseTile(
    value: InboxFilter,
    count: Int,
    selected: Boolean,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val tint = value.tint
    val shape = RoundedCornerShape(20.dp)
    val content = if (selected) contentOn(tint) else palette.label
    val idle = count == 0 && !selected
    Column(
        modifier
            .then(
                if (!palette.dark && !selected)
                    Modifier.shadow(
                        1.dp,
                        shape,
                        ambientColor = Color.Black.copy(.04f),
                        spotColor = Color.Black.copy(.08f),
                    )
                else Modifier
            )
            .clip(shape)
            .background(if (selected) tint else cardFill)
            .then(
                if (!selected && !idle)
                    Modifier.background(
                        Brush.linearGradient(
                            0f to tint.copy(alpha = if (palette.dark) .2f else .1f),
                            .75f to Color.Transparent,
                        )
                    )
                else Modifier
            )
            .then(
                if (!selected)
                    Modifier.border(
                        .5.dp,
                        palette.separator.copy(alpha = if (palette.dark) .5f else .3f),
                        shape,
                    )
                else Modifier
            )
            .pressable(onClick = onClick, highlight = true)
            .semantics { this.selected = selected }
            .testTag("inbox-filter-${value.name.lowercase()}")
            .padding(start = 14.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "$count",
                Modifier.weight(1f),
                style = type.title1.copy(fontWeight = FontWeight.Bold),
                color = if (idle) palette.tertiaryLabel else content,
                maxLines = 1,
            )
            if (value == InboxFilter.RUNNING && count > 0)
                LiveDot(if (selected) content else tint, size = 12.dp)
            else
                Icon(
                    value.glyph,
                    null,
                    tint =
                        when {
                            selected -> content
                            idle -> palette.tertiaryLabel
                            else -> tint
                        },
                    size = 17.dp,
                    weight = GlyphWeight.SEMIBOLD,
                )
        }
        Text(
            value.title,
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = if (selected) content.copy(alpha = .86f) else palette.secondaryLabel,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Remaining provider usage as small gauges; opens the Usage page. */
@Composable
private fun UsageStrip(quotas: QuotasSlice, open: () -> Unit) {
    val groups = quotas.group_rows.filter { it.lowest_remaining >= 0 }
    Row(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 4.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(palette.cell)
            .pressable(onClick = open, highlight = true)
            .padding(start = 14.dp, end = 10.dp, top = 9.dp, bottom = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        groups.take(3).forEach { group ->
            val low = group.lowest_remaining < 20
            Row(
                Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                UsageGauge(
                    group.lowest_remaining / 100f,
                    if (low) palette.warning else palette.success,
                )
                Column {
                    Text(
                        group.provider_name,
                        style = type.caption2,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        "${group.lowest_remaining}% left",
                        style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                        color =
                            if (low) palette.warning.readableOn(palette.cell) else palette.label,
                        maxLines = 1,
                    )
                }
            }
        }
        Icon(
            Glyph.CHEVRON_RIGHT,
            "Usage",
            tint = palette.tertiaryLabel,
            size = 13.dp,
            weight = GlyphWeight.SEMIBOLD,
        )
    }
}

@Composable
private fun UsageGauge(fraction: Float, color: Color) {
    val track = palette.fill
    Canvas(Modifier.size(22.dp)) {
        val stroke = Stroke(3.dp.toPx(), cap = StrokeCap.Round)
        val inset = stroke.width / 2
        val arc = Size(size.width - stroke.width, size.height - stroke.width)
        drawArc(track, 0f, 360f, false, Offset(inset, inset), arc, style = stroke)
        drawArc(
            color,
            -90f,
            360f * fraction.coerceIn(0f, 1f),
            false,
            Offset(inset, inset),
            arc,
            style = stroke,
        )
    }
}

@Composable
private fun HiddenByRules(count: Int, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .padding(horizontal = ScreenMargin, vertical = 4.dp)
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

@Composable
private fun InboxSectionHeader(section: InboxSection, count: Int) {
    Row(
        Modifier.fillMaxWidth()
            .padding(
                start = ScreenMargin + 4.dp,
                end = ScreenMargin + 4.dp,
                top = 20.dp,
                bottom = 9.dp,
            )
            .semantics(mergeDescendants = true) {}
            .testTag("inbox-section-${section.name.lowercase()}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when (section) {
            InboxSection.RUNNING -> LiveDot(palette.info, size = 10.dp)
            InboxSection.PINNED ->
                Icon(
                    Glyph.PIN,
                    null,
                    tint = palette.accent,
                    size = 15.dp,
                    weight = GlyphWeight.SEMIBOLD,
                )
            InboxSection.ATTENTION ->
                Box(Modifier.size(8.dp).background(palette.warning, CircleShape))
            InboxSection.REVIEW ->
                Icon(
                    Glyph.EYE,
                    null,
                    tint = palette.purple,
                    size = 15.dp,
                    weight = GlyphWeight.SEMIBOLD,
                )
            InboxSection.RECENT ->
                Icon(Glyph.CLOCK, null, tint = palette.secondaryLabel, size = 14.dp)
        }
        Text(
            when (section) {
                InboxSection.RUNNING -> "Running"
                InboxSection.PINNED -> "Pinned"
                InboxSection.ATTENTION -> "Needs you"
                InboxSection.REVIEW -> "Review"
                InboxSection.RECENT -> "Recent"
            },
            style =
                if (apple) type.headline.copy(fontWeight = FontWeight.Bold)
                else type.title3.copy(fontWeight = FontWeight.SemiBold),
            color = palette.label,
        )
        Text(
            "$count",
            Modifier.clip(CircleShape)
                .background(palette.fill)
                .padding(horizontal = 7.dp, vertical = 1.dp),
            style = type.caption.copy(fontWeight = FontWeight.SemiBold),
            color = palette.secondaryLabel,
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

/** Swiping right: read an unread reply, finish a review, or pin. */
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

@Composable
private fun InboxRow(
    store: MobileStore,
    row: ActivityRow,
    now: Instant,
    compact: Boolean,
    position: Position,
    selected: Boolean,
    machine: String?,
    onSwipe: (SwipeAction, ActivityRow) -> Unit,
) {
    val card = row.card ?: return
    val menu = rememberMenuState()
    val onMenu = { menu.show(inboxMenu(store, row) { onSwipe(it, row) }) }
    val shape =
        if (compact) groupShape(position) else RoundedCornerShape(if (apple) 24.dp else 22.dp)
    val gap =
        when {
            position.isFirst -> 0.dp
            compact -> if (apple) 0.dp else 2.dp
            else -> 10.dp
        }
    MenuAnchor(menu) {
        SwipeRow(
            row,
            Modifier.padding(horizontal = ScreenMargin)
                .padding(top = gap)
                .then(
                    if (!compact && !palette.dark && !selected)
                        Modifier.shadow(
                            2.dp,
                            shape,
                            ambientColor = Color.Black.copy(.05f),
                            spotColor = Color.Black.copy(.12f),
                        )
                    else Modifier
                )
                .clip(shape)
                .testTag("activity-row-${card.id}"),
            onSwipe = { onSwipe(it, row) },
        ) {
            if (compact)
                CompactRow(
                    row,
                    now,
                    position,
                    selected,
                    machine,
                    onOpen = { store.openConversation(card.id) },
                    onMenu = onMenu,
                    onFinish = { onSwipe(SwipeAction.DONE, row) },
                )
            else
                InboxCard(
                    row,
                    now,
                    shape,
                    selected,
                    machine,
                    onOpen = { store.openConversation(card.id) },
                    onMenu = onMenu,
                    onFinish = { onSwipe(SwipeAction.DONE, row) },
                )
        }
    }
}

/** The long-press menu: the Inbox's own actions, then the card's. */
private fun inboxMenu(
    store: MobileStore,
    row: ActivityRow,
    perform: (SwipeAction) -> Unit,
): List<MenuSection> {
    val card = row.card ?: return emptyList()
    val sections = cardMenuSections(store, card, row.can_finish)
    val inbox =
        MenuSection(
            listOfNotNull(
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
            )
        )
    return sections.take(1) + inbox + sections.drop(1)
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

/**
 * Live or waiting work: the project avatar ringed by its status, where it belongs, the title, and a
 * callout saying what happens now — the agent's current step or what it said last.
 */
@Composable
private fun InboxCard(
    row: ActivityRow,
    now: Instant,
    shape: Shape,
    selected: Boolean,
    machine: String?,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
    onFinish: () -> Unit,
) {
    val card = row.card ?: return
    val tint = row.tint
    val running = row.kind == "RUNNING"
    val surface = if (selected) palette.accentContainer else cardFill
    Box(
        Modifier.fillMaxWidth()
            .background(surface)
            .border(
                if (selected) 1.5.dp else .5.dp,
                if (selected) palette.accent
                else palette.separator.copy(alpha = if (palette.dark) .55f else .3f),
                shape,
            )
            .pressable(onClick = onOpen, onLongClick = onMenu, highlight = true)
    ) {
        Column(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 14.dp)
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                InboxAvatar(row, tint, surface, 42.dp)
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RowContext(row, machine, Modifier.weight(1f))
                        Text(
                            row.age(now),
                            Modifier.padding(start = 8.dp),
                            style = type.footnote.copy(fontWeight = FontWeight.Medium),
                            color =
                                if (running || row.needs_you) tint.readableOn(surface)
                                else palette.secondaryLabel,
                        )
                    }
                    Spacer(Modifier.height(3.dp))
                    Text(
                        row.title,
                        style = type.bodyEmphasized.copy(fontWeight = FontWeight.SemiBold),
                        color = palette.label,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            if (running) LiveCallout(row.detail, tint, surface)
            else
                StatusCallout(row, tint, surface) {
                    if (row.can_finish) FinishChip(onFinish, Modifier.testTag("finish-${card.id}"))
                }
            if (row.stale.isNotEmpty())
                StaleNote(row.stale, surface, Modifier.padding(top = 8.dp, start = 4.dp))
        }
        if (running) RunningSweep(tint)
    }
}

/** Finished work: one quiet line for the title and one for what happened. */
@Composable
private fun CompactRow(
    row: ActivityRow,
    now: Instant,
    position: Position,
    selected: Boolean,
    machine: String?,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
    onFinish: () -> Unit,
) {
    val card = row.card ?: return
    val tint = row.tint
    val surface = if (selected) palette.accentContainer else palette.cell
    val separator = palette.separator
    val hairline = with(LocalDensity.current) { 1f / density }.dp
    val iOS = apple
    Row(
        Modifier.fillMaxWidth()
            .background(surface)
            .pressable(onClick = onOpen, onLongClick = onMenu, highlight = true)
            .drawBehind {
                if (iOS && !position.isFirst)
                    drawRect(
                        separator,
                        topLeft = Offset(60.dp.toPx(), 0f),
                        size = Size(size.width - 60.dp.toPx(), hairline.toPx()),
                    )
            }
            .padding(start = 14.dp, end = 12.dp, top = 11.dp, bottom = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        InboxAvatar(row, tint, surface, 34.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (row.pinned)
                    Icon(
                        Glyph.PIN,
                        "Pinned",
                        Modifier.padding(end = 4.dp),
                        tint = palette.accent,
                        size = 13.dp,
                    )
                Text(
                    row.title,
                    Modifier.weight(1f),
                    style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    row.age(now),
                    Modifier.padding(start = 8.dp),
                    style = type.caption,
                    color = palette.secondaryLabel,
                )
            }
            val status = row.status
            val summary = row.preview
            Text(
                listOfNotNull(
                        status.takeIf { it.isNotEmpty() },
                        summary.takeIf { it.isNotEmpty() && it != status }
                            ?: listOfNotNull(row.project_name.ifEmpty { null }, machine)
                                .joinToString(" · ")
                                .ifEmpty { null },
                    )
                    .joinToString(" · "),
                style = type.footnote,
                color =
                    if (row.kind == "REVIEW" || row.kind == "FAILED") tint.readableOn(surface)
                    else palette.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (row.can_finish)
            Box(
                Modifier.size(32.dp)
                    .clip(CircleShape)
                    .background(palette.success.copy(alpha = if (palette.dark) .2f else .12f))
                    .pressable(onClick = onFinish)
                    .semantics { contentDescription = "Mark done" }
                    .testTag("finish-${card.id}"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Glyph.CHECK,
                    null,
                    tint = palette.success.readableOn(surface),
                    size = 16.dp,
                    weight = GlyphWeight.BOLD,
                )
            }
    }
}

/** What happened in words: "New reply", "Ready for review", "Finished". */
private val ActivityRow.status: String
    get() = detail.ifEmpty { kind_label }

/** What the agent said last, when its machine summarized it. */
private val ActivityRow.preview: String
    get() = card?.summary?.trim().orEmpty()

private fun ActivityRow.age(now: Instant) =
    Activity.age(
        shown_at_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds),
        now,
        suffix = false,
    )

/** "Atlas API · Office mini", a chat bubble for chats and a pin for pinned rows. */
@Composable
private fun RowContext(row: ActivityRow, machine: String?, modifier: Modifier = Modifier) {
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (row.pinned) Icon(Glyph.PIN, "Pinned", tint = palette.accent, size = 13.dp)
        if (row.chat) Icon(Glyph.CHAT, "Chat", tint = palette.secondaryLabel, size = 12.dp)
        Text(
            listOfNotNull(row.project_name.ifEmpty { if (row.chat) "Chat" else null }, machine)
                .joinToString(" · "),
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = palette.secondaryLabel,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The status in the row's color with an optional action beside it, then what the agent said last.
 */
@Composable
private fun StatusCallout(
    row: ActivityRow,
    tint: Color,
    surface: Color,
    action: @Composable () -> Unit = {},
) {
    val wash = lerp(surface, tint, if (palette.dark) .16f else .08f)
    val status = row.status
    val preview = row.preview.takeIf { it != status }.orEmpty()
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(wash)
            .padding(start = 10.dp, end = 8.dp, top = 8.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Row(
            Modifier.heightIn(min = 22.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                row.statusGlyph,
                null,
                tint = tint.readableOn(wash),
                size = 15.dp,
                weight = GlyphWeight.SEMIBOLD,
            )
            Text(
                status,
                Modifier.weight(1f),
                style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = tint.readableOn(wash),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            action()
        }
        if (preview.isNotEmpty())
            Text(
                preview,
                Modifier.padding(start = 2.dp, end = 4.dp),
                style = type.subheadline,
                color = palette.label.copy(alpha = .82f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
    }
}

/** The agent's current step, typed out like a terminal line after a prompt. */
@Composable
private fun LiveCallout(step: String, tint: Color, surface: Color) {
    val wash = lerp(surface, tint, if (palette.dark) .14f else .06f)
    val mono = type.mono.copy(fontSize = 12.sp, lineHeight = 17.sp)
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(wash)
            .padding(start = 11.dp, end = 12.dp, top = 9.dp, bottom = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Text("›", style = mono.copy(fontWeight = FontWeight.Bold), color = tint.readableOn(wash))
        Text(
            step.ifEmpty { "Working…" },
            Modifier.weight(1f),
            style = mono,
            color = palette.label.copy(alpha = .86f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun StaleNote(text: String, surface: Color, modifier: Modifier = Modifier) {
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        val color = palette.warning.readableOn(surface)
        Icon(Glyph.OFFLINE, null, tint = color, size = 13.dp)
        Text(
            text,
            style = type.footnote,
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private val ActivityRow.statusGlyph: Glyph
    get() =
        when {
            kind == "FAILED" -> Glyph.WARNING
            kind == "ANSWER" -> Glyph.HOURGLASS
            needs_you -> Glyph.CHAT
            kind == "REVIEW" -> Glyph.EYE
            else -> Glyph.CHECK
        }

/**
 * The project's avatar, or a chat bubble for an unfiled chat. A working agent spins a ring around
 * it; other live states wear a badge.
 */
@Composable
private fun InboxAvatar(row: ActivityRow, tint: Color, ring: Color, size: Dp) {
    val card = row.card ?: return
    val running = row.kind == "RUNNING"
    val badge =
        when {
            running || row.kind == "RECENT" -> null
            row.kind == "FAILED" -> Glyph.CLOSE
            row.kind == "ANSWER" -> Glyph.HOURGLASS
            row.needs_you -> Glyph.CHAT
            row.kind == "REVIEW" -> Glyph.EYE
            else -> null
        }
    Box(Modifier.size(size + 6.dp), contentAlignment = Alignment.Center) {
        val inner = if (running) size - 4.dp else size
        if (running) RunningRing(tint, size + 4.dp, inner * .28f + 4.dp)
        if (row.project_name.isEmpty())
            Box(
                Modifier.size(inner).clip(RoundedCornerShape(inner * .3f)).background(palette.fill),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Glyph.CHAT, null, tint = palette.secondaryLabel, size = inner * .48f)
            }
        else ProjectAvatar(card.project_id, row.project_name, inner)
        if (badge != null)
            Box(
                Modifier.align(Alignment.BottomEnd).size(20.dp).background(ring, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(16.dp).background(tint, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        badge,
                        null,
                        tint = contentOn(tint),
                        size = 10.dp,
                        weight = GlyphWeight.BOLD,
                    )
                }
            }
    }
}

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
private fun FinishChip(onFinish: () -> Unit, modifier: Modifier = Modifier) {
    val tint = palette.success
    Row(
        modifier
            .clip(CircleShape)
            .background(cardFill)
            .pressable(onClick = onFinish, highlight = true)
            .semantics { contentDescription = "Mark done" }
            .padding(start = 8.dp, end = 11.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        val color = tint.readableOn(cardFill)
        Icon(Glyph.CHECK, null, tint = color, size = 14.dp, weight = GlyphWeight.BOLD)
        Text(
            "Done",
            style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = color,
            maxLines = 1,
        )
    }
}

/** A light sweeping along the bottom edge while the agent works. */
@Composable
private fun BoxScope.RunningSweep(tint: Color) {
    val progress =
        rememberInfiniteTransition()
            .animateFloat(0f, 1f, infiniteRepeatable(tween(1800, easing = LinearEasing)))
    Box(
        Modifier.align(Alignment.BottomStart).fillMaxWidth().height(2.dp).drawBehind {
            val band = size.width * .45f
            val start = -band + (size.width + band) * progress.value
            drawRect(
                Brush.horizontalGradient(
                    listOf(Color.Transparent, tint, Color.Transparent),
                    startX = start,
                    endX = start + band,
                )
            )
        }
    )
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
