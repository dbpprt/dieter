package com.getdieter.core.folders

import com.getdieter.api.v1.FolderMode
import com.getdieter.core.presentation.ByteSizes
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.FolderBackgroundSync
import com.getdieter.core.v1.FolderDeviceSettings
import com.getdieter.core.v1.FolderDirection
import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderNetworkPolicy
import com.getdieter.core.v1.FolderSyncSettings

/** Folder sync settings: device defaults and per-folder overrides, kept on this device only. */
object FolderSettings {
    const val MB = 1L shl 20
    const val GB = 1L shl 30

    /** The defaults of §3.15: hourly, unmetered networks, 25 MB downloads, a 2 GB limit. */
    val DEFAULTS =
        FolderDeviceSettings(
            enabled = true,
            background = FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL,
            interval_minutes = 60,
            sync_when_opened = true,
            upload_right_away = true,
            live_sync = true,
            network = FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNMETERED,
            large_file_bytes = 25 * MB,
            respect_data_saver = true,
            never_roaming = true,
            only_while_charging = false,
            pause_in_power_saver = true,
            pause_below_percent = 20,
            auto_download_bytes = 25 * MB,
            storage_limit_bytes = 2 * GB,
            keep_free_bytes = 1 * GB,
            notify_conflicts = true,
            notify_attention = true,
            notify_finished = false,
        )

    /** The shortest background interval each platform schedules. */
    const val MINIMUM_INTERVAL_MINUTES = 15

    /** [settings] with every value inside its bounds. */
    fun normalized(settings: FolderDeviceSettings): FolderDeviceSettings =
        settings.copy(
            background =
                settings.background.takeIf {
                    it != FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_UNSPECIFIED
                } ?: FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL,
            interval_minutes =
                settings.interval_minutes
                    .takeIf { it > 0 }
                    ?.coerceIn(MINIMUM_INTERVAL_MINUTES, 1440) ?: DEFAULTS.interval_minutes,
            network =
                settings.network.takeIf {
                    it != FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNSPECIFIED
                } ?: DEFAULTS.network,
            large_file_bytes =
                settings.large_file_bytes.takeIf { it > 0 } ?: DEFAULTS.large_file_bytes,
            pause_below_percent = settings.pause_below_percent.coerceIn(0, 100),
            storage_limit_bytes = settings.storage_limit_bytes.coerceAtLeast(0),
            keep_free_bytes = settings.keep_free_bytes.coerceAtLeast(0),
        )

    fun mode(direction: FolderDirection): FolderMode =
        when (direction) {
            FolderDirection.FOLDER_DIRECTION_DOWNLOAD_ONLY -> FolderMode.FOLDER_MODE_RECEIVE_ONLY
            FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY -> FolderMode.FOLDER_MODE_SEND_ONLY
            else -> FolderMode.FOLDER_MODE_TWO_WAY
        }

    fun directionLabel(direction: FolderDirection): String =
        when (direction) {
            FolderDirection.FOLDER_DIRECTION_DOWNLOAD_ONLY -> "Download only"
            FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY -> "Upload only"
            FolderDirection.FOLDER_DIRECTION_PAUSED -> "Paused"
            else -> "Two-way"
        }

    fun modeLabel(mode: FolderMode): String =
        when (mode) {
            FolderMode.FOLDER_MODE_SEND_ONLY -> "Upload only"
            FolderMode.FOLDER_MODE_RECEIVE_ONLY -> "Download only"
            else -> "Two-way"
        }

    /** The background interval [folder] uses: its override, else the device's. */
    fun intervalMinutes(device: FolderDeviceSettings, folder: FolderLocalSettings?): Int =
        folder?.interval_minutes?.takeIf { it > 0 }?.coerceAtLeast(MINIMUM_INTERVAL_MINUTES)
            ?: device.interval_minutes

    fun network(device: FolderDeviceSettings, folder: FolderLocalSettings?): FolderNetworkPolicy =
        folder?.network?.takeIf { it != FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNSPECIFIED }
            ?: device.network

    /** Files up to this size download automatically; 0 none, negative every file. */
    fun autoDownloadBytes(device: FolderDeviceSettings, folder: FolderLocalSettings?): Long =
        if (folder?.auto_download_override == true) folder.auto_download_bytes
        else device.auto_download_bytes

    fun downloadsAutomatically(limit: Long, size: Long): Boolean = limit < 0 || size <= limit

    /** Interval choices, worded per platform (iOS schedules its own times). */
    fun intervalOptions(platform: String): List<Pair<Int, String>> =
        if (platform == "ios")
            listOf(
                15 to "Often",
                60 to "About hourly",
                360 to "About every 6 hours",
                1440 to "Daily",
            )
        else
            listOf(
                15 to "Every 15 min",
                30 to "Every 30 min",
                60 to "Every hour",
                360 to "Every 6 hours",
                720 to "Every 12 hours",
                1440 to "Every 24 hours",
            )

    /** The network choices, in the order Settings offers them. */
    val NETWORK_OPTIONS =
        listOf(
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNMETERED,
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY,
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY_LARGE_ON_UNMETERED,
        )

    fun networkLabel(policy: FolderNetworkPolicy): String =
        when (policy) {
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY -> "Any network"
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY_LARGE_ON_UNMETERED ->
                "Any network, large files on Wi-Fi only"
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNSPECIFIED -> "Use device setting"
            else -> "Wi-Fi and unmetered only"
        }

