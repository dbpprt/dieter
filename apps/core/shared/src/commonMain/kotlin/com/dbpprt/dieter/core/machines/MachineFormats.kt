package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.v1.GPUDevice
import com.dbpprt.dieter.api.v1.GPUMemoryKind
import com.dbpprt.dieter.api.v1.GPUTelemetry
import com.dbpprt.dieter.api.v1.GPUVendor
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.core.presentation.Ages
import com.dbpprt.dieter.core.presentation.ByteSizes
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.presentation.TokenCounts
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.math.roundToLong
import kotlin.time.Instant

/** How machine telemetry reads, independent of the device locale. */
object MachineFormats {
    fun bytes(value: Long): String = ByteSizes.format(value)

    fun rate(bytesPerSecond: Double): String = if (bytesPerSecond <= 0) "0 B/s" else "${bytes(bytesPerSecond.roundToLong())}/s"

    /** "14d 6h", "2h 41m", or "12m". */
    fun uptime(seconds: Long): String {
        val safe = seconds.coerceAtLeast(0)
        val days = safe / 86_400
        val hours = (safe % 86_400) / 3_600
        val minutes = (safe % 3_600) / 60
        return when {
            days > 0 -> "${days}d ${hours}h"
            hours > 0 -> "${hours}h ${minutes}m"
            else -> "${minutes}m"
        }
    }

    fun percentage(value: Double): String = "${value.roundToLong()}%"

    /** "1 device", "2 devices", "3 processes": [count] and [noun], or [plural] unless [count] is 1. */
    fun count(count: Int, noun: String, plural: String = "${noun}s"): String = Counts.of(count, noun, plural)

    /** "12 cores · load 1.2 / 0.8 / 0.5". */
    fun load(information: MachineInformation): String =
        load(information.logical_cpu_count, information.load_1, information.load_5, information.load_15)

    /** "12 cores · load 1.2 / 0.8 / 0.5". */
    fun load(cores: Int, load1: Double, load5: Double, load15: Double): String =
        "$cores cores · load ${TokenCounts.format1(load1)} / ${TokenCounts.format1(load5)} / ${TokenCounts.format1(load15)}"

    /** Hardware, OS, and uptime; before information arrives, whether it is loading. */
    fun subtitle(row: MachineRow, information: MachineInformation?): String {
        if (information == null) return if (row.online) "Loading machine information…" else row.detail
        return subtitle(information.hardware_model, information.processor, information.os_name, information.os_version, information.uptime_seconds)
    }

    /** "Mac16,1 · M4 Max  ·  macOS 26.1  ·  up 1h 1m", leaving out what is blank. */
    fun subtitle(hardwareModel: String, processor: String, osName: String, osVersion: String, uptimeSeconds: Long): String {
        val hardware = listOf(hardwareModel, processor).filter(String::isNotBlank).joinToString(" · ")
        return listOf(hardware, operatingSystem(osName, osVersion), "up ${uptime(uptimeSeconds)}").filter(String::isNotBlank).joinToString("  ·  ")
    }

    fun gpuVendor(vendor: GPUVendor): String? = when (vendor) {
        GPUVendor.GPU_VENDOR_APPLE -> "Apple"
        GPUVendor.GPU_VENDOR_NVIDIA -> "NVIDIA"
        GPUVendor.GPU_VENDOR_AMD -> "AMD"
        else -> null
    }

    /** The device's name, else "GPU". */
    fun gpuName(device: GPUDevice): String = device.name.ifBlank { "GPU" }

    /** "AMD · gpu-0 · driver 24.1", leaving out what is unknown. */
    fun gpuDetail(device: GPUDevice): String =
        listOfNotNull(gpuVendor(device.vendor), device.id.takeIf(String::isNotBlank), device.driver_version.takeIf(String::isNotBlank)?.let { "driver $it" }).joinToString(" · ")

    /** "21%", or "—" when the device does not report its utilization. */
    fun gpuUtilization(device: GPUDevice): String = device.utilization_percent?.let { percentage(it) } ?: "—"

    /** Why a machine reports no GPU devices: its own reason, else that none is supported. */
    fun gpuUnavailable(gpu: GPUTelemetry): String = gpu.unavailable_reason.ifBlank { "No supported GPU telemetry is available." }

