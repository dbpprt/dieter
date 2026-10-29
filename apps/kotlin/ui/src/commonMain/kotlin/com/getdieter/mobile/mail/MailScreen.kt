@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package com.getdieter.mobile.mail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.MailFolder
import com.getdieter.client.v1.*
import com.getdieter.core.admin.Labels
import com.getdieter.core.presentation.Counts
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The Mail tab: one mailbox (Inbox, Flagged, Unread, Archive or Trash) of every machine's mail,
 * newest first in date groups, with search, a filter, swipe actions with undo and multi-select. The
 * core words, groups and counts everything; rows open the message beside the list on wide layouts.
 */
@Composable
internal fun MailScreen(store: MobileStore) {
    val slice by store.mail.slice.collectAsState()
    val root = MobileRoute.Root(MobileTab.MAIL)
    val rows = slice.sections.flatMap { it.rows }
    var searching by rememberSaveable { mutableStateOf(slice.search.isNotEmpty()) }
    var query by rememberSaveable { mutableStateOf(slice.search) }
    var filtering by remember { mutableStateOf(false) }
    var emptying by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<List<MailMessageRef>>(emptyList()) }
    var chosen by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val selected = rows.filter { refKey(it.ref) in chosen }
    val selecting = chosen.isNotEmpty()
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    // Rows that leave the mailbox drop out of the selection.
    LaunchedEffect(rows) {
        val listed = rows.mapTo(HashSet()) { refKey(it.ref) }
        if (chosen.any { it !in listed }) chosen = chosen.filter { it in listed }
    }
    SystemBackHandler(selecting) { chosen = emptyList() }

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

    fun move(targets: List<MailRow>, folder: MailFolder) {
        if (targets.isEmpty()) return
        store.mail.change(targets.refs(), folder = folder)
        offerUndo(described(movedVerb(folder), targets)) {
            targets
                .groupBy { it.folder }
                .forEach { (previous, group) ->
                    store.mail.change(group.refs(), folder = previous)
                }
        }
    }

    fun markRead(targets: List<MailRow>, read: Boolean) {
        if (targets.isEmpty()) return
        store.mail.change(targets.refs(), read = read)
        offerUndo(described(if (read) "Marked as read" else "Marked as unread", targets)) {
            targets
                .groupBy { it.read }
                .forEach { (previous, group) ->
                    store.mail.change(group.refs(), read = previous)
                }
        }
    }

    fun flag(targets: List<MailRow>, flagged: Boolean) {
        if (targets.isEmpty()) return
        store.mail.change(targets.refs(), flagged = flagged)
        offerUndo(described(if (flagged) "Flagged" else "Unflagged", targets)) {
            targets
                .groupBy { it.flagged }
                .forEach { (previous, group) ->
                    store.mail.change(group.refs(), flagged = previous)
                }
        }
    }

    /** Swiping a row to the left: archive it, or out of Archive and Trash, restore or delete. */
    fun swipeAway(row: MailRow) {
        when (row.folder) {
            MailFolder.MAIL_FOLDER_ARCHIVE -> move(listOf(row), MailFolder.MAIL_FOLDER_INBOX)
            MailFolder.MAIL_FOLDER_TRASH -> deleting = row.refs()
            else -> move(listOf(row), MailFolder.MAIL_FOLDER_ARCHIVE)
        }
    }

    val inTrash = slice.box == MailBox.MAIL_BOX_TRASH
    val boxTitle = slice.boxes.firstOrNull { it.box == slice.box }?.title ?: "Mail"
    val filtered = slice.filter?.let { it != MailFilter() } == true
    val boxMenu =
        listOf(
            MenuSection(
                slice.boxes.map { box ->
                    ChromeAction(
                        "mail-box-${box.box.name.removePrefix("MAIL_BOX_").lowercase()}",
                        box.title,
                        box.box.glyph,
                        checked = box.selected,
                        value = box.count_label,
                    ) {
                        chosen = emptyList()
                        store.mail.selectBox(box.box)
                    }
                }
            )
        )
    val extra =
        listOfNotNull(
            ChromeAction("mail-mark-all-read", "Mark all read", Glyph.MAIL_OPEN) {
                store.mail.markAllRead()
            },
            if (inTrash)
                ChromeAction("mail-empty-trash", "Empty Trash", Glyph.TRASH, destructive = true) {
                    emptying = true
                }
            else null,
        )
    val anyUnread = selected.any { !it.read }
    val anyUnflagged = selected.any { !it.flagged }
    val selectionActions =
        listOf(
            ChromeAction(
                "mail-selection-read",
                if (anyUnread) "Read" else "Unread",
                if (anyUnread) Glyph.MAIL_OPEN else Glyph.MAIL,
            ) {
                markRead(selected, anyUnread)
                chosen = emptyList()
            },
            ChromeAction(
                "mail-selection-flag",
                if (anyUnflagged) "Flag" else "Unflag",
                if (anyUnflagged) Glyph.FLAG else Glyph.FLAG_FILL,
            ) {
                flag(selected, anyUnflagged)
                chosen = emptyList()
            },
            if (
                selected.isNotEmpty() &&
                    selected.all { it.folder == MailFolder.MAIL_FOLDER_ARCHIVE }
            )
                ChromeAction("mail-selection-inbox", "Inbox", Glyph.MOVE_TO_INBOX) {
                    move(selected, MailFolder.MAIL_FOLDER_INBOX)
                    chosen = emptyList()
                }
            else
                ChromeAction("mail-selection-archive", "Archive", Glyph.ARCHIVE) {
                    move(
                        selected.filter { it.folder != MailFolder.MAIL_FOLDER_ARCHIVE },
                        MailFolder.MAIL_FOLDER_ARCHIVE,
                    )
                    chosen = emptyList()
                },
            ChromeAction("mail-selection-delete", "Delete", Glyph.TRASH, destructive = true) {
                // Trashed mail goes for good (after a confirmation); the rest moves to the Trash.
                val trashed = selected.filter { it.folder == MailFolder.MAIL_FOLDER_TRASH }
                move(selected - trashed.toSet(), MailFolder.MAIL_FOLDER_TRASH)
                if (trashed.isNotEmpty()) deleting = trashed.refs()
                chosen = emptyList()
            },
        )
    val chrome =
        if (selecting)
            ScreenChrome(
                "${selected.size} selected",
                cancel = ChromeAction("mail-selection-done", "Done") { chosen = emptyList() },
                actions =
                    listOf(
                        ChromeAction(
                            "mail-select-all",
                            "Select all",
                            Glyph.CHECKLIST,
                            enabled = selected.size < rows.size,
                        ) {
                            chosen = rows.map { refKey(it.ref) }
                        }
                    ),
            )
        else
            ScreenChrome(
                boxTitle,
                large = apple,
                titleMenu = boxMenu,
                actions =
                    listOf(
                        ChromeAction("mail-search", "Search", Glyph.SEARCH, checked = searching) {
                            if (searching) {
                                searching = false
                                query = ""
                                store.mail.search("")
                            } else searching = true
                        },
                        ChromeAction("mail-filter", "Filter", Glyph.FILTER, checked = filtered) {
                            filtering = true
                        },
                    ) + overflow("mail-more", extra),
            )
    Screen(
        chrome,
        bottomBar =
            if (selecting) {
                { SelectionBar(selectionActions) }
            } else null,
    ) {
        Box(Modifier.fillMaxSize().padding(top = padding.calculateTopPadding())) {
            RefreshableList(
                refreshing = slice.loading,
                onRefresh = store.session::retry,
                tag = "mail-refresh",
                topInset = 0.dp,
            ) {
                LazyColumn(
                    Modifier.fillMaxSize().testTag("mail-list"),
                    state = listState,
                    contentPadding = PaddingValues(bottom = padding.calculateBottomPadding()),
                ) {
                    titleHeader()
                    item("notice") { ConnectionNotice(store) }
                    if (searching)
                        item("search") {
                            SearchField(
                                query,
                                {
                                    query = it
                                    store.mail.search(it)
                                },
                                "Search mail",
                                Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                                testTag = "mail-search-field",
                            )
                        }
                    if (slice.action_error.isNotEmpty())
                        item("error") {
                            Banner(
                                "Mail could not be changed",
                                slice.action_error,
                                Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                                tone = Tone.WARNING,
                            )
                        }
                    if (rows.isEmpty())
                        item("empty") {
                            if (slice.loading || slice.empty_title.isEmpty())
                                Box(
                                    Modifier.fillMaxWidth().padding(vertical = 60.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Spinner()
                                }
                            else
                                EmptyState(
                                    Glyph.MAIL,
                                    slice.empty_title,
                                    slice.empty_detail,
                                    Modifier.testTag("mail-empty"),
                                )
                        }
                    slice.sections.forEach { section ->
                        stickyHeader(key = "section-${section.id}", contentType = "section") {
                            DateHeader(section.title)
                        }
                        items(
                            section.rows,
                            key = { "row-${refKey(it.ref)}" },
                            contentType = { "row" },
                        ) { row ->
                            SwipeableRow(
                                row,
                                enabled = !selecting,
                                onAway = { swipeAway(row) },
                                onRead = { markRead(listOf(row), !row.read) },
                            ) {
                                MailRowView(
                                    row,
                                    selecting = selecting,
                                    chosen = refKey(row.ref) in chosen,
                                    onClick = {
                                        val ref = row.ref ?: return@MailRowView
                                        if (selecting) chosen = chosen.toggled(refKey(ref))
                                        else
                                            store.showFrom(
                                                root,
                                                MobileRoute.MailMessage(ref.daemon_id, ref.id),
                                            )
                                    },
                                    onLongClick = { chosen = chosen.toggled(refKey(row.ref)) },
                                )
                            }
                        }
                    }
                }
            }
            SnackbarHost(
                snackbar,
                Modifier.align(Alignment.BottomCenter)
                    .padding(bottom = padding.calculateBottomPadding())
                    .testTag("mail-snackbar"),
            )
        }
    }
    if (filtering) FilterSheet(store, slice) { filtering = false }
    if (emptying)
        ConfirmDialog(
            "Empty Trash?",
            "Every message in the Trash is deleted for good on every machine.",
            "Empty Trash",
            {
                emptying = false
                store.mail.emptyTrash()
            },
            { emptying = false },
            destructive = true,
        )
    if (deleting.isNotEmpty())
        ConfirmDialog(
            if (deleting.size == 1) "Delete this message?"
            else "Delete ${Counts.of(deleting.size, "message")}?",
            "Deleted messages cannot be restored.",
            "Delete",
            {
                store.mail.delete(deleting)
                deleting = emptyList()
            },
            { deleting = emptyList() },
            destructive = true,
        )
}

