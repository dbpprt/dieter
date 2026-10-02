package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.GPUVendor
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.client.v1.MachineOperationCopy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Instant

class MachineExportsTest {
    private val now = Instant.parse("2026-08-18T15:00:00Z").toEpochMilliseconds()
    private val minute = 60_000L

    @Test
    fun relativeTimesTreatZeroAsUnknown() {
        assertEquals("Last seen 8m ago", MachineExports.lastSeen("2026-08-18T14:52:00Z", now))
        assertEquals("Last seen unknown", MachineExports.lastSeen("", now))
        assertEquals("Last connected unknown", MachineExports.lastConnected(0, now))
        assertEquals("Last connected 5m ago", MachineExports.lastConnected(now - 5 * minute, now))
        assertEquals("Waiting for first update", MachineExports.updated(0, now))
        assertEquals("Updated just now", MachineExports.updated(now - 30_000, now))
        assertEquals("Updated 6m ago", MachineExports.updated(now - 6 * minute, now))
    }

    @Test
    fun telemetryWordingMatchesTheCoreFormats() {
        assertEquals("38%", MachineExports.percentage(37.6))
        assertEquals("8 cores · load 1.5 / 0.8 / 0.3", MachineExports.load(8, 1.5, 0.75, 0.25))
        assertEquals("Mac16,1 · M4 Max  ·  macOS 26.1  ·  up 1h 1m", MachineExports.subtitle("Mac16,1", "M4 Max", "macOS", "26.1", 3_700))
        assertEquals("1 device", MachineExports.count(1, "device", "devices"))
        assertEquals("3 processes", MachineExports.count(3, "process", "processes"), "the plural is explicit")
        assertEquals("2 agents active", MachineExports.activeAgents(2))
        assertEquals("41°C", MachineExports.temperature(41.0))
        assertEquals("45 W", MachineExports.power(45.0))
        assertEquals("512 B free", MachineExports.disk(512))
        assertEquals("↓ 0 B/s · ↑ 1.2 MB/s", MachineExports.network(0.0, 1_250_000.0))
        assertEquals("pid 7 · daemon", MachineExports.processDetail(7, "daemon"))
        assertEquals("0.4.340 · 0123456789", MachineExports.version("0.4.340", "0123456789abcdef"))
        assertEquals("0.4.340", MachineExports.daemonVersion("", "0.4.340", ""))
    }

    @Test
    fun gpuValuesUseNegativeForUnknownAndEnumNumbers() {
        assertEquals("2.0 GB / 24.0 GB unified", MachineExports.gpuMemory(unified = true, usedBytes = 2L shl 30, totalBytes = 24L shl 30))
        assertEquals("2.0 GB VRAM", MachineExports.gpuMemory(unified = false, usedBytes = 2L shl 30, totalBytes = -1))
        assertEquals("8.0 GB VRAM", MachineExports.gpuMemory(unified = false, usedBytes = -1, totalBytes = 8L shl 30))
        assertEquals("NVIDIA", MachineExports.gpuVendor(GPUVendor.GPU_VENDOR_NVIDIA.value))
        assertEquals("", MachineExports.gpuVendor(GPUVendor.GPU_VENDOR_UNSPECIFIED.value))
        assertEquals("", MachineExports.gpuVendor(99))
    }

    @Test
    fun operationCopyTravelsAsAMessage() {
        val restart = MachineExports.operationCopy(MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART.value)
        assertEquals("Restart machine", restart.title)
        assertEquals("Restart", restart.button)
        assertEquals("Restart…", restart.menu_title)
        assertTrue(restart.destructive)
        assertEquals(MachineOperationCopy(), MachineExports.operationCopy(99))
    }
}
