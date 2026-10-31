@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.getdieter.mobile.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.MachineEntry
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.exposingTestTags
import com.getdieter.mobile.store.*
import com.getdieter.mobile.tools.machineGlyph

/** A place in More: where it goes, and its unread badge or a glanceable value. */
@Immutable
internal class MoreEntry(
    val id: String,
    val title: String,
    val glyph: Glyph,
    val tint: Color,
    val route: MobileRoute,
    val badge: String = "",
    val value: String = "",
)

/** More's places (mail, channels, terminals, usage) and account pages (devices, settings). */
@Composable
internal fun rememberMoreEntries(store: MobileStore): Pair<List<MoreEntry>, List<MoreEntry>> {
    val mail by store.mail.slice.collectAsState()
    val channels by store.channels.slice.collectAsState()
    val quotas by store.machines.quotas.collectAsState()
    val terminals by store.terminals.overview.collectAsState()
    val lowest =
        quotas.group_rows.filter { it.lowest_remaining >= 0 }.minOfOrNull { it.lowest_remaining }
    fun tool(page: ToolPage, value: String = "") =
        MoreEntry(
            page.name.lowercase(),
            page.title,
            page.glyph,
            page.color,
            MobileRoute.Tool(page),
            value = value,
        )
    return listOf(
        MoreEntry(
            "mail",
            "Mail",
            Glyph.MAIL,
            Color(0xFF0A84FF),
            MobileRoute.Mailbox,
            badge = mail.unread_label,
        ),
        MoreEntry(
            "channels",
            "Channels",
            Glyph.TAG,
            Color(0xFFBF5AF2),
            MobileRoute.Channels,
            badge = channels.unread_label,
        ),
        tool(
            ToolPage.TERMINALS,
            terminals.entries.size.takeIf { it > 0 }?.let { "$it open" }.orEmpty(),
        ),
        tool(ToolPage.USAGE, lowest?.let { "$it% left" }.orEmpty()),
    ) to listOf(tool(ToolPage.DEVICES), tool(ToolPage.SETTINGS))
}

/** The More tab badge: unread mail and channel messages together. */
internal fun moreBadge(mailUnread: Int, channelsUnread: Int): String =
    (mailUnread.coerceAtLeast(0) + channelsUnread.coerceAtLeast(0)).let {
        when {
            it <= 0 -> ""
            it > 99 -> "99+"
            else -> "$it"
        }
    }

/** What More shows open beside or above it: the route right after the More page. */
private fun MobileNavigation.moreSelection(): String? =
    stacks.getValue(MobileTab.MORE).getOrNull(1)?.key.takeIf { tab == MobileTab.MORE }

/**
 * The More page: the iOS More tab, and on Android what back from a More place returns to. On wide
 * layouts it stays beside the open place.
 */
@Composable
internal fun MoreScreen(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    val navigation by store.routes.collectAsState()
    val (places, account) = rememberMoreEntries(store)
    val selected = navigation.moreSelection()
    val root = MobileRoute.Root(MobileTab.MORE)
    val online = session.machines.count { it.online }
    Screen(
        ScreenChrome(
            "More",
            large = true,
            actions =
                listOf(
                    ChromeAction(
                        "reconnect",
                        "Reconnect",
                        Glyph.REFRESH,
                        onClick = store.session::retry,
                    )
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("more-list"),
            state = listState,
            contentPadding = padding,
        ) {
            titleHeader()
            item { ConnectionNotice(store) }
            item {
                Spacer(Modifier.height(8.dp))
                Group(places) { entry, position ->
                    MoreRow(entry, position, entry.route.key == selected) {
                        store.showFrom(root, entry.route)
                    }
                }
            }
            item {
                SectionHeader(
                    "Machines",
                    trailing = {
                        if (session.machines.isNotEmpty())
                            Text(
                                "$online of ${session.machines.size} online",
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                    },
                )
            }
            if (session.machines.isEmpty())
                item {
                    ListRow(
                        "No machines",
                        position = Position.SINGLE,
                        subtitle = "Enroll a computer with the Dieter daemon to run agents on it.",
                        glyph = Glyph.MACHINE,
                    )
                }
            itemsIndexed(session.machines, key = { _, machine -> machine.id }) { index, machine ->
                val route = MobileRoute.Machine(machine.id)
                ListRow(
                    machine.display_name,
                    Modifier.testTag("more-machine-${machine.id}"),
                    position = Position.of(index, session.machines.size),
                    subtitle = machine.statusLine(),
                    glyph = machineGlyph(machine.platform),
                    tile = if (machine.online) Color(0xFF0A84FF) else Color(0xFF8E8E93),
                    accessory = Accessory.CHEVRON,
                    selected = route.key == selected,
                    trailing = { PresenceDot(machine.online) },
                    onClick = { store.showFrom(root, route) },
                )
            }
            item {
                SectionHeader("Account")
                Group(account) { entry, position ->
                    MoreRow(entry, position, entry.route.key == selected) {
                        store.showFrom(root, entry.route)
                    }
                }
            }
        }
    }
}

@Composable
private fun MoreRow(entry: MoreEntry, position: Position, selected: Boolean, onClick: () -> Unit) {
    ListRow(
        entry.title,
        Modifier.testTag("more-${entry.id}"),
        position = position,
        glyph = entry.glyph,
        tile = entry.tint,
        value = entry.value.takeIf { it.isNotEmpty() && entry.badge.isEmpty() },
        accessory = Accessory.CHEVRON,
        selected = selected,
        trailing =
            entry.badge
                .takeIf { it.isNotEmpty() }
                ?.let { label -> { TextBadge(label, Modifier.padding(end = 4.dp)) } },
        onClick = onClick,
    )
}

/** "Online · Direct TLS · 12 ms", or why the machine can't take work. */
private fun MachineEntry.statusLine() =
    listOf(presence, detail).filter { it.isNotBlank() }.distinct().joinToString(" · ")

@Composable
private fun PresenceDot(online: Boolean) {
    Box(
        Modifier.size(9.dp)
            .background(if (online) palette.success else palette.tertiaryLabel, CircleShape)
    )
}

@Composable
private fun TextBadge(label: String, modifier: Modifier = Modifier) {
    Box(
        modifier
            .heightIn(min = 20.dp)
            .widthIn(min = 20.dp)
            .background(palette.destructive, CircleShape)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = type.caption2.copy(fontWeight = FontWeight.SemiBold),
            color = Color.White,
        )
    }
}

/**
 * Android's More: a sheet that slides up over the screen with the navigation bar docked beneath it.
 * Places are tiles, machines are rows with a screen shortcut; choosing one opens it in More.
 */
@Composable
internal fun MoreSheet(
    store: MobileStore,
    navigation: MobileNavigation,
    showBar: Boolean,
    onDismiss: () -> Unit,
) {
    val session by store.session.slice.collectAsState()
    val (places, account) = rememberMoreEntries(store)
    val selected = navigation.moreSelection()
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    fun open(route: MobileRoute) {
        store.openMore(route)
        onDismiss()
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = colors.surfaceContainerLow,
        // The docked bar reaches under the system navigation bar, as the app's own bar does.
        contentWindowInsets = {
            if (showBar) WindowInsets.safeDrawing.only(WindowInsetsSides.Top)
            else BottomSheetDefaults.windowInsets
        },
        modifier = Modifier.exposingTestTags().testTag("more-sheet"),
    ) {
        Column(
            Modifier.weight(1f, fill = false)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 12.dp)
        ) {
            TileGrid(places + account, selected, ::open)
            if (session.machines.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(start = 4.dp, top = 20.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Machines",
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.titleSmall,
                        color = colors.onSurfaceVariant,
                    )
                    Text(
                        "${session.machines.count { it.online }} of ${session.machines.size} online",
                        style = MaterialTheme.typography.labelMedium,
                        color = colors.onSurfaceVariant,
                    )
                }
                Column(
                    Modifier.clip(RoundedCornerShape(22.dp)),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    session.machines.forEach { machine ->
                        SheetMachineRow(
                            machine,
                            MobileRoute.Machine(machine.id).key == selected,
                            onOpen = { open(MobileRoute.Machine(machine.id)) },
                            onScreen = { open(MobileRoute.ScreenSession(machine.id)) },
                        )
                    }
                }
            }
        }
        if (showBar)
            NavigationBar(containerColor = colors.surfaceContainer) {
                NavigationItems(store, navigation, moreOpen = true) { tab ->
                    onDismiss()
                    if (tab != MobileTab.MORE) store.selectTab(tab)
                }
            }
    }
}