/** "Archived “Subject”", or "Archived 3 messages". */
private fun described(verb: String, rows: List<MailRow>): String =
    if (rows.size == 1) "$verb “${rows.single().subject}”"
    else "$verb ${Counts.of(rows.size, "message")}"

private fun movedVerb(folder: MailFolder): String =
    when (folder) {
        MailFolder.MAIL_FOLDER_ARCHIVE -> "Archived"
        MailFolder.MAIL_FOLDER_TRASH -> "Moved to Trash"
        else -> "Moved to Inbox"
    }

internal fun refKey(ref: MailMessageRef?): String = "${ref?.daemon_id}/${ref?.id}"

private fun MailRow.refs(): List<MailMessageRef> = listOfNotNull(ref)

private fun List<MailRow>.refs(): List<MailMessageRef> = mapNotNull { it.ref }

private fun List<String>.toggled(key: String): List<String> =
    if (key in this) this - key else this + key

internal val MailBox.glyph: Glyph
    get() =
        when (this) {
            MailBox.MAIL_BOX_INBOX -> Glyph.INBOX
            MailBox.MAIL_BOX_FLAGGED -> Glyph.FLAG
            MailBox.MAIL_BOX_UNREAD -> Glyph.MAIL
            MailBox.MAIL_BOX_ARCHIVE -> Glyph.ARCHIVE
            MailBox.MAIL_BOX_TRASH -> Glyph.TRASH
        }

