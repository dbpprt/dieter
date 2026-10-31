@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.channels

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.presentation.Ages
import com.getdieter.mobile.app.*
import com.getdieter.mobile.conversation.ComposerChip
import com.getdieter.mobile.conversation.SendButton
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.time.Instant

/** The account's project channels, one per project and shared by every machine. */
@Composable
internal fun ChannelsScreen(store: MobileStore) {
    val slice by store.channels.slice.collectAsState()
    val settings by store.channels.settings.collectAsState()
    val navigation by store.routes.collectAsState()
    val root = MobileRoute.Channels
    val open =
        navigation.stack
            .let { stack -> stack.getOrNull(stack.indexOf(root) + 1) }
            .takeIf { root in navigation.stack } as? MobileRoute.Channel
    Screen(ScreenChrome("Channels", large = true)) {
        RefreshableList(
            refreshing = slice.loading,
            onRefresh = store.channels::refresh,
            tag = "channels-refresh",
            topInset = padding.calculateTopPadding(),
        ) {
            LazyColumn(
                Modifier.fillMaxSize().testTag("channels-list"),
                state = listState,
                contentPadding = padding,
            ) {
                titleHeader()
                item("notice") { ConnectionNotice(store) }
                if (slice.error.isNotEmpty() && slice.channels.isNotEmpty())
                    item("error") {
                        Banner(
                            "Channels could not be read",
                            slice.error,
                            Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                            tone = Tone.WARNING,
                        )
                    }
                if (slice.channels.isEmpty())
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
                                Glyph.TAG,
                                slice.empty_title,
                                slice.empty_detail,
                                Modifier.testTag("channels-empty"),
                                action =
                                    if (slice.enabled) null
                                    else {
                                        {
                                            DButton(
                                                "Turn on agent channels",
                                                { store.channels.setEnabled(true) },
                                                Modifier.testTag("channels-enable"),
                                                loading = settings.saving,
                                            )
                                        }
                                    },
                            )
                    }
                else {
                    item("projects") { SectionHeader("Projects") }
                    itemsIndexed(slice.channels, key = { _, row -> row.project_id }) { index, row ->
                        ListRow(
                            "#${row.name}",
                            Modifier.testTag("channel-row-${row.project_id}"),
                            position = Position.of(index, slice.channels.size),
                            subtitle = row.detail,
                            leading = { ChannelMark(row.enabled) },
                            trailing = {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    if (row.claims > 0)
                                        Icon(Glyph.LOCK, null, tint = palette.warning, size = 13.dp)
                                    CountBadge(row.unread)
                                }
                            },
                            accessory = Accessory.CHEVRON,
                            selected = open?.projectId == row.project_id,
                            onClick = { store.showFrom(root, MobileRoute.Channel(row.project_id)) },
                        )
                    }
                    item("footer") {
                        SectionFooter(
                            "Each project has one channel, shared by all your machines. A post " +
                                "reaches agents in their next turn; a direct message or @here " +
                                "reaches running agents at once."
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ChannelMark(enabled: Boolean) {
    Box(
        Modifier.size(30.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (enabled) palette.info.copy(alpha = .14f) else palette.fill),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Glyph.TAG,
            null,
            tint = if (enabled) palette.info else palette.tertiaryLabel,
            size = 16.dp,
            weight = GlyphWeight.SEMIBOLD,
        )
    }
}

/**
 * One project's channel: what its agents and people wrote, Dieter's coordination events, how each
 * message reached its recipients, and a composer. The read position moves when the newest message
 * shows.
 */
@Composable
internal fun ChannelScreen(store: MobileStore, projectId: String, openUrl: (String) -> Unit) {
    val slice by store.channels.slice.collectAsState()
    val stream = slice.stream?.takeIf { it.channel?.project_id == projectId }
    var info by remember { mutableStateOf(false) }
    val listed = slice.channels.firstOrNull { it.project_id == projectId }
    val chrome =
        ScreenChrome(
            stream?.title ?: "#${listed?.name ?: "channel"}",
            subtitle = stream?.subtitle.orEmpty(),
            actions =
                listOf(
                    ChromeAction("channel-info", "Agents, claims and pins", Glyph.INFO) {
                        info = true
                    }
                ),
        )
    val now = rememberNow()
    Screen(chrome) {
        val rows = stream?.rows.orEmpty()
        val atEnd by remember {
            derivedStateOf {
                val layout = listState.layoutInfo
                val last = layout.visibleItemsInfo.lastOrNull()
                last == null || last.index >= layout.totalItemsCount - 1
            }
        }
        var following by remember(projectId) { mutableStateOf(true) }
        LaunchedEffect(listState) {
            snapshotFlow { listState.isScrollInProgress to atEnd }
                .collect { (scrolling, end) -> if (!scrolling) following = end }
        }
        // The trailing "end" item: after the placeholder, the claims line and the rows.
        val end =
            (if (stream == null || stream.loading || rows.isEmpty()) 1 else 0) +
                (if (stream?.claims_summary.isNullOrEmpty()) 0 else 1) +
                rows.size
        LaunchedEffect(rows.lastOrNull()?.id, stream?.loading) {
            if (following && rows.isNotEmpty()) listState.scrollToItem(end)
        }
        LaunchedEffect(atEnd, rows.lastOrNull()?.id, stream?.unread) {
            if (atEnd && (stream?.unread ?: 0) > 0) store.channels.markRead()
        }
        Column(Modifier.fillMaxSize().imePadding()) {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth().testTag("channel-stream"),
                state = listState,
                contentPadding =
                    PaddingValues(top = padding.calculateTopPadding() + 8.dp, bottom = 12.dp),
            ) {
                when {
                    stream == null || stream.loading ->
                        item("loading") {
                            Box(
                                Modifier.fillMaxWidth().padding(vertical = 60.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Spinner()
                            }
                        }
                    rows.isEmpty() ->
                        item("empty") {
                            EmptyState(
                                Glyph.TAG,
                                "No messages yet",
                                "Agents post here when they coordinate. You can write first.",
                            )
                        }
                }
                if (stream != null && stream.claims_summary.isNotEmpty())
                    item("claims") {
                        MetaPill(
                            stream.claims_summary,
                            Glyph.LOCK,
                            Modifier.padding(horizontal = ScreenMargin, vertical = 4.dp),
                            tint = palette.warning,
                        )
                    }
                items(rows, key = { it.id }) { row ->
                    if (row.id == stream?.first_unread_row_id) NewDivider()
                    if (row.event) EventRow(row, now)
                    else
                        MessageRow(row, now, openUrl) {
                            store.channels.pin(row.id, !row.pinned)
                        }
                }
                item("end") { Spacer(Modifier.height(1.dp)) }
            }
            if (stream != null && stream.error.isNotEmpty())
                Text(
                    "Reconnecting: ${stream.error}",
                    Modifier.fillMaxWidth().padding(horizontal = ScreenMargin, vertical = 4.dp),
                    style = type.caption,
                    color = palette.warning,
                    maxLines = 2,
                )
            stream?.composer?.let { composer ->
                ChannelComposer(
                    store,
                    projectId,
                    composer,
                    stream.action_error,
                    padding.calculateBottomPadding(),
                )
            }
        }
    }
    if (info && stream != null) ChannelInfoSheet(store, stream, now) { info = false }
}

@Composable
private fun NewDivider() {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = ScreenMargin, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "New",
            style = type.caption.copy(fontWeight = FontWeight.Bold),
            color = palette.destructive,
        )
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f).height(1.dp).background(palette.destructive.copy(alpha = .5f)))
    }
}

