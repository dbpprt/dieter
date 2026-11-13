@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.folders

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.platform.rememberNotificationPermission
import com.getdieter.mobile.store.*

/**
 * Settings › Folder sync: this device's defaults for every folder kept here (§3.15) and its sync
 * status. The core supplies the choices, worded for the platform, and why sync would not run now.
 */
@Composable
internal fun FolderSyncScreen(store: MobileStore) {
    val slice by store.folders.settings.collectAsState()
    val settings = slice.settings ?: FolderDeviceSettings()
    val askNotifications = rememberNotificationPermission()
    var freeing by remember { mutableStateOf(false) }
    fun update(change: FolderDeviceSettings.() -> FolderDeviceSettings) =
        store.folders.setDeviceSettings(settings.change())
    fun sizes(options: List<FolderSizeOption>) = options.map { it.amount.toString() to it.label }
    fun selected(options: List<FolderSizeOption>, amount: Long) =
        options.firstOrNull { it.selected }?.label
            ?: options.firstOrNull { it.amount == amount }?.label.orEmpty()
    val enabled = settings.enabled && slice.device_capable
    Screen(ScreenChrome("Folder sync")) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("folder-sync-settings"),
            state = listState,
            contentPadding = padding,
        ) {
            if (!slice.device_capable)
                item("incapable") {
                    Banner(
                        "Not on this device",
                        "This device keeps no folders; your machines keep them.",
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                    )
                }
            item("master") {
                Spacer(Modifier.height(8.dp))
                ListRow(
                    "Folder sync",
                    position = Position.SINGLE,
                    subtitle =
                        if (slice.folders_on_device == 0) "No folder is on this device yet"
                        else if (slice.folders_on_device == 1) "1 folder on this device"
                        else "${slice.folders_on_device} folders on this device",
                    glyph = Glyph.SYNC,
                    tile = palette.info,
                    trailing = {
                        DSwitch(
                            settings.enabled,
                            { on -> update { copy(enabled = on) } },
                            Modifier.testTag("folder-sync-enabled"),
                            enabled = slice.device_capable,
                        )
                    },
                )
                if (slice.reason.isNotEmpty())
                    SectionFooter(slice.reason, Modifier.testTag("folder-sync-reason"))
            }
            item("background") {
                SectionHeader("Sync in the background")
                SettingsCell {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        slice.interval_options.forEach { option ->
                            val key =
                                if (
                                    option.background ==
                                        FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL
                                )
                                    option.minutes.toString()
                                else option.background.name.lowercase().substringAfterLast('_')
                            FilterPill(
                                option.label,
                                option.selected,
                                {
                                    if (enabled)
                                        update {
                                            copy(
                                                background = option.background,
                                                interval_minutes =
                                                    option.minutes.takeIf { it > 0 }
                                                        ?: interval_minutes,
                                            )
                                        }
                                },
                                Modifier.testTag("folder-sync-interval-$key"),
                            )
                        }
                    }
                    if (slice.background_caption.isNotEmpty())
                        Text(
                            slice.background_caption,
                            style = type.footnote,
                            color = palette.secondaryLabel,
                        )
                }
            }
            item("open") {
                SectionHeader("While Dieter is open")
                Group(listOf(0, 1, 2)) { index, position ->
                    val (title, checked) =
                        when (index) {
                            0 -> "Sync when opened" to settings.sync_when_opened
                            1 -> "Upload my changes right away" to settings.upload_right_away
                            else -> "Keep in sync live" to settings.live_sync
                        }
                    ListRow(
                        title,
                        position = position,
                        trailing = {
                            DSwitch(
                                checked,
                                { on ->
                                    update {
                                        when (index) {
                                            0 -> copy(sync_when_opened = on)
                                            1 -> copy(upload_right_away = on)
                                            else -> copy(live_sync = on)
                                        }
                                    }
                                },
                                Modifier.testTag("folder-sync-open-$index"),
                                enabled = enabled,
                            )
                        },
                    )
                }
            }
            item("network") {
                SectionHeader("Network")
                SettingsCell {
                    Segmented(
                        folderNetworks.map { it.shortLabel() },
                        folderNetworks.indexOf(settings.network).coerceAtLeast(0),
                        { if (enabled) update { copy(network = folderNetworks[it]) } },
                        testTagPrefix = "folder-sync-network",
                    )
                    Text(
                        settings.network.label(),
                        style = type.footnote,
                        color = palette.secondaryLabel,
                    )
                }
                Spacer(Modifier.height(8.dp))
                val rows =
                    listOfNotNull(
                        "large"
                            .takeIf {
                                settings.network ==
                                    FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY_LARGE_ON_UNMETERED
                            },
                        "saver",
                        "roaming".takeIf { slice.roaming_available },
                    )
                Group(rows) { row, position ->
                    when (row) {
                        "large" ->
                            PickerRow(
                                "Large file threshold",
                                selected(slice.large_file_options, settings.large_file_bytes),
                                sizes(slice.large_file_options),
                                settings.large_file_bytes.toString(),
                                enabled,
                                position,
                                tag = "folder-sync-large",
                            ) {
                                update { copy(large_file_bytes = it.toLong()) }
                            }
                        "saver" ->
                            ListRow(
                                slice.data_saver_label.ifEmpty { "Respect Data Saver" },
                                position = position,
                                trailing = {
                                    DSwitch(
                                        settings.respect_data_saver,
                                        { on -> update { copy(respect_data_saver = on) } },
                                        Modifier.testTag("folder-sync-data-saver"),
                                        enabled = enabled,
                                    )
                                },
                            )
                        else ->
                            ListRow(
                                "Never while roaming",
                                position = position,
                                trailing = {
                                    DSwitch(
                                        settings.never_roaming,
                                        { on -> update { copy(never_roaming = on) } },
                                        Modifier.testTag("folder-sync-roaming"),
                                        enabled = enabled,
                                    )
                                },
                            )
                    }
                }
            }
            item("power") {
                SectionHeader("Power")
                Group(listOf("charging", "saver", "battery")) { row, position ->
                    when (row) {
                        "charging" ->
                            ListRow(
                                "Only while charging",
                                position = position,
                                trailing = {
                                    DSwitch(
                                        settings.only_while_charging,
                                        { on -> update { copy(only_while_charging = on) } },
                                        Modifier.testTag("folder-sync-charging"),
                                        enabled = enabled,
                                    )
                                },
                            )
                        "saver" ->
                            ListRow(
                                slice.power_saver_label.ifEmpty { "Pause in Battery Saver" },
                                position = position,
                                trailing = {
                                    DSwitch(
                                        settings.pause_in_power_saver,
                                        { on -> update { copy(pause_in_power_saver = on) } },
                                        Modifier.testTag("folder-sync-power-saver"),
                                        enabled = enabled,
                                    )
                                },
                            )
                        else ->
                            PickerRow(
                                "Pause below",
                                selected(
                                    slice.battery_options,
                                    settings.pause_below_percent.toLong(),
                                ),
                                sizes(slice.battery_options),
                                settings.pause_below_percent.toString(),
                                enabled,
                                position,
                                tag = "folder-sync-battery",
                            ) {
                                update { copy(pause_below_percent = it.toInt()) }
                            }
                    }
                }
            }
            item("storage") {
                SectionHeader("Storage")
                Group(listOf("download", "limit", "free")) { row, position ->
                    when (row) {
                        "download" ->
                            PickerRow(
                                "Download automatically",
                                selected(slice.auto_download_options, settings.auto_download_bytes),
                                sizes(slice.auto_download_options),
                                settings.auto_download_bytes.toString(),
                                enabled,
                                position,
                                tag = "folder-sync-download",
                            ) {
                                update { copy(auto_download_bytes = it.toLong()) }
                            }
                        "limit" ->
                            PickerRow(
                                "Storage limit",
                                selected(slice.storage_options, settings.storage_limit_bytes),
                                sizes(slice.storage_options),
                                settings.storage_limit_bytes.toString(),
                                enabled,
                                position,
                                tag = "folder-sync-storage",
                            ) {
                                update { copy(storage_limit_bytes = it.toLong()) }
                            }
                        else ->
                            PickerRow(
                                "Free space",
                                selected(slice.keep_free_options, settings.keep_free_bytes),
                                sizes(slice.keep_free_options),
                                settings.keep_free_bytes.toString(),
                                enabled,
                                position,
                                tag = "folder-sync-keep-free",
                            ) {
                                update { copy(keep_free_bytes = it.toLong()) }
                            }
                    }
                }
                if (slice.used_label.isNotEmpty())
                    SectionFooter("${slice.used_label} used on this device")
                Spacer(Modifier.height(8.dp))
                ListRow(
                    "Free up space…",
                    Modifier.testTag("folder-sync-free-up"),
                    position = Position.SINGLE,
                    subtitle = "Remove downloaded files your machines keep; they stay listed",
                    glyph = Glyph.PULL,
                    glyphTint = palette.accent,
                    enabled = slice.folders_on_device > 0,
                    onClick = { freeing = true },
                )
            }
            item("notifications") {
                SectionHeader("Notifications")
                Group(listOf(0, 1, 2)) { index, position ->
                    val (title, subtitle, checked) =
                        when (index) {
                            0 -> Triple("Conflicts", null, settings.notify_conflicts)
                            1 ->
                                Triple(
                                    "Needs attention",
                                    "A held deletion, a lost location, a reached limit",
                                    settings.notify_attention,
                                )
                            else -> Triple("Sync finished", null, settings.notify_finished)
                        }
                    ListRow(
                        title,
                        position = position,
                        subtitle = subtitle,
                        trailing = {
                            DSwitch(
                                checked,
                                { on ->
                                    if (on) askNotifications()
                                    update {
                                        when (index) {
                                            0 -> copy(notify_conflicts = on)
                                            1 -> copy(notify_attention = on)
                                            else -> copy(notify_finished = on)
                                        }
                                    }
                                },
                                Modifier.testTag("folder-sync-notify-$index"),
                                enabled = slice.device_capable,
                            )
                        },
                    )
                }
            }
            item("status") {
                SectionHeader("Status")
                val rows =
                    listOf(
                        "Last sync" to slice.last_sync.ifEmpty { "Never" },
                        "Next sync" to slice.next_sync.ifEmpty { "Not scheduled" },
                        "Waiting" to slice.pending_label.ifEmpty { "Nothing" },
                        "Cellular this month" to
                            com.getdieter.core.folders.FolderSettings.size(slice.cellular_bytes),
                    )
                Group(rows) { (title, value), position ->
                    ListRow(
                        title,
                        Modifier.testTag(
                            "folder-sync-status-${title.lowercase().replace(' ', '-')}"
                        ),
                        position = position,
                        value = value,
                    )
                }
            }
        }
    }
    if (freeing)
        ConfirmDialog(
            "Free up space?",
            "Downloaded files your machines keep are removed from this device. They stay listed " +
                "and download again on tap.",
            "Free up space",
            {
                freeing = false
                store.folders.freeUpSpace()
            },
            { freeing = false },
        )
}