/**
 * Secondary commands: behind one "…" bar button on iOS, in the top app bar's overflow menu on
 * Android.
 */
@Composable
internal fun overflow(id: String, actions: List<ChromeAction>): List<ChromeAction> =
    when {
        actions.isEmpty() -> emptyList()
        apple ->
            listOf(
                ChromeAction(
                    id,
                    "More",
                    Glyph.MORE_HORIZONTAL,
                    menu = listOf(MenuSection(actions)),
                )
            )
        // Material's top bar shows the screen's first two icons and lists the rest in its
        // overflow menu; screens put their own two icons first.
        else -> actions
    }

@Composable
private fun DateHeader(title: String) {
    Text(
        if (apple) title.uppercase() else title,
        Modifier.fillMaxWidth()
            .background(palette.background)
            .padding(start = ScreenMargin + 4.dp, end = ScreenMargin, top = 10.dp, bottom = 6.dp),
        style =
            if (apple) type.footnote.copy(fontWeight = FontWeight.SemiBold)
            else type.subheadline.copy(fontWeight = FontWeight.Medium),
        color = if (apple) palette.secondaryLabel else colors.primary,
        maxLines = 1,
    )
}

/** Left: archive (or restore, or delete); right: toggle read. The row springs back after. */
@Composable
private fun SwipeableRow(
    row: MailRow,
    enabled: Boolean,
    onAway: () -> Unit,
    onRead: () -> Unit,
    content: @Composable () -> Unit,
) {
    // Not saveable: the list restores saved item state by key, so a row archived mid-swipe would
    // come back (after Undo) still swiped away.
    val threshold = SwipeToDismissBoxDefaults.positionalThreshold
    val state = remember { SwipeToDismissBoxState(SwipeToDismissBoxValue.Settled, threshold) }
    val scope = rememberCoroutineScope()
    SwipeToDismissBox(
        state,
        backgroundContent = { SwipeBackground(row, state.dismissDirection) },
        enableDismissFromStartToEnd = enabled,
        enableDismissFromEndToStart = enabled,
        gesturesEnabled = enabled,
        onDismiss = { direction ->
            when (direction) {
                SwipeToDismissBoxValue.EndToStart -> onAway()
                SwipeToDismissBoxValue.StartToEnd -> onRead()
                SwipeToDismissBoxValue.Settled -> Unit
            }
            scope.launch {
                // A row that leaves the mailbox goes with its swipe; one that stays returns.
                if (direction == SwipeToDismissBoxValue.EndToStart) delay(450)
                state.reset()
            }
        },
    ) {
        content()
    }
}