/** A message with its author, kind, recipients, files and receipt. */
@Composable
private fun MessageRow(
    row: ChannelStreamRow,
    now: Instant,
    openUrl: (String) -> Unit,
    pin: () -> Unit,
) {
    val menu = rememberMenuState()
    val clipboard = LocalClipboardManager.current
    val author = row.author ?: ChannelAuthorView()
    MenuAnchor(menu) {
        Row(
            Modifier.fillMaxWidth()
                .pressable(
                    onClick = {},
                    onLongClick = {
                        menu.show(
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "pin",
                                            if (row.pinned) "Unpin" else "Pin as decision",
                                            Glyph.PIN,
                                            onClick = pin,
                                        ),
                                        ChromeAction("copy", "Copy", Glyph.COPY) {
                                            clipboard.setText(AnnotatedString(row.body))
                                        },
                                    )
                                )
                            )
                        )
                    },
                    role = null,
                )
                .padding(
                    start = ScreenMargin,
                    end = ScreenMargin,
                    top = if (row.continued) 2.dp else 12.dp,
                    bottom = 2.dp,
                )
                .testTag("channel-message-${row.id}"),
            verticalAlignment = Alignment.Top,
        ) {
            Box(Modifier.width(34.dp)) { if (!row.continued) ChannelAvatar(author) }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                if (!row.continued) {
                    // The name keeps its line; harness, model, machine and age go below it.
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            author.name,
                            Modifier.weight(1f, fill = false),
                            style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                            color = palette.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (row.kind_label.isNotEmpty()) KindBadge(row.kind_label, row.kind)
                        if (row.pinned)
                            Icon(Glyph.PIN, "Pinned", tint = palette.purple, size = 12.dp)
                    }
                    val meta =
                        listOf(row.meta, age(row.created_at_millis, now)).filter { it.isNotEmpty() }
                    if (meta.isNotEmpty())
                        Text(
                            meta.joinToString(" · "),
                            style = type.caption,
                            color = palette.secondaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                } else if (row.kind_label.isNotEmpty()) KindBadge(row.kind_label, row.kind)
                if (row.recipients.isNotEmpty())
                    Text(
                        if (row.here) row.recipients else "→ ${row.recipients}",
                        style = type.footnote.copy(fontWeight = FontWeight.Medium),
                        color = palette.info,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                RichText(row.body, openUrl)
                if (row.files.isNotEmpty()) Files(row.files)
                if (row.replies_label.isNotEmpty())
                    Text(
                        row.replies_label,
                        style = type.footnote.copy(fontWeight = FontWeight.Medium),
                        color = palette.info,
                    )
                if (row.receipt.isNotEmpty())
                    Text("→ ${row.receipt}", style = type.caption, color = palette.tertiaryLabel)
            }
        }
    }
}

