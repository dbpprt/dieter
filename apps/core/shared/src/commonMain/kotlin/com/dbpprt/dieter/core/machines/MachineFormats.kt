package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.v1.GPUDevice
import com.dbpprt.dieter.api.v1.GPUMemoryKind
import com.dbpprt.dieter.api.v1.GPUVendor
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.core.presentation.ByteSizes
import com.dbpprt.dieter.core.presentation.TokenCounts
import kotlin.math.roundToLong

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

    /** "12 cores · load 1.2 / 0.8 / 0.5". */
    fun load(information: MachineInformation): String =
        "${information.logical_cpu_count} cores · load ${TokenCounts.format1(information.load_1)} / ${TokenCounts.format1(information.load_5)} / ${TokenCounts.format1(information.load_15)}"

    /** Hardware, OS, and uptime; before information arrives, whether it is loading. */
    fun subtitle(row: MachineRow, information: MachineInformation?): String {
        if (information == null) return if (row.online) "Loading machine information…" else row.detail
        val hardware = listOf(information.hardware_model, information.processor).filter(String::isNotBlank).joinToString(" · ")
        val os = listOf(information.os_name, information.os_version).filter(String::isNotBlank).joinToString(" ")
        return listOf(hardware, os, "up ${uptime(information.uptime_seconds)}").filter(String::isNotBlank).joinToString("  ·  ")
    }

    fun gpuVendor(vendor: GPUVendor): String? = when (vendor) {
        GPUVendor.GPU_VENDOR_APPLE -> "Apple"
        GPUVendor.GPU_VENDOR_NVIDIA -> "NVIDIA"
        GPUVendor.GPU_VENDOR_AMD -> "AMD"
        else -> null
    }

    /** "3 GB / 24 GB unified" or "8 GB VRAM". */
    fun gpuMemory(device: GPUDevice): String {
        val label = if (device.memory_kind == GPUMemoryKind.GPU_MEMORY_KIND_UNIFIED) "unified" else "VRAM"
        val used = device.memory_used_bytes
        val total = device.memory_total_bytes
        return when {
            used != null && total != null -> "${bytes(used)} / ${bytes(total)} $label"
            used != null -> "${bytes(used)} $label"
            else -> "${bytes(total ?: 0)} $label"
        }
    }

    /** The first ten characters of a known source revision. */
    fun shortRevision(value: String): String? = value.takeIf { it.isNotBlank() && it != "unknown" }?.take(10)
}