    /** "3 GB / 24 GB unified" or "8 GB VRAM". */
    fun gpuMemory(device: GPUDevice): String =
        gpuMemory(device.memory_kind == GPUMemoryKind.GPU_MEMORY_KIND_UNIFIED, device.memory_used_bytes, device.memory_total_bytes)

    /** "3 GB / 24 GB unified", "3 GB VRAM" with only [used], "8 GB VRAM" with only [total]; null reads unknown. */
    fun gpuMemory(unified: Boolean, used: Long?, total: Long?): String {
        val label = if (unified) "unified" else "VRAM"
        return when {
            used != null && total != null -> "${bytes(used)} / ${bytes(total)} $label"
            used != null -> "${bytes(used)} $label"
            else -> "${bytes(total ?: 0)} $label"
        }
    }

    /** "41°C". */
    fun temperature(celsius: Double): String = "${celsius.roundToLong()}°C"

    /** "45 W". */
    fun power(watts: Double): String = "${watts.roundToLong()} W"

    /** "120 GB free". */
    fun disk(freeBytes: Long): String = "${bytes(freeBytes)} free"

    /** "↓ 1.2 MB/s · ↑ 0 B/s". */
    fun network(receiveBytesPerSecond: Double, sendBytesPerSecond: Double): String = "↓ ${rate(receiveBytesPerSecond)} · ↑ ${rate(sendBytesPerSecond)}"

    /** "2 agents active". */
    fun activeAgents(agents: Int): String = "${count(agents, "agent")} active"

    /** "pid 412 · harness worker"; just the pid without a [detail]. */
    fun processDetail(pid: Int, detail: String): String = processDetail(pid.toLong(), detail)

    /** "pid 412 · harness worker" for the 64-bit pid a daemon reports. */
    fun processDetail(pid: Long, detail: String): String = if (detail.isBlank()) "pid $pid" else "pid $pid · $detail"

    /** The first ten characters of a known source revision. */
    fun shortRevision(value: String): String? = value.takeIf { it.isNotBlank() && it != "unknown" }?.take(10)

    /** "0.4.340 · 0123456789": a release and its short revision; "Unknown" without a release. */
    fun version(version: String, revision: String): String = listOfNotNull(version.ifBlank { "Unknown" }, shortRevision(revision)).joinToString(" · ")

    /** The daemon's own build release, else the release the gateway reports for it, with the build's revision. */
    fun daemonVersion(buildVersion: String, releaseVersion: String, revision: String): String = version(buildVersion.ifBlank { releaseVersion }, revision)

    /** Why [row]'s information is missing: the read's [error], else that an online machine sent none, else the row's detail. */
    fun informationUnavailable(row: MachineRow, error: String?): String = informationUnavailable(row.online, row.detail, error)

    /** Why a machine's information is missing: the read's [error], else that an [online] machine sent none, else its [detail]. */
    fun informationUnavailable(online: Boolean, detail: String, error: String?): String =
        error?.takeIf(String::isNotBlank) ?: if (online) "Machine information is unavailable." else detail

    /** "64.0 GB total · 12.0 GB cached · 1.0 GB swap". */
    fun memory(totalBytes: Long, cachedBytes: Long, swapBytes: Long): String = "${bytes(totalBytes)} total · ${bytes(cachedBytes)} cached · ${bytes(swapBytes)} swap"

    /** "macOS 26.1", leaving out what is blank. */
    fun operatingSystem(osName: String, osVersion: String): String = listOf(osName, osVersion).filter(String::isNotBlank).joinToString(" ")

    /** A Dieter process that runs an agent, as opposed to a tool or terminal. */
    fun isAgentProcess(kind: String): Boolean = kind == "agent"

    /** "Last seen just now", "Last seen 8m ago", "… 3h ago", "… 2d ago"; "Last seen unknown" when [lastSeenAt] does not parse. */
    fun lastSeen(lastSeenAt: String, now: Instant): String {
        val at = Timestamps.parse(lastSeenAt) ?: return "Last seen unknown"
        return "Last seen " + Ages.ago(at, now)
    }
}