/** Dieter's coordination event (claimed, held, released) as one compact line. */
@Composable
private fun EventRow(row: ChannelStreamRow, now: Instant) {
    Row(
        Modifier.fillMaxWidth()
            .padding(start = ScreenMargin + 44.dp, end = ScreenMargin, top = 4.dp, bottom = 4.dp)
            .semantics(mergeDescendants = true) {}
            .testTag("channel-event-${row.id}"),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.padding(top = 6.dp).size(6.dp).background(kindColor(row.kind), CircleShape))
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(row.body, style = type.footnote, color = palette.secondaryLabel)
            if (row.receipt.isNotEmpty())
                Text("→ ${row.receipt}", style = type.caption, color = palette.tertiaryLabel)
        }
        Spacer(Modifier.width(6.dp))
        Text(age(row.created_at_millis, now), style = type.caption2, color = palette.tertiaryLabel)
    }
}

@Composable
private fun Files(files: List<String>) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        files.forEach { MetaPill(it, Glyph.FILE_PLAIN) }
    }
}

@Composable
internal fun KindBadge(label: String, kind: ChannelMessageKind) {
    val color = kindColor(kind)
    Text(
        label,
        Modifier.clip(RoundedCornerShape(5.dp))
            .background(color.copy(alpha = .15f))
            .padding(horizontal = 5.dp, vertical = 1.dp),
        style = type.caption2.copy(fontWeight = FontWeight.Bold),
        color = color,
        maxLines = 1,
    )
}

/** A card's avatar: its initials on its stable colour; people and Dieter have their own. */
@Composable
internal fun ChannelAvatar(author: ChannelAuthorView, size: Dp = 34.dp) {
    val fill =
        when (author.kind) {
            ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN -> palette.accent
            ChannelAuthorKind.CHANNEL_AUTHOR_KIND_DIETER -> palette.secondaryLabel
            else -> avatarColor(author.color_index)
        }
    Initials(author.initials, fill, size)
}

@Composable
private fun Initials(initials: String, fill: Color, size: Dp) {
    Box(
        Modifier.size(size).clip(CircleShape).background(fill),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            initials.ifEmpty { "?" },
            style =
                (if (size < 30.dp) type.caption2 else type.footnote).copy(
                    fontWeight = FontWeight.SemiBold
                ),
            color = Color.White,
            maxLines = 1,
        )
    }
}

@Composable
private fun avatarColor(index: Int): Color =
    listOf(
        palette.purple,
        palette.warning,
        palette.destructive,
        palette.success,
        palette.info,
        Color(0xFFF28B7A),
        Color(0xFFAF52DE),
        Color(0xFF2588F5),
    )[(index % 8 + 8) % 8]