@Composable
private fun SwipeBackground(row: MailRow, direction: SwipeToDismissBoxValue) {
    val (color, glyph, title) =
        when {
            direction == SwipeToDismissBoxValue.StartToEnd ->
                Triple(
                    palette.info,
                    if (row.read) Glyph.MAIL else Glyph.MAIL_OPEN,
                    if (row.read) "Unread" else "Read",
                )
            row.folder == MailFolder.MAIL_FOLDER_TRASH ->
                Triple(palette.destructive, Glyph.TRASH, "Delete")
            row.folder == MailFolder.MAIL_FOLDER_ARCHIVE ->
                Triple(palette.info, Glyph.MOVE_TO_INBOX, "Inbox")
            else -> Triple(palette.success, Glyph.ARCHIVE, "Archive")
        }
    if (direction == SwipeToDismissBoxValue.Settled) return
    Row(
        Modifier.fillMaxSize().background(color).padding(horizontal = 24.dp),
        horizontalArrangement =
            if (direction == SwipeToDismissBoxValue.StartToEnd) Arrangement.Start
            else Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(glyph, null, tint = Color.White, size = 22.dp, weight = GlyphWeight.SEMIBOLD)
        Spacer(Modifier.width(8.dp))
        Text(
            title,
            style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
            color = Color.White,
        )
    }
}

