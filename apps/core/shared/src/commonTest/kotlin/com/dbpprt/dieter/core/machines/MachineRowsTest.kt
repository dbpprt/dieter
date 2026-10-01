package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.api.gateway.v1.RemoteDesktopPresence
import com.dbpprt.dieter.api.v1.GPUDevice
import com.dbpprt.dieter.api.v1.GPUMemoryKind
import com.dbpprt.dieter.api.v1.GPUTelemetry
import com.dbpprt.dieter.api.v1.GPUVendor
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.api.v1.PeerSyncDiagnostic
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.session.MachineRoute
import com.dbpprt.dieter.core.sync.MachineFreshness
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant

class MachineRowsTest {
    private fun machine(id: String, name: String = id, compatibility: CompatibilityStatus = CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE) = Machine(
        id = id, name = name, serverOnline = true, lastSeenAt = "", releaseVersion = "1.2.0", minimumReleaseVersion = "1.3.0",
        compatibility = compatibility, generation = 1, remoteDesktop = RemoteDesktopPresence(platform = "macos", ready = false, reason = "Grant screen recording"),
        receivedAt = Instant.DISTANT_PAST,
    )

    private fun row(id: String, label: String = id, online: Boolean = true, phase: MachineLink = MachineLink.PENDING) =
        MachineRow(id = id, label = label, address = id, phase = phase, online = online, daemonId = id)

    @Test fun rowsDescribeRouteAttachmentAndPresence() {
        val routed = MachineRows.of(machine("m1", "Studio"), online = true, MachineRoute(RouteKind.DIRECT, 12.milliseconds), attached = "m1")
        assertEquals(MachineLink.CONNECTED, routed.phase)
        assertEquals("Direct TLS", routed.detail)
        assertEquals(12L, routed.latencyMs)
        assertEquals("Studio", routed.label)
        assertFalse(routed.remoteDesktopReady)
        assertEquals("Grant screen recording", routed.remoteDesktopReason)
        assertEquals("macos", routed.remoteDesktopPlatform)

        assertEquals("Attached", MachineRows.of(machine("m1"), online = true, route = null, attached = "m1").detail)
        assertEquals(MachineLink.PENDING, MachineRows.of(machine("m2"), online = true, route = null, attached = "m1").phase)
        assertEquals("Online", MachineRows.of(machine("m2"), online = true, route = null, attached = "m1").detail)
        val offline = MachineRows.of(machine("m3"), online = false, route = null, attached = null)
        assertEquals(MachineLink.FAILED, offline.phase)
        assertEquals("Offline", offline.detail)
        assertEquals("m3 is offline.", offline.unavailableMessage)

        val outdated = MachineRows.of(machine("m4", compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_UPDATE_REQUIRED), online = true, route = null, attached = null)
        assertTrue(outdated.detail.startsWith("Update required"))
        assertFalse(outdated.isCompatible)
        assertEquals("Dieter 1.2.0 needs an update to 1.3.0.", outdated.unavailableMessage)
        assertNull(routed.unavailableMessage)
    }

    @Test fun cachedPresenceIsNotPresentedAsLiveWhileDisconnected() {
        val rows = listOf(row("m1", "Studio", phase = MachineLink.CONNECTED).copy(latencyMs = 12))
        val reconnecting = MachineRows.presented(rows, ConnectionPhase.RECONNECTING, emptySet(), emptyMap()).single()
        assertFalse(reconnecting.online)
        assertEquals(MachineLink.PENDING, reconnecting.phase)
        assertEquals("Unavailable", reconnecting.detail)
        assertNull(reconnecting.latencyMs)
        assertEquals("Synchronizing", MachineRows.presented(rows, ConnectionPhase.SYNCING, emptySet(), emptyMap()).single().detail)
        assertEquals(rows, MachineRows.presented(rows, ConnectionPhase.CONNECTED, emptySet(), emptyMap()))
    }

    @Test fun queuedMachinesRemainVisibleWhenDiscoveryIsUnavailable() {
        val presented = MachineRows.presented(listOf(row("m1")), ConnectionPhase.RECONNECTING, setOf("m1", "m2", "m3"), mapOf("m2" to "Studio Mac"))
        assertEquals(listOf("m1", "m2", "m3"), presented.map { it.id })
        val queued = presented[1]
        assertEquals("Studio Mac", queued.label)
        assertFalse(queued.online)
        assertEquals(MachineLink.PENDING, queued.phase)
        assertEquals("Dieter machine", presented[2].label)
    }

    @Test fun listsPutOnlineMachinesFirstThenSortByName() {
        val rows = listOf(row("b", "beta", online = false), row("a", "Alpha"), row("c", "charlie"), row("a", "Alpha duplicate"), MachineRow("gateway", "Gateway", "https://example.test"))
        assertEquals(listOf("a", "c", "b"), MachineRows.listed(rows).map { it.id })
    }

    @Test fun fleetTotalsCountOnlyReportingMachines() {
        val rows = listOf(row("a"), row("b"), row("c"))
        val info = mapOf(
            "a" to MachineInformation(active_agent_count = 2, logical_cpu_count = 8, memory_total_bytes = 16L shl 30, gpu = GPUTelemetry(devices = listOf(GPUDevice(id = "g")))),
            "b" to MachineInformation(active_agent_count = 1, logical_cpu_count = 4, memory_total_bytes = 8L shl 30),
        )
        assertEquals(FleetTotals(reporting = 2, machines = 3, agents = 3, cores = 12, memoryBytes = 24L shl 30, gpus = 1), MachineRows.fleet(rows) { info[it] })
    }