@Composable
private fun kindColor(kind: ChannelMessageKind): Color =
    when (kind) {
        ChannelMessageKind.CHANNEL_MESSAGE_KIND_REQUEST,
        ChannelMessageKind.CHANNEL_MESSAGE_KIND_HOLD -> palette.warning
        ChannelMessageKind.CHANNEL_MESSAGE_KIND_DONE,
        ChannelMessageKind.CHANNEL_MESSAGE_KIND_RELEASE -> palette.success
        ChannelMessageKind.CHANNEL_MESSAGE_KIND_DECISION -> palette.purple
        ChannelMessageKind.CHANNEL_MESSAGE_KIND_CLAIM -> palette.info
        else -> palette.secondaryLabel
    }

@Composable
private fun presenceColor(presence: ChannelPresence): Color =
    when (presence) {
        ChannelPresence.CHANNEL_PRESENCE_RUNNING -> palette.success
        ChannelPresence.CHANNEL_PRESENCE_WAITING -> palette.warning
        ChannelPresence.CHANNEL_PRESENCE_FAILED -> palette.destructive
        else -> palette.tertiaryLabel
    }

private fun age(millis: Long, now: Instant): String =
    if (millis <= 0) "" else Ages.compact(Instant.fromEpochMilliseconds(millis), now).orEmpty()

/**
 * What the user writes and to whom: everyone (interrupts nobody), @here (every running agent) or
 * picked agents (a direct message), with what that does, the kind, and whether to wake idle
 * recipients.
 */
