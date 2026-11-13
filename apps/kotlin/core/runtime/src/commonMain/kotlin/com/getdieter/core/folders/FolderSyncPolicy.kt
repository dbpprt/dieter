package com.getdieter.core.folders

import com.getdieter.core.v1.FolderBackgroundSync
import com.getdieter.core.v1.FolderDeviceSettings
import com.getdieter.core.v1.FolderDirection
import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderNetworkPolicy
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

/** What started a run. */
enum class FolderTrigger {
    /** A scheduled background window. */
    BACKGROUND,
    /** Dieter came to the foreground. */
    OPENED,
    /** A foreground scan while Dieter is open (upload my changes right away). */
    LOCAL_CHANGE,
    /** The home daemon's head moved while Dieter is open (keep in sync live). */
    LIVE,
    /** The person tapped Sync now or asked for a file. */
    MANUAL,
}

/** Why a run does not happen now. */
enum class FolderSkip {
    SYNC_OFF,
    PAUSED,
    /** The trigger is off in the settings (e.g. background sync only while open). */
    NOT_SCHEDULED,
    NO_NETWORK,
    WAITING_FOR_WIFI,
    ROAMING,
    DATA_SAVER,
    WAITING_FOR_CHARGING,
    POWER_SAVER,
    LOW_BATTERY,
}

/** One decision per run. */
sealed interface FolderRunDecision {
    /** Everything may move. */
    data object RunAll : FolderRunDecision

    /** Only files up to [maxBytes] move; [reason] says why larger ones wait. */
    data class SmallOnly(val maxBytes: Long, val reason: String) : FolderRunDecision

    data class Skip(val skip: FolderSkip, val reason: String) : FolderRunDecision
}

/**
 * Turns the device settings, a folder's overrides and the device's conditions into one decision per
 * run (§3.14). Pure; the platform's scheduler expresses what it can and the core re-checks the rest
 * at run time.
 */
object FolderSyncPolicy {
    fun decide(
        device: FolderDeviceSettings,
        folder: FolderLocalSettings?,
        conditions: FolderConditions,
        trigger: FolderTrigger,
        platform: String,
    ): FolderRunDecision {
        fun skip(skip: FolderSkip) =
            FolderRunDecision.Skip(skip, reason(skip, platform, device.pause_below_percent))
        if (!device.enabled) return skip(FolderSkip.SYNC_OFF)
        if (folder?.direction == FolderDirection.FOLDER_DIRECTION_PAUSED)
            return skip(FolderSkip.PAUSED)
        val scheduled =
            when (trigger) {
                FolderTrigger.MANUAL -> true
                FolderTrigger.BACKGROUND ->
                    device.background == FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL
                FolderTrigger.OPENED ->
                    device.background != FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL &&
                        device.sync_when_opened
                FolderTrigger.LOCAL_CHANGE ->
                    device.background != FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL &&
                        device.upload_right_away
                FolderTrigger.LIVE ->
                    device.background != FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL &&
                        device.live_sync
            }
        if (!scheduled) return skip(FolderSkip.NOT_SCHEDULED)
        val network = FolderSettings.network(device, folder)
        when (conditions.network) {
            FolderNetwork.NONE -> return skip(FolderSkip.NO_NETWORK)
            FolderNetwork.METERED -> {
                if (network == FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNMETERED)
                    return skip(FolderSkip.WAITING_FOR_WIFI)
                if (device.never_roaming && conditions.roaming && platform != "ios")
                    return skip(FolderSkip.ROAMING)
                if (device.respect_data_saver && conditions.dataSaver)
                    return skip(FolderSkip.DATA_SAVER)
            }
            FolderNetwork.UNMETERED -> Unit
        }
        if (device.respect_data_saver && conditions.constrained) return skip(FolderSkip.DATA_SAVER)
        // The person asked: power settings do not hold back Sync now.
        if (trigger != FolderTrigger.MANUAL) {
            if (device.only_while_charging && !conditions.charging)
                return skip(FolderSkip.WAITING_FOR_CHARGING)
            if (device.pause_in_power_saver && conditions.powerSaver)
                return skip(FolderSkip.POWER_SAVER)
            if (
                device.pause_below_percent > 0 &&
                    !conditions.charging &&
                    conditions.batteryPercent in 0 until device.pause_below_percent
            )
                return skip(FolderSkip.LOW_BATTERY)
        }
        if (
            conditions.network == FolderNetwork.METERED &&
                network == FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY_LARGE_ON_UNMETERED
        )
            return FolderRunDecision.SmallOnly(
                device.large_file_bytes,
                "Files over ${FolderSettings.size(device.large_file_bytes)} wait for Wi-Fi",
            )
        return FolderRunDecision.RunAll
    }