@Composable
private fun MailRowView(
    row: MailRow,
    selecting: Boolean,
    chosen: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val unread = !row.read
    val stale = row.stale.isNotEmpty()
    Column(
        Modifier.fillMaxWidth()
            .background(
                if (chosen || (row.selected && !selecting)) palette.accentContainer
                else palette.background
            )
            .pressable(onClick = onClick, onLongClick = onLongClick, highlight = true)
            .semantics { contentDescription = row.accessibility_label }
            .testTag("mail-row-${row.ref?.id}")
    ) {
        Row(
            Modifier.fillMaxWidth()
                .graphicsAlpha(if (stale) .55f else 1f)
                .padding(start = 4.dp, end = ScreenMargin, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Box(Modifier.width(22.dp).height(40.dp), contentAlignment = Alignment.Center) {
                when {
                    selecting -> SelectionMark(chosen)
                    unread ->
                        Box(
                            Modifier.size(9.dp)
                                .background(palette.info, CircleShape)
                                .testTag("mail-unread-dot")
                        )
                }
            }
            MailAvatar(row.initials, row.sender_style, row.harness, row.sender_key)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        row.sender,
                        Modifier.weight(1f),
                        style =
                            type.subheadline.copy(
                                fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Normal
                            ),
                        color = palette.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (row.important)
                        Text(
                            "!",
                            Modifier.padding(start = 6.dp),
                            style = type.subheadline.copy(fontWeight = FontWeight.Bold),
                            color = palette.destructive,
                        )
                    if (row.flagged)
                        Icon(
                            Glyph.FLAG_FILL,
                            "Flagged",
                            Modifier.padding(start = 6.dp),
                            tint = palette.warning,
                            size = 14.dp,
                        )
                    Text(
                        row.time_label,
                        Modifier.padding(start = 8.dp),
                        style = type.footnote,
                        color = if (unread) palette.info else palette.secondaryLabel,
                        maxLines = 1,
                    )
                }
                Text(
                    row.subject,
                    style =
                        type.subheadline.copy(
                            fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Normal
                        ),
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (row.preview.isNotEmpty())
                    Text(
                        row.preview,
                        style = type.footnote,
                        color = palette.secondaryLabel,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                if (stale)
                    Row(
                        Modifier.padding(top = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Glyph.OFFLINE, null, tint = palette.warning, size = 12.dp)
                        Spacer(Modifier.width(4.dp))
                        Text(
                            row.stale,
                            style = type.caption,
                            color = palette.warning,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
            }
        }
        Hairline(inset = 4.dp + 22.dp + 40.dp + 12.dp)
    }
}

@Composable
private fun SelectionMark(chosen: Boolean) {
    Box(
        Modifier.size(20.dp)
            .clip(CircleShape)
            .then(
                if (chosen) Modifier.background(palette.accent)
                else Modifier.border(1.5.dp, palette.tertiaryLabel, CircleShape)
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (chosen)
            Icon(
                Glyph.CHECK,
                "Selected",
                tint = palette.onAccent,
                size = 12.dp,
                weight = GlyphWeight.BOLD,
            )
    }
}

/**
 * The sender's mark: a schedule's clock, an operator's terminal or a conversation's initials on a
 * stable color, with the agent's harness in the corner.
 */
@Composable
internal fun MailAvatar(
    initials: String,
    style: MailSenderStyle,
    harness: String,
    key: String,
    size: Dp = 40.dp,
) {
    val tint = labelColor(Labels.stable(key))
    Box(Modifier.size(size)) {
        Box(
            Modifier.size(size).clip(CircleShape).background(tint),
            contentAlignment = Alignment.Center,
        ) {
            when (style) {
                MailSenderStyle.MAIL_SENDER_STYLE_SCHEDULE ->
                    Icon(Glyph.CLOCK, "Schedule", tint = Color.White, size = size * .5f)
                MailSenderStyle.MAIL_SENDER_STYLE_OPERATOR ->
                    Icon(Glyph.TERMINAL, "Operator", tint = Color.White, size = size * .48f)
                else ->
                    Text(
                        initials,
                        style =
                            (if (size > 40.dp) type.headline else type.subheadline).copy(
                                fontWeight = FontWeight.Bold
                            ),
                        color = Color.White,
                        maxLines = 1,
                    )
            }
        }
        if (harness.isNotEmpty())
            Box(
                Modifier.align(Alignment.BottomEnd)
                    .offset(x = 3.dp, y = 3.dp)
                    .size(size * .42f)
                    .background(palette.background, CircleShape)
                    .padding(1.5.dp)
                    .background(harnessColor(harness), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Glyph.SPARKLES, harness, tint = Color.White, size = size * .26f)
            }
    }
}

private fun harnessColor(harness: String): Color =
    when {
        harness.startsWith("claude") -> Color(0xFFD97757)
        harness.startsWith("codex") -> Color(0xFF10A37F)
        harness.startsWith("gemini") -> Color(0xFF4285F4)
        harness.startsWith("opencode") -> Color(0xFF5E5CE6)
        else -> Color(0xFF8E8E93)
    }

/** The multi-select commands along the bottom of the list. */
@Composable
private fun SelectionBar(actions: List<ChromeAction>) {
    Column(Modifier.fillMaxWidth().background(colors.surfaceContainer)) {
        Hairline()
        Row(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            actions.forEach { action ->
                Column(
                    Modifier.weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .pressable(onClick = action.onClick, enabled = action.enabled)
                        .padding(vertical = 8.dp)
                        .testTag("chrome-${action.id}"),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    val tint = if (action.destructive) palette.destructive else palette.accent
                    Icon(action.glyph ?: Glyph.MORE, null, tint = tint, size = 22.dp)
                    Text(action.title, style = type.caption, color = tint, maxLines = 1)
                }
            }
        }
    }
}

/** Narrows the mailbox by project, machine and sender, or to important mail. */
@Composable
private fun FilterSheet(store: MobileStore, slice: MailSlice, onDismiss: () -> Unit) {
    val filter = slice.filter ?: MailFilter()
    Sheet(
        "Filter",
        onDismiss,
        size = SheetSize.MEDIUM,
        confirm =
            if (filter != MailFilter())
                ChromeAction("mail-filter-clear", "Clear") { store.mail.filter(MailFilter()) }
            else null,
    ) {
        Spacer(Modifier.height(8.dp))
        val pickers =
            listOf(
                Triple("Project", slice.projects, filter.project_id),
                Triple("Machine", slice.machines, filter.daemon_id),
                Triple("Sender", slice.senders, filter.sender_key),
            )
        Group(pickers + null) { picker, position ->
            if (picker == null)
                ListRow(
                    "Important only",
                    position = position,
                    trailing = {
                        DSwitch(
                            filter.important_only,
                            { store.mail.filter(filter.copy(important_only = it)) },
                            Modifier.testTag("mail-filter-important"),
                        )
                    },
                )
            else {
                val (title, options, chosen) = picker
                PickerRow(
                    title,
                    options.firstOrNull { it.id == chosen }?.title ?: "All",
                    listOf("" to "All") + options.map { it.id to it.title },
                    chosen,
                    enabled = options.isNotEmpty(),
                    position = position,
                    tag = "mail-filter-${title.lowercase()}",
                ) { value ->
                    store.mail.filter(
                        when (title) {
                            "Project" -> filter.copy(project_id = value)
                            "Machine" -> filter.copy(daemon_id = value)
                            else -> filter.copy(sender_key = value)
                        }
                    )
                }
            }
        }
        SectionFooter("The filter applies to every mailbox until you clear it.")
    }
}