@Composable
private fun ChannelComposer(
    store: MobileStore,
    projectId: String,
    composer: ChannelComposerState,
    actionError: String,
    bottomInset: Dp,
) {
    var draft by rememberSaveable(projectId) { mutableStateOf("") }
    var recipients by remember(projectId) { mutableStateOf(emptySet<String>()) }
    var here by remember(projectId) { mutableStateOf(false) }
    var kind by remember(projectId) { mutableStateOf(ChannelMessageKind.CHANNEL_MESSAGE_KIND_NOTE) }
    var wake by remember(projectId) { mutableStateOf(false) }
    val picked = composer.recipients.filter { it.card_id in recipients }
    val audience =
        when {
            here -> "@here"
            picked.isEmpty() -> "Everyone"
            picked.size == 1 -> picked.single().title
            else -> "${picked.size} agents"
        }
    val hint =
        when {
            here -> composer.here_hint
            picked.isEmpty() -> composer.everyone_hint
            else -> composer.direct_hint
        }
    val canSend = composer.can_post && !composer.sending && draft.isNotBlank()
    val audienceMenu = rememberMenuState()
    val kindMenu = rememberMenuState()
    fun send() {
        val body = draft
        store.channels.post(body, picked.map { it.card_id }, here, kind, wake) {
            if (draft == body) draft = ""
            kind = ChannelMessageKind.CHANNEL_MESSAGE_KIND_NOTE
            // @here interrupts every running agent: never keep it for the next message.
            here = false
            wake = false
        }
    }
    val imeVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    Column(
        Modifier.fillMaxWidth()
            .background(
                if (apple)
                    Brush.verticalGradient(
                        0f to palette.background.copy(alpha = 0f),
                        .18f to palette.background,
                    )
                else SolidColor(colors.surfaceContainer)
            )
            .padding(
                top = if (apple) 10.dp else 8.dp,
                bottom = if (imeVisible) 8.dp else bottomInset.coerceAtLeast(8.dp),
            )
    ) {
        val notice = actionError.ifEmpty {
            if (!composer.can_post) composer.disabled_reason else ""
        }
        if (notice.isNotEmpty())
            Text(
                notice,
                Modifier.padding(horizontal = ScreenMargin, vertical = 4.dp),
                style = type.footnote,
                color =
                    if (actionError.isNotEmpty()) palette.destructive else palette.secondaryLabel,
            )
        Row(
            Modifier.fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = ScreenMargin, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MenuAnchor(audienceMenu) {
                ComposerChip(
                    audience,
                    Glyph.TAG,
                    Modifier.testTag("channel-audience"),
                    onClick = {
                        audienceMenu.show(
                            listOf(
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "audience-everyone",
                                            "Everyone",
                                            Glyph.TAG,
                                            checked = !here && picked.isEmpty(),
                                            subtitle = "Read in each agent's next turn",
                                        ) {
                                            here = false
                                            recipients = emptySet()
                                        },
                                        ChromeAction(
                                            "audience-here",
                                            "@here",
                                            Glyph.BOLT,
                                            checked = here,
                                            subtitle = "Interrupts every running agent",
                                        ) {
                                            here = true
                                            recipients = emptySet()
                                            wake = false
                                        },
                                    )
                                )
                            ) +
                                listOfNotNull(
                                    MenuSection(
                                            composer.recipients.map { option ->
                                                ChromeAction(
                                                    "audience-${option.card_id}",
                                                    option.title,
                                                    checked = option.card_id in recipients,
                                                    subtitle =
                                                        listOf(
                                                                presenceName(option.presence),
                                                                option.machine,
                                                            )
                                                            .filter { it.isNotEmpty() }
                                                            .joinToString(" · "),
                                                ) {
                                                    here = false
                                                    recipients =
                                                        if (option.card_id in recipients)
                                                            recipients - option.card_id
                                                        else recipients + option.card_id
                                                    if (recipients.isEmpty()) wake = false
                                                }
                                            },
                                            title = "Agents",
                                        )
                                        .takeIf { composer.recipients.isNotEmpty() }
                                )
                        )
                    },
                    chevron = true,
                )
            }
            MenuAnchor(kindMenu) {
                ComposerChip(
                    composer.kinds.firstOrNull { it.kind == kind }?.label ?: "Note",
                    Glyph.LABEL,
                    Modifier.testTag("channel-kind"),
                    onClick = {
                        kindMenu.show(
                            listOf(
                                MenuSection(
                                    composer.kinds.map { option ->
                                        ChromeAction(
                                            "kind-${option.label.lowercase()}",
                                            option.label,
                                            checked = option.kind == kind,
                                            subtitle = option.detail,
                                        ) {
                                            kind = option.kind
                                        }
                                    }
                                )
                            )
                        )
                    },
                    chevron = true,
                )
            }
            if (picked.isNotEmpty())
                ComposerChip(
                    "Wake",
                    Glyph.BELL,
                    Modifier.testTag("channel-wake"),
                    onClick = { wake = !wake },
                    prominent = wake,
                )
        }
        if (hint.isNotEmpty())
            Text(
                if (wake && picked.isNotEmpty()) composer.wake_hint else hint,
                Modifier.padding(horizontal = ScreenMargin + 2.dp, vertical = 4.dp)
                    .testTag("channel-audience-hint"),
                style = type.caption,
                color = palette.secondaryLabel,
            )
        Row(
            Modifier.fillMaxWidth()
                .padding(start = ScreenMargin - 4.dp, end = ScreenMargin - 4.dp, top = 4.dp)
                .heightIn(min = if (apple) 38.dp else 48.dp)
                .clip(RoundedCornerShape(if (apple) 20.dp else 24.dp))
                .background(if (apple) palette.cell else colors.surfaceContainerHighest)
                .then(
                    if (apple)
                        Modifier.border(
                            .5.dp,
                            palette.separator.copy(alpha = .6f),
                            RoundedCornerShape(20.dp),
                        )
                    else Modifier
                )
                .padding(start = 14.dp, end = 4.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Box(Modifier.weight(1f).padding(vertical = if (apple) 8.dp else 12.dp)) {
                if (draft.isEmpty())
                    Text(composer.placeholder, style = type.body, color = palette.secondaryLabel)
                BasicTextField(
                    draft,
                    { draft = it },
                    Modifier.fillMaxWidth().testTag("channel-input").semantics {
                        contentDescription = composer.placeholder
                    },
                    enabled = composer.can_post,
                    textStyle = type.body.copy(color = palette.label),
                    cursorBrush = SolidColor(if (apple) palette.info else colors.primary),
                    maxLines = 6,
                )
            }
            Box(Modifier.padding(bottom = 4.dp)) {
                SendButton(
                    Glyph.ARROW_UP,
                    "Send to the channel",
                    ::send,
                    enabled = canSend,
                    size = if (apple) 30.dp else 40.dp,
                    tag = "channel-send",
                )
            }
        }
    }
}

private fun presenceName(presence: ChannelPresence): String =
    when (presence) {
        ChannelPresence.CHANNEL_PRESENCE_RUNNING -> "Running"
        ChannelPresence.CHANNEL_PRESENCE_WAITING -> "Waiting"
        ChannelPresence.CHANNEL_PRESENCE_FAILED -> "Failed"
        else -> "Idle"
    }

