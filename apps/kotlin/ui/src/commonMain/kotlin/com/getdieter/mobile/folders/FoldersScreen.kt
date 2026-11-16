package com.getdieter.mobile.folders

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.FolderRow
import com.getdieter.client.v1.Tone as SliceTone
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

/**
 * More › Folders: every synced folder with its status, this device's next background sync and the
 * way to Settings › Folder sync, Sync now and Add folder. On wide layouts it stays beside the open
 * folder.
 */
@Composable
internal fun FoldersScreen(store: MobileStore) {
    val slice by store.folders.list.collectAsState()
    val settings by store.folders.settings.collectAsState()
    val navigation by store.routes.collectAsState()
    val root = MobileRoute.Tool(ToolPage.FOLDERS)
    val selected = navigation.stack.getOrNull(navigation.stack.indexOf(root) + 1)?.key
    Screen(
        ScreenChrome(
            "Folders",
            subtitle =
                when (slice.folders.size) {
                    0 -> ""
                    1 -> "1 folder"
                    else -> "${slice.folders.size} folders"
                },
            actions =
                listOf(
                    ChromeAction(
                        "folders-sync-now",
                        "Sync now",
                        Glyph.SYNC,
                        enabled = slice.folders.any { it.on_device },
                    ) {
                        store.folders.syncNow()
                    },
                    ChromeAction("folders-add", "Add folder", Glyph.ADD) {
                        store.present(MobileRoute.AddFolder())
                    },
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("folders-list"),
            state = listState,
            contentPadding = padding,
        ) {
            item("connection") { ConnectionNotice(store) }
            if (slice.notice.isNotEmpty())
                item("notice") {
                    Banner(
                        "Folder sync is off",
                        slice.notice,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.WARNING,
                        actionLabel = "Settings",
                        onAction = { store.showFrom(root, MobileRoute.FolderSync) },
                    )
                }
            if (slice.action_error.isNotEmpty())
                item("error") { ListNote(slice.action_error, color = palette.destructive) }
            if (slice.loading)
                item("loading") {
                    Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) { Spinner() }
                }
            else if (slice.folders.isEmpty())
                item("empty") {
                    EmptyState(
                        Glyph.FOLDER,
                        slice.empty_title.ifEmpty { "No folders yet" },
                        slice.empty_detail,
                        Modifier.testTag("folders-empty"),
                    ) {
                        DButton(
                            "Add folder",
                            { store.present(MobileRoute.AddFolder()) },
                            Modifier.testTag("folders-empty-add"),
                            glyph = Glyph.ADD,
                        )
                    }
                }
            itemsIndexed(slice.folders, key = { _, row -> row.id }) { index, row ->
                val route = MobileRoute.Folder(row.id)
                FolderListRow(row, index == 0, route.key == selected) {
                    store.showFrom(root, route)
                }
            }
            if (slice.folders.isNotEmpty())
                item("add") {
                    ListRow(
                        onClick = { store.present(MobileRoute.AddFolder()) },
                        Modifier.testTag("folders-add-row"),
                        leading = { ListIconTile(Glyph.ADD, palette.accent) },
                    ) {
                        ListTitle("Add folder", color = palette.accent)
                    }
                }
            if (slice.device_capable || settings.device_capable) {
                item("device-header") { ListSectionHeader("This device") }
                item("device-next-sync") {
                    val summary =
                        listOf(
                                settings.next_sync,
                                settings.reason,
                                settings.used_label.takeIf { settings.folders_on_device > 0 },
                            )
                            .filter { !it.isNullOrBlank() }
                            .joinToString(" · ")
                    ListRow(
                        onClick = null,
                        Modifier.testTag("folders-next-sync"),
                        first = true,
                        leading = { ListIconTile(Glyph.CLOCK) },
                        subtitle = {
                            ListSubtitle(
                                summary.ifEmpty {
                                    if (settings.folders_on_device == 0)
                                        "No folder is on this device yet"
                                    else "Not scheduled"
                                }
                            )
                        },
                    ) {
                        ListTitle("Next background sync")
                    }
                }
                item("device-settings") {
                    ListRow(
                        onClick = { store.showFrom(root, MobileRoute.FolderSync) },
                        Modifier.testTag("folders-settings"),
                        surface = listRowSurface(selected = MobileRoute.FolderSync.key == selected),
                        leading = { ListIconTile(Glyph.SETTINGS) },
                    ) {
                        ListTitle("Folder sync settings")
                    }
                }
            }
        }
    }
}

/**
 * A folder: its tile with a status dot, its name (with a spinner while it syncs), and its status
 * and this device's direction.
 */
@Composable
private fun FolderListRow(row: FolderRow, first: Boolean, selected: Boolean, onClick: () -> Unit) {
    val surface = listRowSurface(selected = selected)
    val subtitle =
        // A folder kept elsewhere names its machines in its status.
        listOf(row.status, row.direction.takeIf { row.on_device })
            .filter { !it.isNullOrBlank() }
            .joinToString(" · ")
    ListRow(
        onClick = onClick,
        Modifier.testTag("folder-row-${row.id}"),
        surface = surface,
        first = first,
        leading = {
            Box(Modifier.size(ListLeading), contentAlignment = Alignment.Center) {
                ListIconTile(
                    when {
                        row.attention -> Glyph.WARNING
                        row.on_device -> Glyph.FOLDER
                        else -> Glyph.FOLDER_OPEN
                    },
                    when {
                        row.attention -> palette.warning
                        row.on_device -> ToolPage.FOLDERS.color
                        else -> palette.secondaryLabel
                    },
                )
                if (row.tone != SliceTone.TONE_NEUTRAL)
                    StatusDot(
                        row.tone,
                        Modifier.align(Alignment.BottomEnd)
                            .size(13.dp)
                            .background(surface, CircleShape)
                            .padding(2.5.dp),
                    )
            }
        },
        meta = { if (row.syncing) Spinner(Modifier.padding(start = 6.dp).size(14.dp)) },
        subtitle = { ListSubtitle(subtitle) },
    ) {
        ListTitle(row.name)
    }
}
