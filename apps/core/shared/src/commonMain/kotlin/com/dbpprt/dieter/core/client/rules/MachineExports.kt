package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.GPUVendor
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.client.v1.MachineOperationCopy
import com.dbpprt.dieter.core.admin.MachineOperations
import com.dbpprt.dieter.core.connection.Availability
import com.dbpprt.dieter.core.machines.MachineFormats
import kotlin.time.Instant

/**
 * Machine telemetry and connection wording with primitive inputs, as machine
 * views, lists, and connection status call them while rendering: the
 * time-relative parts of `SessionSlice` and its `MachineEntry` rows, and the
 * text of `MachineReadings.information`. Times are epoch milliseconds; 0
 * means unknown. Byte counts use `FormatExports.bytes`.
 */
object MachineExports {
    // --- Times ---

    /** "Last seen just now", "Last seen 8m ago", "… 3h ago", "… 2d ago"; "Last seen unknown" for a blank or unparseable RFC 3339 [lastSeenAt]. */
    fun lastSeen(lastSeenAt: String, nowMillis: Long): String = MachineFormats.lastSeen(lastSeenAt, Instant.fromEpochMilliseconds(nowMillis))

    /** "Last connected just now", "Last connected 5m ago", or "Last connected unknown". */
    fun lastConnected(atMillis: Long, nowMillis: Long): String =
        Availability.lastConnected(FormatExports.instant(atMillis), Instant.fromEpochMilliseconds(nowMillis))

    /** "Updated just now", "Updated 5m ago", or "Waiting for first update", e.g. for `FeedStatus.last_applied_at_millis`. */
    fun updated(atMillis: Long, nowMillis: Long): String =
        Availability.updated(FormatExports.instant(atMillis), Instant.fromEpochMilliseconds(nowMillis))

    // --- Telemetry ---

    /** "38%", rounded half up. */
    fun percentage(value: Double): String = MachineFormats.percentage(value)

    /** "12 cores · load 1.2 / 0.8 / 0.5". */
    fun load(cores: Int, load1: Double, load5: Double, load15: Double): String = MachineFormats.load(cores, load1, load5, load15)

    /** "Mac16,1 · M4 Max  ·  macOS 26.1  ·  up 1h 1m", leaving out what is blank. */
    fun subtitle(hardwareModel: String, processor: String, osName: String, osVersion: String, uptimeSeconds: Long): String =
        MachineFormats.subtitle(hardwareModel, processor, osName, osVersion, uptimeSeconds)

    /** "1 device", "2 devices", "3 processes": [noun] when [count] is 1, else [plural]. */
    fun count(count: Int, noun: String, plural: String): String = MachineFormats.count(count, noun, plural)

    /** "2 agents active". */
    fun activeAgents(agents: Int): String = MachineFormats.activeAgents(agents)

    /** "3 GB / 24 GB unified", "3 GB VRAM", "8 GB VRAM"; a negative [usedBytes] or [totalBytes] is unknown. */
    fun gpuMemory(unified: Boolean, usedBytes: Long, totalBytes: Long): String =
        MachineFormats.gpuMemory(unified, usedBytes.takeIf { it >= 0 }, totalBytes.takeIf { it >= 0 })

    /** "Apple", "NVIDIA", or "AMD" for a `GPUVendor` value; "" otherwise. */
    fun gpuVendor(vendor: Int): String = GPUVendor.fromValue(vendor)?.let(MachineFormats::gpuVendor).orEmpty()

    /** "41°C". */
    fun temperature(celsius: Double): String = MachineFormats.temperature(celsius)

    /** "45 W". */
    fun power(watts: Double): String = MachineFormats.power(watts)

    /** "120 GB free". */
    fun disk(freeBytes: Long): String = MachineFormats.disk(freeBytes)

    /** "↓ 1.2 MB/s · ↑ 0 B/s". */
    fun network(receiveBytesPerSecond: Double, sendBytesPerSecond: Double): String = MachineFormats.network(receiveBytesPerSecond, sendBytesPerSecond)

    /** "pid 412 · harness worker". */
    fun processDetail(pid: Int, detail: String): String = MachineFormats.processDetail(pid, detail)

    /** "0.4.340 · 0123456789", e.g. for the gateway's build; "Unknown" without a release. */
    fun version(version: String, revision: String): String = MachineFormats.version(version, revision)

    /** The daemon row: its build's release, else the release the gateway reports, with the build's short revision. */
    fun daemonVersion(buildVersion: String, releaseVersion: String, revision: String): String =
        MachineFormats.daemonVersion(buildVersion, releaseVersion, revision)

    // --- Operations ---

    /** How a `MachineOperationAction` value reads in the actions menu and its confirmation; empty for an unknown action. */
    fun operationCopy(action: Int): MachineOperationCopy {
        val copy = MachineOperations.copy(MachineOperationAction.fromValue(action) ?: MachineOperationAction.MACHINE_OPERATION_ACTION_UNSPECIFIED)
        return MachineOperationCopy(title = copy.title, button = copy.button, menu_title = copy.menuTitle, explanation = copy.explanation, destructive = copy.destructive)
    }
}