/** The channel's member agents, live claims (with a release) and pinned decisions. */
@Composable
private fun ChannelInfoSheet(
    store: MobileStore,
    stream: ChannelStreamView,
    now: Instant,
    onDismiss: () -> Unit,
) {
    Sheet(stream.title, onDismiss) {
        SectionHeader(stream.members_tab)
        if (stream.members.isEmpty()) SectionFooter("No agents in this channel yet.")
        Group(stream.members) { member, position ->
            ListRow(
                member.title,
                Modifier.testTag("channel-member-${member.card_id}"),
                position = position,
                subtitle =
                    listOf(member.presence_label, member.detail)
                        .filter { it.isNotEmpty() }
                        .joinToString(" · "),
                leading = {
                    Box {
                        Initials(member.initials, avatarColor(member.color_index), 30.dp)
                        Box(
                            Modifier.align(Alignment.BottomEnd)
                                .size(9.dp)
                                .clip(CircleShape)
                                .background(palette.cell)
                                .padding(1.5.dp)
                                .background(presenceColor(member.presence), CircleShape)
                        )
                    }
                },
            )
        }
        SectionHeader(stream.claims_tab)
        if (stream.claims.isEmpty())
            SectionFooter("No live claims. A running agent claims the files it changes.")
        Group(stream.claims) { claim, position ->
            ListRow(
                claim.path,
                Modifier.testTag("channel-claim-${claim.path}"),
                position = position,
                subtitle =
                    listOf(
                            claim.holder,
                            claim.held_label,
                            claim.waiting_label,
                            if (claim.advisory) "on ${claim.machine}, advisory" else "",
                        )
                        .filter { it.isNotEmpty() }
                        .joinToString(" · "),
                leading = {
                    Icon(
                        Glyph.LOCK,
                        null,
                        tint = if (claim.advisory) palette.tertiaryLabel else palette.warning,
                        size = 18.dp,
                    )
                },
                trailing = {
                    DButton(
                        "Release",
                        { store.channels.release(claim.card_id, claim.path) },
                        kind = ButtonKind.TONAL,
                    )
                },
            )
        }
        SectionHeader(stream.pins_tab)
        if (stream.pins.isEmpty()) SectionFooter("Pin a message as a decision with a long press.")
        Group(stream.pins) { pin, position ->
            ListRow(
                pin.body,
                position = position,
                subtitle =
                    listOf(pin.author, age(pin.created_at_millis, now))
                        .filter { it.isNotEmpty() }
                        .joinToString(" · "),
                leading = { Icon(Glyph.PIN, null, tint = palette.purple, size = 18.dp) },
                titleMaxLines = 4,
            )
        }
    }
}

/**
 * An agent channel message that joined a running turn, where it joined: who wrote it, in which
 * channel, what it said, and a way to open the channel. It is never folded into activity.
 */
@Composable
internal fun PeerNoticeCard(
    notice: TimelinePeerNotice,
    openUrl: (String) -> Unit,
    openChannel: (String) -> Unit,
) {
    val author = notice.author ?: ChannelAuthorView()
    val now = rememberNow()
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(palette.info.copy(alpha = .08f))
            .border(.75.dp, palette.info.copy(alpha = .3f), RoundedCornerShape(14.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .testTag("peer-notice-${notice.message_id}"),
        verticalAlignment = Alignment.Top,
    ) {
        ChannelAvatar(author, 26.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(Glyph.TAG, null, tint = palette.info, size = 12.dp, weight = GlyphWeight.BOLD)
                Text(
                    notice.title,
                    Modifier.weight(1f, fill = false),
                    style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (notice.kind_label.isNotEmpty()) KindBadge(notice.kind_label, notice.kind)
                val at = age(notice.created_at_millis, now)
                if (at.isNotEmpty())
                    Text(at, style = type.caption2, color = palette.tertiaryLabel, maxLines = 1)
            }
            RichText(notice.body, openUrl)
            if (notice.files.isNotEmpty()) Files(notice.files)
            if (notice.project_id.isNotEmpty())
                Row(
                    Modifier.clip(CircleShape)
                        .pressable(onClick = { openChannel(notice.project_id) })
                        .padding(vertical = 2.dp)
                        .testTag("peer-notice-open-${notice.message_id}"),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(
                        notice.open_label,
                        style = type.footnote.copy(fontWeight = FontWeight.Medium),
                        color = palette.info,
                    )
                    Icon(Glyph.CHEVRON_RIGHT, null, tint = palette.info, size = 11.dp)
                }
        }
    }
}