    /** The status line of [skip], worded for [platform]. */
    fun reason(skip: FolderSkip, platform: String, pauseBelowPercent: Int): String =
        when (skip) {
            FolderSkip.SYNC_OFF -> "Folder sync is off"
            FolderSkip.PAUSED -> "Paused"
            FolderSkip.NOT_SCHEDULED -> "Waiting for the next sync"
            FolderSkip.NO_NETWORK -> "Waiting for a network"
            FolderSkip.WAITING_FOR_WIFI -> "Waiting for Wi-Fi"
            FolderSkip.ROAMING -> "Paused while roaming"
            FolderSkip.DATA_SAVER ->
                if (platform == "ios") "Paused: Low Data Mode" else "Paused: Data Saver"
            FolderSkip.WAITING_FOR_CHARGING -> "Waiting for charging"
            FolderSkip.POWER_SAVER ->
                if (platform == "ios") "Paused: Low Power Mode" else "Paused: Battery Saver"
            FolderSkip.LOW_BATTERY -> "Paused: battery below $pauseBelowPercent%"
        }

    /**
     * Whether a download of [size] bytes fits: this device's folders use [usedBytes] of the storage
     * limit, and the volume keeps the free space the settings ask for. [onDemand] downloads (a tap)
     * ignore the limit but never the free space.
     */
    fun fitsStorage(
        device: FolderDeviceSettings,
        usedBytes: Long,
        freeBytes: Long,
        size: Long,
        onDemand: Boolean = false,
    ): Boolean {
        if (
            !onDemand &&
                device.storage_limit_bytes > 0 &&
                usedBytes + size > device.storage_limit_bytes
        )
            return false
        return device.keep_free_bytes <= 0 || freeBytes - size >= device.keep_free_bytes
    }

    const val STORAGE_FULL = "Storage limit reached"

    /**
     * The periodic window to schedule for [folders] on this device: the shortest active interval
     * with the constraints the platform can express; null when nothing should run in the
     * background.
     */
    fun schedule(
        device: FolderDeviceSettings,
        folders: List<FolderLocalSettings>,
    ): FolderScheduleRequest? {
        if (!device.enabled) return null
        if (device.background != FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL) return null
        val active = folders.filter { it.direction != FolderDirection.FOLDER_DIRECTION_PAUSED }
        if (active.isEmpty()) return null
        val minutes =
            active
                .minOf { FolderSettings.intervalMinutes(device, it) }
                .coerceAtLeast(FolderSettings.MINIMUM_INTERVAL_MINUTES)
        return FolderScheduleRequest(
            interval = minutes.minutes,
            unmeteredOnly =
                active.all {
                    FolderSettings.network(device, it) ==
                        FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNMETERED
                },
            notRoaming = device.never_roaming,
            requiresCharging = device.only_while_charging,
            batteryNotLow = device.pause_below_percent > 0,
            storageNotLow = device.keep_free_bytes > 0,
        )
    }

    /** When the next background run is due, estimated from the last attempt; null if none. */
    fun nextSync(
        device: FolderDeviceSettings,
        folders: List<FolderLocalSettings>,
        lastAttempt: Instant?,
        now: Instant,
    ): Instant? {
        val request = schedule(device, folders) ?: return null
        val due = (lastAttempt ?: now) + request.interval
        return if (due < now) now else due
    }
}