    /** A segmented control's label of [policy]: "Wi-Fi only", "Any", "Large on Wi-Fi". */
    fun networkShortLabel(policy: FolderNetworkPolicy): String =
        when (policy) {
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY -> "Any"
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY_LARGE_ON_UNMETERED -> "Large on Wi-Fi"
            else -> "Wi-Fi only"
        }

    /** The direction choices of a folder on this device, in order. */
    val DIRECTION_OPTIONS =
        listOf(
            FolderDirection.FOLDER_DIRECTION_TWO_WAY,
            FolderDirection.FOLDER_DIRECTION_DOWNLOAD_ONLY,
            FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY,
            FolderDirection.FOLDER_DIRECTION_PAUSED,
        )

    /** A segmented control's label of [direction]: "Two-way", "Download", "Upload", "Paused". */
    fun directionShortLabel(direction: FolderDirection): String =
        when (direction) {
            FolderDirection.FOLDER_DIRECTION_DOWNLOAD_ONLY -> "Download"
            FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY -> "Upload"
            FolderDirection.FOLDER_DIRECTION_PAUSED -> "Paused"
            else -> "Two-way"
        }

    /** What [direction] means, under its control. */
    fun directionDetail(direction: FolderDirection): String =
        when (direction) {
            FolderDirection.FOLDER_DIRECTION_DOWNLOAD_ONLY ->
                "Changes from your machines arrive here; changes made here are not sent."
            FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY ->
                "Files added here go to your machines; their changes are not applied here."
            FolderDirection.FOLDER_DIRECTION_PAUSED -> "Nothing syncs until you resume it."
            else -> "Changes go both ways."
        }

    /** The trash choices of a folder, in days as an update sends them; -1 turns it off. */
    val TRASH_DAY_OPTIONS = listOf(-1, 7, 30, 90)

    /** [days] of a folder's definition (0 is off) as [TRASH_DAY_OPTIONS] name them. */
    fun trashOption(days: Int): Int = if (days <= 0) -1 else days

    val LARGE_FILE_OPTIONS = listOf(10 * MB, 25 * MB, 100 * MB)
    val BATTERY_OPTIONS = listOf(10L, 20L, 30L, 0L)
    val AUTO_DOWNLOAD_OPTIONS = listOf(10 * MB, 25 * MB, 100 * MB, 1 * GB, -1L, 0L)
    val STORAGE_OPTIONS = listOf(1 * GB, 2 * GB, 5 * GB, 10 * GB, 25 * GB, 0L)
    val KEEP_FREE_OPTIONS = listOf(1 * GB, 0L)

    /** "25 MB", "1.5 GB": binary units without a trailing ".0". */
    fun size(bytes: Long): String = ByteSizes.format(bytes).replace(".0 ", " ")

    fun autoDownloadLabel(bytes: Long): String =
        when {
            bytes < 0 -> "All files"
            bytes == 0L -> "Nothing (on demand only)"
            else -> "Files up to ${size(bytes)}"
        }

    fun storageLabel(bytes: Long): String = if (bytes <= 0) "No limit" else size(bytes)

    fun keepFreeLabel(bytes: Long): String =
        if (bytes <= 0) "Off" else "Keep at least ${size(bytes)} free"

    fun batteryLabel(percent: Long): String = if (percent <= 0) "Never" else "Pause below $percent%"
}

/**
 * The device's [FolderSyncSettings] record in [storage] (the account's namespace). Absent, the
 * defaults apply and no folder is on this device.
 */
class FolderSettingsStore(private val storage: CoreStorage) {
    private var cached: FolderSyncSettings? = null

    fun load(): FolderSyncSettings =
        cached
            ?: (storage.read(NAME)?.let {
                    runCatching { FolderSyncSettings.ADAPTER.decode(it) }.getOrNull()
                } ?: FolderSyncSettings())
                .let { stored ->
                    stored.copy(
                        device =
                            if (stored.saved && stored.device != null)
                                FolderSettings.normalized(stored.device!!)
                            else FolderSettings.DEFAULTS
                    )
                }
                .also { cached = it }

    fun device(): FolderDeviceSettings = load().device ?: FolderSettings.DEFAULTS

    fun folder(folderId: String): FolderLocalSettings? =
        load().folders.firstOrNull { it.folder_id == folderId }

    fun setDevice(settings: FolderDeviceSettings) =
        save(load().copy(device = FolderSettings.normalized(settings)))

    /** Adds or replaces [settings] for its folder. */
    fun putFolder(settings: FolderLocalSettings) =
        save(
            load().let { current ->
                current.copy(
                    folders =
                        current.folders.filter { it.folder_id != settings.folder_id } + settings
                )
            }
        )

    fun removeFolder(folderId: String) =
        save(load().let { it.copy(folders = it.folders.filter { f -> f.folder_id != folderId }) })

    /** Cellular data used in [month] ("2026-11"); a new month starts from zero. */
    fun cellular(month: String): Long =
        load().let {
            if (it.cellular_month == month) it.cellular_bytes else 0
        }

    /** Counts [bytes] of cellular data toward [month]. */
    fun addCellular(month: String, bytes: Long) {
        if (bytes <= 0) return
        save(
            load().let {
                if (it.cellular_month == month) it.copy(cellular_bytes = it.cellular_bytes + bytes)
                else it.copy(cellular_month = month, cellular_bytes = bytes)
            }
        )
    }

    private fun save(settings: FolderSyncSettings) {
        val saved = settings.copy(saved = true)
        storage.write(NAME, FolderSyncSettings.ADAPTER.encode(saved))
        cached = saved
    }

    private companion object {
        const val NAME = "settings.pb"
    }
}