@Composable
private fun TileGrid(
    entries: List<MoreEntry>,
    selected: String?,
    onOpen: (MobileRoute) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val scale = LocalDensity.current.fontScale.coerceAtLeast(1f)
        val columns = (maxWidth / (84.dp * scale)).toInt().coerceIn(3, 6)
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            entries.chunked(columns).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { entry ->
                        Tile(
                            entry,
                            entry.route.key == selected,
                            Modifier.weight(1f),
                        ) {
                            onOpen(entry.route)
                        }
                    }
                    repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun Tile(entry: MoreEntry, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(20.dp),
        color = if (selected) colors.secondaryContainer else colors.surfaceContainerHigh,
        contentColor = if (selected) colors.onSecondaryContainer else colors.onSurface,
        modifier = modifier.heightIn(min = 92.dp).testTag("more-${entry.id}"),
    ) {
        Box {
            Column(
                Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                IconTile(entry.glyph, entry.tint, size = 26.dp)
                Text(
                    entry.title,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (entry.value.isNotEmpty())
                    Text(
                        entry.value,
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
            }
            if (entry.badge.isNotEmpty())
                TextBadge(entry.badge, Modifier.align(Alignment.TopEnd).padding(10.dp))
        }
    }
}

@Composable
private fun SheetMachineRow(
    machine: MachineEntry,
    selected: Boolean,
    onOpen: () -> Unit,
    onScreen: () -> Unit,
) {
    Surface(
        onClick = onOpen,
        color = if (selected) colors.secondaryContainer else colors.surfaceContainerHigh,
        shape = RoundedCornerShape(5.dp),
        modifier = Modifier.fillMaxWidth().testTag("more-machine-${machine.id}"),
    ) {
        Row(
            Modifier.padding(start = 16.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(contentAlignment = Alignment.BottomEnd) {
                Icon(machineGlyph(machine.platform), null, size = 24.dp)
                Box(
                    Modifier.offset(x = 3.dp, y = 2.dp)
                        .size(10.dp)
                        .background(colors.surfaceContainerHigh, CircleShape)
                        .padding(1.5.dp)
                        .background(
                            if (machine.online) palette.success else palette.tertiaryLabel,
                            CircleShape,
                        )
                )
            }
            Column(Modifier.weight(1f).padding(start = 16.dp)) {
                Text(
                    machine.display_name,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    machine.statusLine(),
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (machine.can_share_screen)
                IconButton(
                    onClick = onScreen,
                    modifier =
                        Modifier.testTag("more-screen-${machine.id}").semantics {
                            contentDescription = "Show ${machine.display_name}'s screen"
                        },
                ) {
                    Icon(Glyph.SCREENS, null, size = 22.dp)
                }
            Icon(Glyph.CHEVRON_RIGHT, null, tint = colors.onSurfaceVariant, size = 20.dp)
        }
    }
}
