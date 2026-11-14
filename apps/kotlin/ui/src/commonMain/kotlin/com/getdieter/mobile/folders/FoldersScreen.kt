package com.getdieter.mobile.folders

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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
            titleHeader()
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
            if (slice.action_error.isNotEmpty()) item("error") { SectionFooter(slice.action_error) }
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
            else item("spacer") { Spacer(Modifier.height(8.dp)) }
            itemsIndexed(slice.folders, key = { _, row -> row.id }) { index, row ->
                val route = MobileRoute.Folder(row.id)
                FolderListRow(
                    row,
                    Position.of(index, slice.folders.size),
                    route.key == selected,
                ) {
                    store.showFrom(root, route)
                }
            }
            if (slice.device_capable || settings.device_capable)
                item("device") {
                    SectionHeader("This device")
                    val summary =
                        listOf(
                                settings.next_sync,
                                settings.reason,
                                settings.used_label.takeIf { settings.folders_on_device > 0 },
                            )
                            .filter { !it.isNullOrBlank() }
                            .joinToString(" · ")
                    Group(listOf(0, 1)) { index, position ->
                        if (index == 0)
                            ListRow(
                                "Next background sync",
                                Modifier.testTag("folders-next-sync"),
                                position = position,
                                subtitle =
                                    summary.ifEmpty {
                                        if (settings.folders_on_device == 0)
                                            "No folder is on this device yet"
                                        else "Not scheduled"
                                    },
                                glyph = Glyph.CLOCK,
                            )
                        else
                            ListRow(
                                "Folder sync settings",
                                Modifier.testTag("folders-settings"),
                                position = position,
                                glyph = Glyph.SETTINGS,
                                accessory = Accessory.CHEVRON,
                                selected = MobileRoute.FolderSync.key == selected,
                                onClick = { store.showFrom(root, MobileRoute.FolderSync) },
                            )
                    }
                }
            if (slice.folders.isNotEmpty())
                item("add") {
                    Spacer(Modifier.height(12.dp))
                    ListRow(
                        "Add folder",
                        Modifier.testTag("folders-add-row"),
                        position = Position.SINGLE,
                        glyph = Glyph.ADD,
                        glyphTint = palette.accent,
                        onClick = { store.present(MobileRoute.AddFolder()) },
                    )
                }
        }
    }
}

@Composable
private fun FolderListRow(
    row: FolderRow,
    position: Position,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val subtitle =
        // A folder kept elsewhere names its machines in its status.
        listOf(row.status, row.direction.takeIf { row.on_device })
            .filter { !it.isNullOrBlank() }
            .joinToString(" · ")
    ListRow(
        row.name,
        Modifier.testTag("folder-row-${row.id}"),
        position = position,
        subtitle = subtitle,
        glyph =
            if (row.attention) Glyph.WARNING
            else if (row.on_device) Glyph.FOLDER else Glyph.FOLDER_OPEN,
        tile =
            when {
                row.attention -> palette.warning
                row.on_device -> Color(0xFF64D2FF)
                else -> palette.tertiaryLabel
            },
        accessory = Accessory.CHEVRON,
        selected = selected,
        trailing = {
            when {
                row.syncing -> Spinner(Modifier.size(16.dp))
                row.tone != SliceTone.TONE_NEUTRAL -> StatusDot(row.tone)
                else -> Unit
            }
        },
        onClick = onClick,
    )
}
