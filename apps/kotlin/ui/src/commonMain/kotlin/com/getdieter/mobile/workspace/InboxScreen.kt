@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.workspace

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.activity.Activity
import com.getdieter.mobile.app.*
import com.getdieter.mobile.board.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.time.Instant

private enum class InboxFilter(val title: String) {
    ALL("All"),
    NEEDS_YOU("Needs you"),
    RUNNING("Running"),
    REVIEW("Review"),
}

@Composable
internal fun InboxScreen(store: MobileStore) {
    val view by store.workspace.activity.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val refreshing by store.session.refreshing.collectAsState()
    val session by store.session.slice.collectAsState()
    val quotas by store.machines.quotas.collectAsState()
    val selected by store.conversation.selectedCard.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var project by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(InboxFilter.ALL) }
    var timeline by rememberSaveable { mutableStateOf(false) }
    val now = rememberNow()
    val scoped =
        view.rows.filter { row ->
            (project.isEmpty() || row.card?.project_id == project) &&
                Activity.matches(query, row.title, row.project_name, row.board_name)
        }
    fun count(value: InboxFilter) = scoped.count { it.matches(value) }
    val rows = scoped.filter { it.matches(filter) }
    val running = view.summary?.running ?: 0
    val attention = view.summary?.attention ?: 0
    val projectName = workspace.projects.firstOrNull { it.id == project }?.name
    val chrome =
        ScreenChrome(
            "Inbox",
            subtitle =
                listOfNotNull(
                        projectName,
                        when {
                            attention > 0 && running > 0 -> "$attention need you · $running running"
                            attention > 0 -> "$attention need you"
                            running > 0 -> "$running running"
                            workspace.loaded -> "All caught up"
                            else -> null
                        },
                    )
                    .joinToString(" · "),
            // Keep the title beside the toolbar controls and the inbox content near the top.
            large = false,
            actions =
                listOf(
                    ChromeAction(
                        "inbox-filter",
                        "Filter",
                        Glyph.FILTER,
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
                                        ChromeAction(
                                            "timeline",
                                            "Activity timeline",
                                            Glyph.TIMELINE,
                                            checked = timeline,
                                        ) {
                                            timeline = !timeline
                                        }
                                    )
                                ),
                            ),
                    )
                ),
            primary = newTaskAction(store),
        )
    Screen(chrome) {
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
                item("search") {
                    SearchField(
                        query,
                        { query = it },
                        "Search activity",
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp)
                            .testTag("inbox-search"),
                    )
                }
                item("filters") {
                    Row(
                        Modifier.fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = ScreenMargin, vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        InboxFilter.entries.forEach { value ->
                            val total = count(value)
                            FilterPill(
                                if (value == InboxFilter.ALL || total == 0) value.title
                                else "${value.title} $total",
                                filter == value,
                                { filter = value },
                                Modifier.testTag("inbox-filter-${value.name.lowercase()}"),
                            )
                        }
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
                if (timeline && rows.isNotEmpty())
                    item("timeline") { ActivityTimeline(rows, now) { store.openConversation(it) } }
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
                            Modifier.padding(top = 32.dp),
                        )
                    }
                (listOf<ActivityRow.Section?>(null) + ActivityRow.Section.entries).forEach { section
                    ->
                    val sectionRows = rows.filter {
                        it.card != null &&
                            if (section == null) it.pinned else !it.pinned && it.section == section
                    }
                    if (sectionRows.isNotEmpty()) {
                        item("header-$section") {
                            SectionHeader(
                                when (section) {
                                    null -> "Pinned"
                                    ActivityRow.Section.SECTION_ATTENTION -> "Needs you"
                                    ActivityRow.Section.SECTION_RUNNING -> "Running"
                                    else -> "Recent"
                                },
                                prominent = true,
                                trailing = {
                                    Text(
                                        "${sectionRows.size}",
                                        style = type.footnote,
                                        color = palette.secondaryLabel,
                                    )
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
                                Position.of(index, sectionRows.size),
                                selected = row.card!!.id == selected,
                                machine =
                                    session.machines
                                        .takeIf { it.size > 1 }
                                        ?.firstOrNull { it.id == row.card?.owner_daemon_id }
                                        ?.display_name,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun ActivityRow.matches(filter: InboxFilter) =
    when (filter) {
        InboxFilter.ALL -> true
        InboxFilter.NEEDS_YOU -> needs_you
        InboxFilter.RUNNING -> kind == "RUNNING"
        InboxFilter.REVIEW -> kind == "REVIEW"
    }

@Composable
private fun InboxRow(
    store: MobileStore,
    row: ActivityRow,
    now: Instant,
    position: Position,
    selected: Boolean,
    machine: String?,
) {
    val card = row.card ?: return
    val menu = rememberMenuState()
    val tint =
        when {
            row.kind == "FAILED" -> palette.destructive
            row.needs_you -> palette.warning
            row.kind == "RUNNING" -> palette.info
            row.kind == "REVIEW" -> palette.purple
            else -> palette.tertiaryLabel
        }
    MenuAnchor(menu) {
        if (!apple) {
            MaterialInboxRow(
                row,
                now,
                position,
                selected,
                machine,
                tint,
                onOpen = { store.openConversation(card.id) },
                onMenu = { menu.show(cardMenuSections(store, card, row.can_finish)) },
                onFinish = { store.command(Command(finish_card = FinishCard(card.id))) },
                onPin = { store.pinInbox(row) },
            )
            return@MenuAnchor
        }
        GroupItem(
            position,
            Modifier.testTag("activity-row-${card.id}"),
            separatorInset = 62.dp,
            onClick = { store.openConversation(card.id) },
            onLongClick = { menu.show(cardMenuSections(store, card, row.can_finish)) },
            selected = selected,
        ) {
            Row(
                Modifier.fillMaxWidth()
                    .padding(start = 14.dp, end = 14.dp, top = 11.dp, bottom = 11.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                InboxAvatar(
                    row,
                    tint,
                    if (selected) palette.accentContainer else palette.cell,
                    size = 34.dp,
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.Top) {
                        Text(
                            row.title,
                            Modifier.weight(1f),
                            style =
                                if (row.needs_you) type.headline
                                else type.bodyEmphasized.copy(fontWeight = FontWeight.Medium),
                            color = palette.label,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            Activity.age(
                                row.shown_at_millis
                                    .takeIf { it > 0 }
                                    ?.let(Instant::fromEpochMilliseconds),
                                now,
                                suffix = false,
                            ),
                            Modifier.padding(start = 8.dp, top = 2.dp),
                            style = type.footnote,
                            color = palette.secondaryLabel,
                        )
                        InboxPin(row) { store.pinInbox(row) }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (row.chat) {
                            Icon(Glyph.CHAT, "Chat", tint = palette.secondaryLabel, size = 13.dp)
                            Spacer(Modifier.width(4.dp))
                        }
                        Text(
                            listOfNotNull(
                                    row.project_name.ifEmpty { null },
                                    row.board_name.ifEmpty { null },
                                    machine,
                                )
                                .joinToString(" · "),
                            style = type.subheadline,
                            color = palette.secondaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    val detail = row.detail.ifEmpty { row.kind_label }
                    if (detail.isNotEmpty())
                        Text(
                            detail,
                            style = type.subheadline,
                            color =
                                if (row.needs_you || row.kind == "FAILED")
                                    tint.readableOn(palette.cell)
                                else palette.secondaryLabel,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    if (row.stale.isNotEmpty())
                        Text(
                            row.stale,
                            style = type.footnote,
                            color = palette.warning.readableOn(palette.cell),
                        )
                    if (row.can_finish)
                        DButton(
                            "Mark done",
                            { store.command(Command(finish_card = FinishCard(card.id))) },
                            Modifier.padding(top = 6.dp).testTag("finish-${card.id}"),
                            kind = ButtonKind.TONAL,
                            glyph = Glyph.CHECK,
                        )
                }
            }
        }
    }
}

/** An activity card: the project's avatar with a status badge, a status wash and a live sweep. */
@Composable
private fun MaterialInboxRow(
    row: ActivityRow,
    now: Instant,
    position: Position,
    selected: Boolean,
    machine: String?,
    tint: Color,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
    onFinish: () -> Unit,
    onPin: () -> Unit,
) {
    val card = row.card ?: return
    val shape = RoundedCornerShape(20.dp)
    // Work that is live or waits for the user carries its status color; finished work stays calm.
    val active = row.kind != "RECENT" && !selected
    val surface = if (selected) palette.accentContainer else palette.cell
    val wash = if (active) lerp(surface, tint, if (palette.dark) .16f else .09f) else surface
    val statusColor = tint.readableOn(wash)
    Box(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin)
            .padding(top = if (position.isFirst) 0.dp else 8.dp)
            .testTag("activity-row-${card.id}")
            .clip(shape)
            .background(surface)
            .then(
                if (active)
                    Modifier.background(Brush.horizontalGradient(0f to wash, .7f to surface))
                else Modifier
            )
            .border(
                if (selected) 1.dp else .75.dp,
                when {
                    selected -> palette.accent
                    active -> tint.copy(alpha = .3f)
                    else -> palette.separator.copy(alpha = .28f)
                },
                shape,
            )
            .pressable(onClick = onOpen, onLongClick = onMenu, highlight = true)
    ) {
        Row(
            Modifier.fillMaxWidth()
                .padding(start = 12.dp, end = 14.dp, top = 12.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            InboxAvatar(row, tint, wash)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        row.title,
                        Modifier.weight(1f),
                        style =
                            type.bodyEmphasized.copy(
                                fontWeight =
                                    if (row.kind == "RECENT") FontWeight.Medium
                                    else FontWeight.SemiBold
                            ),
                        color = palette.label,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        Activity.age(
                            row.shown_at_millis
                                .takeIf { it > 0 }
                                ?.let(Instant::fromEpochMilliseconds),
                            now,
                            suffix = false,
                        ),
                        Modifier.padding(start = 8.dp, top = 3.dp),
                        style =
                            if (row.needs_you) type.footnote.copy(fontWeight = FontWeight.SemiBold)
                            else type.footnote,
                        color = if (row.needs_you) statusColor else palette.secondaryLabel,
                    )
                    InboxPin(row, onPin)
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    if (row.chat)
                        Icon(Glyph.CHAT, "Chat", tint = palette.secondaryLabel, size = 13.dp)
                    Text(
                        listOfNotNull(
                                row.project_name.ifEmpty { null },
                                row.board_name.ifEmpty { null },
                                machine,
                            )
                            .joinToString(" · "),
                        style = type.subheadline,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                val detail = row.detail.ifEmpty { row.kind_label }
                if (detail.isNotEmpty() || row.can_finish)
                    Row(
                        Modifier.padding(top = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Box(Modifier.weight(1f)) {
                            when {
                                detail.isEmpty() -> {}
                                row.kind == "RUNNING" ->
                                    Text(
                                        detail,
                                        style = type.subheadline,
                                        color = palette.label.copy(alpha = .78f),
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                active -> StatusPill(row.statusGlyph, detail, statusColor)
                                else ->
                                    Text(
                                        detail,
                                        style = type.subheadline,
                                        color = palette.secondaryLabel,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                            }
                        }
                        if (row.can_finish)
                            FinishChip(onFinish, Modifier.testTag("finish-${card.id}"))
                    }
                if (row.stale.isNotEmpty())
                    Row(
                        Modifier.padding(top = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        val color = palette.warning.readableOn(surface)
                        Icon(Glyph.OFFLINE, null, tint = color, size = 13.dp)
                        Text(row.stale, style = type.footnote, color = color)
                    }
            }
        }
        if (row.kind == "RUNNING") RunningSweep(tint)
    }
}

private val ActivityRow.statusGlyph: Glyph
    get() =
        when {
            kind == "FAILED" -> Glyph.WARNING
            needs_you -> Glyph.CHAT
            kind == "REVIEW" -> Glyph.EYE
            else -> Glyph.CHECK
        }

/** The project's avatar, or a chat bubble for an unfiled chat, with the row's status badge. */
@Composable
private fun InboxAvatar(row: ActivityRow, tint: Color, ring: Color, size: Dp = 40.dp) {
    val card = row.card ?: return
    Box(Modifier.size(size + 3.dp)) {
        if (row.project_name.isEmpty())
            Box(
                Modifier.size(size).clip(RoundedCornerShape(size * .28f)).background(palette.fill),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Glyph.CHAT, null, tint = palette.secondaryLabel, size = size * .5f)
            }
        else ProjectAvatar(card.project_id, row.project_name, size)
        Box(
            Modifier.align(Alignment.BottomEnd).size(18.dp).background(ring, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (row.kind == "RUNNING") LiveDot(tint, size = 14.dp)
            else
                Box(
                    Modifier.size(13.dp).background(tint, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        row.kind == "FAILED" -> Glyph.CLOSE
                        row.needs_you -> null
                        row.kind == "REVIEW" -> Glyph.EYE
                        else -> Glyph.CHECK
                    }?.let { Icon(it, null, tint = ring, size = 9.dp, weight = GlyphWeight.BOLD) }
                }
        }
    }
}

/** A tinted capsule naming what the row waits for. */
@Composable
private fun StatusPill(glyph: Glyph, text: String, tint: Color) {
    Row(
        Modifier.clip(CircleShape)
            .background(tint.copy(alpha = if (palette.dark) .16f else .11f))
            .padding(start = 8.dp, end = 10.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(glyph, null, tint = tint, size = 14.dp, weight = GlyphWeight.SEMIBOLD)
        Text(
            text,
            style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun FinishChip(onFinish: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(CircleShape)
            .background(palette.fill)
            .pressable(onClick = onFinish, highlight = true)
            .padding(start = 9.dp, end = 12.dp, top = 7.dp, bottom = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(Glyph.CHECK, null, tint = palette.label, size = 15.dp, weight = GlyphWeight.SEMIBOLD)
        Text(
            "Mark done",
            style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = palette.label,
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
private fun UsageStrip(quotas: QuotasSlice, open: () -> Unit) {
    val groups = quotas.group_rows.filter { it.lowest_remaining >= 0 }
    Row(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 6.dp)
            .clip(RoundedCornerShape(if (apple) 18.dp else 16.dp))
            .background(palette.cell)
            .pressable(onClick = open, highlight = true)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(Glyph.USAGE, null, tint = palette.secondaryLabel, size = 20.dp)
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            groups.take(3).forEach { group ->
                val low = group.lowest_remaining < 20
                Column(Modifier.weight(1f)) {
                    Text(
                        group.provider_name,
                        style = type.caption,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                    )
                    Spacer(Modifier.height(4.dp))
                    ProgressBar(
                        group.lowest_remaining / 100f,
                        color = if (low) palette.warning else palette.success,
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(
                        "${group.lowest_remaining}% left",
                        style = type.caption.copy(fontWeight = FontWeight.Medium),
                        color = palette.label,
                    )
                }
            }
        }
        if (apple)
            Icon(
                Glyph.CHEVRON_RIGHT,
                null,
                tint = palette.tertiaryLabel,
                size = 13.dp,
                weight = GlyphWeight.SEMIBOLD,
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

/** A compact pin toggle in a row's top trailing corner; a pinned row shows it in the accent. */
@Composable
private fun InboxPin(row: ActivityRow, onClick: () -> Unit) {
    val label = if (row.pinned) "Unpin from inbox" else "Pin in inbox"
    Box(
        Modifier.padding(start = 2.dp)
            .offset(x = 6.dp, y = (-4).dp)
            .size(28.dp)
            .clip(CircleShape)
            .pressable(onClick = onClick)
            .semantics { contentDescription = label }
            .testTag("inbox-pin-${row.card?.id}"),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Glyph.PIN,
            null,
            tint = if (row.pinned) palette.accent else palette.tertiaryLabel,
            size = 16.dp,
        )
    }
}