    @Test fun projectHostsMustBeOnlineCurrentAndEnrolled() {
        val connected = row("a", phase = MachineLink.CONNECTED)
        val online = row("b")
        val offline = row("c", online = false)
        val outdated = row("d").copy(compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_UPDATE_REQUIRED, minimumReleaseVersion = "1.3.0")
        assertTrue(connected.hostsProjects)
        assertFalse(offline.hostsProjects)
        assertFalse(outdated.hostsProjects)
        assertFalse(MachineRow("gateway", "Gateway", "x").hostsProjects)
        assertEquals("Offline", offline.hostDetail)
        assertEquals("Update required · 1.3.0", outdated.hostDetail)
        assertEquals("Online", MachineRows.of(machine("x"), true, null, null).hostDetail)
        assertEquals("Requires Dieter 1.3.0", outdated.hostSummary)
        assertEquals("Online · repository and agents run here", online.hostSummary)

        assertEquals("b", MachineRows.defaultHost(listOf(connected, online), "b"))
        assertEquals("a", MachineRows.defaultHost(listOf(online, connected), "c"))
        assertEquals("b", MachineRows.defaultHost(listOf(offline, online), ""))
        assertEquals("", MachineRows.defaultHost(listOf(offline, outdated), "c"))
    }

    @Test fun labelsFallBackToProjectHostsThenTheId() {
        val rows = listOf(row("a", "Studio"), row("b", ""))
        assertEquals("Studio", MachineRows.label(rows, emptyMap(), "a"))
        assertEquals("Laptop", MachineRows.label(rows, mapOf("b" to "Laptop"), "b"))
        assertEquals("zzz", MachineRows.label(rows, emptyMap(), "zzz"))
        assertEquals("Unassigned", MachineRows.label(rows, emptyMap(), ""))
    }

    @Test fun syncWarningsNameMachinesAndAppearOnce() {
        val rows = listOf(row("a", "Studio"), row("b", "Laptop"))
        val rejected = PeerSyncDiagnostic(peer_id = "b", failure_code = "Rejected", record_id = "r1", record_kind = "card")
        val freshness = mapOf("a" to MachineFreshness(peerSyncIssues = listOf(rejected, rejected)))
        val now = Instant.parse("2026-08-14T12:00:00Z")
        assertEquals(listOf("Shared updates between Studio and Laptop are blocked by a rejected record."), MachineRows.syncWarnings(rows, freshness, connected = true, now))
        assertEquals(emptyList(), MachineRows.syncWarnings(rows, freshness, connected = false, now))
    }

    @Test fun formatsTelemetryWithoutInventingPrecision() {
        assertEquals("10.4 GB", MachineFormats.bytes(11_200_000_000))
        assertEquals("512 B", MachineFormats.bytes(512))
        assertEquals("1.2 MB/s", MachineFormats.rate(1_250_000.0))
        assertEquals("0 B/s", MachineFormats.rate(0.0))
        assertEquals("14d 6h", MachineFormats.uptime(14 * 86_400L + 6 * 3_600L))
        assertEquals("2h 41m", MachineFormats.uptime(2 * 3_600L + 41 * 60L))
        assertEquals("0m", MachineFormats.uptime(-5))
        assertEquals("38%", MachineFormats.percentage(37.6))
        assertEquals("0123456789", MachineFormats.shortRevision("0123456789abcdef"))
        assertNull(MachineFormats.shortRevision("unknown"))
        assertEquals("8 cores · load 1.5 / 0.8 / 0.3", MachineFormats.load(MachineInformation(logical_cpu_count = 8, load_1 = 1.5, load_5 = 0.75, load_15 = 0.25)))
    }

    @Test fun subtitlesAndGpuLabelsDescribeTheHardware() {
        val info = MachineInformation(hardware_model = "Mac16,1", processor = "M4 Max", os_name = "macOS", os_version = "26.1", uptime_seconds = 3_700)
        assertEquals("Mac16,1 · M4 Max  ·  macOS 26.1  ·  up 1h 1m", MachineFormats.subtitle(row("a"), info))
        assertEquals("Loading machine information…", MachineFormats.subtitle(row("a"), null))
        assertEquals("Waiting", MachineFormats.subtitle(row("a", online = false), null))
        assertEquals("Apple", MachineFormats.gpuVendor(GPUVendor.GPU_VENDOR_APPLE))
        assertNull(MachineFormats.gpuVendor(GPUVendor.GPU_VENDOR_UNSPECIFIED))
        assertEquals("2.0 GB / 24.0 GB unified", MachineFormats.gpuMemory(GPUDevice(memory_kind = GPUMemoryKind.GPU_MEMORY_KIND_UNIFIED, memory_used_bytes = 2L shl 30, memory_total_bytes = 24L shl 30)))
        assertEquals("8.0 GB VRAM", MachineFormats.gpuMemory(GPUDevice(memory_total_bytes = 8L shl 30)))
    }
}
