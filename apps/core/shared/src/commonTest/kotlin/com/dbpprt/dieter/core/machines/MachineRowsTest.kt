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
import com.dbpprt.dieter.core.connection.MachineSync
import com.dbpprt.dieter.core.connection.SyncState
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.session.MachineRoute
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant

class MachineRowsTest {
    private fun machine(
        id: String,
        name: String = id,
        compatibility: CompatibilityStatus = CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE,
    ) =
        Machine(
            id = id,
            name = name,
            serverOnline = true,
            lastSeenAt = "",
            releaseVersion = "1.2.0",
            minimumReleaseVersion = "1.3.0",
            compatibility = compatibility,
            generation = 1,
            remoteDesktop =
                RemoteDesktopPresence(
                    platform = "macos",
                    ready = false,
                    reason = "Grant screen recording",
                ),
            receivedAt = Instant.DISTANT_PAST,
        )

    private fun row(
        id: String,
        label: String = id,
        online: Boolean = true,
        phase: MachineLink = MachineLink.PENDING,
    ) =
        MachineRow(
            id = id,
            label = label,
            address = id,
            phase = phase,
            online = online,
            daemonId = id,
        )

    @Test
    fun rowsDescribeRouteAndPresence() {
        val routed =
            MachineRows.of(
                machine("m1", "Studio"),
                online = true,
                MachineRoute(RouteKind.DIRECT, 12.milliseconds),
            )
        assertEquals(MachineLink.CONNECTED, routed.phase)
        assertEquals("Direct TLS", routed.detail)
        assertEquals(12L, routed.latencyMs)
        assertEquals("Studio", routed.label)
        assertFalse(routed.remoteDesktopReady)
        assertEquals("Grant screen recording", routed.remoteDesktopReason)
        assertEquals("macos", routed.remoteDesktopPlatform)

        assertEquals(
            MachineLink.PENDING,
            MachineRows.of(machine("m2"), online = true, route = null).phase,
        )
        assertEquals("Online", MachineRows.of(machine("m2"), online = true, route = null).detail)
        val offline = MachineRows.of(machine("m3"), online = false, route = null)
        assertEquals(MachineLink.FAILED, offline.phase)
        assertEquals("Offline", offline.detail)
        assertEquals("m3 is offline.", offline.unavailableMessage)

        val outdated =
            MachineRows.of(
                machine(
                    "m4",
                    compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_UPDATE_REQUIRED,
                ),
                online = true,
                route = null,
            )
        assertTrue(outdated.detail.startsWith("Update required"))
        assertFalse(outdated.isCompatible)
        assertEquals("Dieter 1.2.0 needs an update to 1.3.0.", outdated.unavailableMessage)
        assertNull(routed.unavailableMessage)
    }

    @Test
    fun cachedPresenceIsNotPresentedAsLiveWhileDisconnected() {
        val rows = listOf(row("m1", "Studio", phase = MachineLink.CONNECTED).copy(latencyMs = 12))
        val reconnecting =
            MachineRows.presented(rows, ConnectionPhase.RECONNECTING, emptySet(), emptyMap())
                .single()
        assertFalse(reconnecting.online)
        assertEquals(MachineLink.PENDING, reconnecting.phase)
        assertEquals("Unavailable", reconnecting.detail)
        assertNull(reconnecting.latencyMs)
        assertEquals(
            "Unavailable",
            MachineRows.presented(rows, ConnectionPhase.CONNECTING, emptySet(), emptyMap())
                .single()
                .detail,
        )
        assertEquals(
            rows,
            MachineRows.presented(rows, ConnectionPhase.CONNECTED, emptySet(), emptyMap()),
        )
    }

    @Test
    fun queuedMachinesRemainVisibleWhenDiscoveryIsUnavailable() {
        val presented =
            MachineRows.presented(
                listOf(row("m1")),
                ConnectionPhase.RECONNECTING,
                setOf("m1", "m2", "m3"),
                mapOf("m2" to "Studio Mac"),
            )
        assertEquals(listOf("m1", "m2", "m3"), presented.map { it.id })
        val queued = presented[1]
        assertEquals("Studio Mac", queued.label)
        assertFalse(queued.online)
        assertEquals(MachineLink.PENDING, queued.phase)
        assertEquals("Dieter machine", presented[2].label)
    }

    @Test
    fun listsSortByNameIgnoringCaseThenByIdWhateverThePresence() {
        val rows =
            listOf(
                row("b", "beta", online = false),
                row("a", "Alpha"),
                row("c", "charlie"),
                row("a", "Alpha duplicate"),
                MachineRow("gateway", "Gateway", "https://example.test"),
            )
        assertEquals(listOf("a", "b", "c"), MachineRows.listed(rows).map { it.id })
        // The Mac sidebar's order: equal names fall back to the ID.
        val zulu = row("zulu", "Zulu")
        val alpha = row("alpha", "alpha")
        val alphaLater = row("alpha-later", "Alpha", online = false)
        val beta = row("beta", "Beta")
        assertEquals(
            listOf("alpha", "alpha-later", "beta", "zulu"),
            MachineRows.listed(listOf(zulu, alphaLater, beta, alpha)).map { it.id },
        )
        assertEquals(
            listOf("alpha", "alpha-later", "beta", "zulu"),
            listOf(zulu, alphaLater, beta, alpha).sortedWith(MachineRows.ORDER).map { it.id },
        )
    }

    @Test
    fun statusLinesExplainTheMostImportantStateFirst() {
        val routed =
            MachineRows.of(
                machine("m1", "Studio"),
                online = true,
                MachineRoute(RouteKind.DIRECT, 12.milliseconds),
            )
        val idle = MachineRows.of(machine("m2"), online = true, route = null)
        val offline = MachineRows.of(machine("m3"), online = false, route = null)
        val outdated =
            MachineRows.of(
                machine(
                    "m4",
                    compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_UPDATE_REQUIRED,
                ),
                online = true,
                route = null,
            )
        val live = MachineSync(SyncState.LIVE)
        fun status(
            row: MachineRow,
            sync: MachineSync? = live,
            phase: ConnectionPhase = ConnectionPhase.CONNECTED,
            warnings: List<String> = emptyList(),
        ) = MachineRows.status(row, sync, phase, warnings)

        assertEquals(
            MachineStatus("Update required · Dieter 1.2.0 (requires 1.3.0)"),
            status(outdated, warnings = listOf("delayed")),
        )
        assertEquals(
            MachineStatus("Shared updates are delayed.\nShared updates are blocked."),
            status(
                idle,
                warnings = listOf("Shared updates are delayed.", "Shared updates are blocked."),
            ),
        )
        // Without a live gateway connection, presence cannot be trusted.
        assertEquals(
            MachineStatus("Unavailable", showsLastSeen = true),
            status(routed, phase = ConnectionPhase.RECONNECTING),
        )
        assertEquals(
            MachineStatus("Unavailable", showsLastSeen = true),
            status(routed, phase = ConnectionPhase.DISCONNECTED),
        )
        assertEquals(
            MachineStatus("Offline", showsLastSeen = true),
            status(offline, sync = MachineSync(SyncState.OFFLINE)),
        )
        // Each machine's own stream decides its line.
        assertEquals(
            MachineStatus("Studio stopped sending changes."),
            status(
                routed,
                sync = MachineSync(SyncState.STALE, error = "Studio stopped sending changes."),
            ),
        )
        assertEquals(
            MachineStatus("Not responding"),
            status(routed, sync = MachineSync(SyncState.STALE)),
        )
        assertEquals(
            MachineStatus("Synchronizing"),
            status(routed, sync = MachineSync(SyncState.CATCHING_UP)),
        )
        assertEquals(MachineStatus("Synchronizing"), status(idle, sync = null))
        assertEquals(MachineStatus("Direct TLS · 12 ms"), status(routed))
        assertEquals(MachineStatus("Online"), status(idle))
    }

    @Test
    fun screenPickersSayWhyAMachineCannotShare() {
        val ready = row("a").copy(remoteDesktopReady = true)
        assertEquals("Ready to connect", ready.screenStatus)
        assertTrue(ready.canShareScreen)
        assertEquals("Offline", ready.copy(online = false).screenStatus)
        assertFalse(ready.copy(online = false).canShareScreen)
        val outdated =
            ready.copy(compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_UPDATE_REQUIRED)
        assertEquals("Update required", outdated.screenStatus)
        assertFalse(outdated.canShareScreen)
        // A host that cannot share yet is still connectable, so it can explain why.
        assertEquals(
            "Screen sharing unavailable",
            ready.copy(remoteDesktopReady = false).screenStatus,
        )
        assertTrue(ready.copy(remoteDesktopReady = false).canShareScreen)
        assertFalse(MachineRow("gateway", "Gateway", "x").canShareScreen)
    }

    @Test
    fun summariesCountPresentedMachines() {
        assertEquals(
            "Discovering enrolled machines",
            MachineRows.onlineSummary(listOf(MachineRow("gateway", "Gateway", "x"))),
        )
        assertEquals("1 of 1 machine online", MachineRows.onlineSummary(listOf(row("a"))))
        val rows = listOf(row("a"), row("b", online = false), row("c"))
        assertEquals("2 of 3 machines online", MachineRows.onlineSummary(rows))
        assertEquals(
            "0 of 3 machines online",
            MachineRows.onlineSummary(
                MachineRows.presented(rows, ConnectionPhase.RECONNECTING, emptySet(), emptyMap())
            ),
        )
    }

    @Test
    fun lastSeenCountsFromTheGatewaysReport() {
        val now = Instant.parse("2026-08-18T15:00:00Z")
        assertEquals("Last seen just now", MachineFormats.lastSeen("2026-08-18T14:59:40Z", now))
        assertEquals("Last seen 8m ago", MachineFormats.lastSeen("2026-08-18T14:52:00Z", now))
        assertEquals("Last seen 3h ago", MachineFormats.lastSeen("2026-08-18T12:00:00Z", now))
        assertEquals("Last seen 2d ago", MachineFormats.lastSeen("2026-08-16T14:00:00Z", now))
        assertEquals("Last seen just now", MachineFormats.lastSeen("2026-08-18T15:00:30Z", now))
        assertEquals("Last seen unknown", MachineFormats.lastSeen("", now))
        assertEquals("Last seen unknown", MachineFormats.lastSeen("yesterday", now))
    }

    @Test
    fun fleetTotalsCountOnlyReportingMachines() {
        val rows = listOf(row("a"), row("b"), row("c"))
        val info =
            mapOf(
                "a" to
                    MachineInformation(
                        active_agent_count = 2,
                        logical_cpu_count = 8,
                        memory_total_bytes = 16L shl 30,
                        gpu = GPUTelemetry(devices = listOf(GPUDevice(id = "g"))),
                    ),
                "b" to
                    MachineInformation(
                        active_agent_count = 1,
                        logical_cpu_count = 4,
                        memory_total_bytes = 8L shl 30,
                    ),
            )
        assertEquals(
            FleetTotals(
                reporting = 2,
                machines = 3,
                agents = 3,
                cores = 12,
                memoryBytes = 24L shl 30,
                gpus = 1,
            ),
            MachineRows.fleet(rows) { info[it] },
        )
        assertEquals("2/3 reporting", MachineRows.fleet(rows) { info[it] }.reportingLabel)
    }

    @Test
    fun statusLinesAddWhenAnUnreachableMachineWasLastSeen() {
        val now = Instant.parse("2026-08-18T15:00:00Z")
        assertEquals(
            "Offline · Last seen 8m ago",
            MachineStatus("Offline", showsLastSeen = true).line("2026-08-18T14:52:00Z", now),
        )
        assertEquals(
            "Unavailable · Last seen unknown",
            MachineStatus("Unavailable", showsLastSeen = true).line("", now),
        )
        assertEquals(
            "Direct TLS · 12 ms",
            MachineStatus("Direct TLS · 12 ms").line("2026-08-18T14:52:00Z", now),
        )
    }

    @Test
    fun onlineLabelsCountEnrolledMachinesThatAreOnline() {
        assertEquals(
            "2 online",
            MachineRows.onlineLabel(
                listOf(
                    row("a"),
                    row("b", online = false),
                    row("c"),
                    MachineRow("gateway", "Gateway", "x"),
                )
            ),
        )
        assertEquals("0 online", MachineRows.onlineLabel(emptyList()))
    }

    @Test
    fun machinesThatLeftOrCannotWorkSayWhy() {
        val rows = listOf(row("a", "Studio"), row("b", "Laptop", online = false))
        assertNull(MachineRows.unavailableMessage(rows, "a"))
        assertEquals("Laptop is offline.", MachineRows.unavailableMessage(rows, "b"))
        assertEquals(
            "This machine is no longer enrolled.",
            MachineRows.unavailableMessage(rows, "gone"),
        )
    }

    @Test
    fun syncWarningsStayWithTheMachineThatReportsThem() {
        val rows = listOf(row("a", "Studio"), row("b", "Laptop"))
        val rejected =
            PeerSyncDiagnostic(
                peer_id = "b",
                failure_code = "Rejected",
                record_id = "r1",
                record_kind = "card",
            )
        val issues = mapOf("a" to listOf(rejected), "b" to emptyList())
        val now = Instant.parse("2026-08-14T12:00:00Z")
        assertEquals(
            mapOf(
                "a" to
                    listOf(
                        "Board and settings sync between Studio and Laptop is blocked by a rejected record."
                    )
            ),
            MachineRows.syncWarningsByMachine(rows, issues, connected = true, now),
        )
        assertEquals(
            emptyMap(),
            MachineRows.syncWarningsByMachine(rows, issues, connected = false, now),
        )
    }

    @Test
    fun screenPickersNameThePlatformAndRelease() {
        val mac = row("a").copy(remoteDesktopPlatform = "darwin", releaseVersion = "1.2.0")
        assertEquals("Dieter 1.2.0", mac.releaseLabel)
        assertEquals("macOS · Dieter 1.2.0", mac.screenMetadata)
        assertEquals(
            "Linux",
            mac.copy(remoteDesktopPlatform = "linux", releaseVersion = "").screenMetadata,
        )
        assertEquals("", mac.copy(releaseVersion = " ").releaseLabel)
        assertEquals(
            "freebsd · Dieter 1.2.0",
            mac.copy(remoteDesktopPlatform = "freebsd").screenMetadata,
        )
        assertEquals("", row("b").screenMetadata)
    }

    @Test
    fun gpuDevicesAndMissingInformationReadTheSameOnEveryClient() {
        val device =
            GPUDevice(
                id = "gpu-0",
                vendor = GPUVendor.GPU_VENDOR_AMD,
                name = "Radeon",
                driver_version = "24.1",
                utilization_percent = 21.4,
            )
        assertEquals("Radeon", MachineFormats.gpuName(device))
        assertEquals("GPU", MachineFormats.gpuName(device.copy(name = " ")))
        assertEquals("AMD · gpu-0 · driver 24.1", MachineFormats.gpuDetail(device))
        assertEquals(
            "gpu-0",
            MachineFormats.gpuDetail(
                device.copy(vendor = GPUVendor.GPU_VENDOR_UNSPECIFIED, driver_version = "")
            ),
        )
        assertEquals("21%", MachineFormats.gpuUtilization(device))
        assertEquals("—", MachineFormats.gpuUtilization(device.copy(utilization_percent = null)))
        assertEquals(
            "No supported GPU telemetry is available.",
            MachineFormats.gpuUnavailable(GPUTelemetry()),
        )
        assertEquals(
            "nvidia-smi is missing",
            MachineFormats.gpuUnavailable(
                GPUTelemetry(unavailable_reason = "nvidia-smi is missing")
            ),
        )

        assertEquals("timed out", MachineFormats.informationUnavailable(row("a"), "timed out"))
        assertEquals(
            "Machine information is unavailable.",
            MachineFormats.informationUnavailable(row("a"), null),
        )
        assertEquals(
            "Offline",
            MachineFormats.informationUnavailable(
                row("a", online = false).copy(detail = "Offline"),
                null,
            ),
        )
        assertEquals(
            "pid 4294967296 · daemon",
            MachineFormats.processDetail(4_294_967_296L, "daemon"),
        )
    }

    @Test
    fun projectHostsMustBeOnlineCurrentAndEnrolled() {
        val connected = row("a", phase = MachineLink.CONNECTED)
        val online = row("b")
        val offline = row("c", online = false)
        val outdated =
            row("d")
                .copy(
                    compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_UPDATE_REQUIRED,
                    minimumReleaseVersion = "1.3.0",
                )
        assertTrue(connected.hostsProjects)
        assertFalse(offline.hostsProjects)
        assertFalse(outdated.hostsProjects)
        assertFalse(MachineRow("gateway", "Gateway", "x").hostsProjects)
        assertEquals("Offline", offline.hostDetail)
        assertEquals("Update required · 1.3.0", outdated.hostDetail)
        assertEquals("Online", MachineRows.of(machine("x"), true, null).hostDetail)
        assertEquals("Requires Dieter 1.3.0", outdated.hostSummary)
        assertEquals("Online · repository and agents run here", online.hostSummary)

        assertEquals("b", MachineRows.defaultHost(listOf(connected, online), "b"))
        assertEquals("a", MachineRows.defaultHost(listOf(online, connected), "c"))
        assertEquals("b", MachineRows.defaultHost(listOf(offline, online), ""))
        assertEquals("", MachineRows.defaultHost(listOf(offline, outdated), "c"))
    }

    @Test
    fun projectHostsAreTheirPresentedRowElseAnOfflineRowNamedByItsId() {
        val rows =
            MachineRows.presented(
                listOf(row("a", "Studio")),
                ConnectionPhase.RECONNECTING,
                emptySet(),
                emptyMap(),
            )
        val studio = MachineRows.host(rows, "a")
        assertEquals("Studio", studio.label)
        // Cached presence never reads as online while the gateway is not connected.
        assertFalse(studio.online)
        assertTrue(MachineRows.host(listOf(row("a", "Studio")), "a").online)
        val unknown = MachineRows.host(rows, "gone")
        assertEquals("gone", unknown.label)
        assertEquals("gone", unknown.daemonId)
        assertFalse(unknown.online)
    }

    @Test
    fun labelsFallBackToProjectHostsThenTheId() {
        val rows = listOf(row("a", "Studio"), row("b", ""))
        assertEquals("Studio", MachineRows.label(rows, emptyMap(), "a"))
        assertEquals("Laptop", MachineRows.label(rows, mapOf("b" to "Laptop"), "b"))
        assertEquals("zzz", MachineRows.label(rows, emptyMap(), "zzz"))
        assertEquals("Unassigned", MachineRows.label(rows, emptyMap(), ""))
    }

    @Test
    fun syncWarningsNameMachinesAndAppearOnce() {
        val rows = listOf(row("a", "Studio"), row("b", "Laptop"))
        val rejected =
            PeerSyncDiagnostic(
                peer_id = "b",
                failure_code = "Rejected",
                record_id = "r1",
                record_kind = "card",
            )
        val issues = mapOf("a" to listOf(rejected, rejected))
        val now = Instant.parse("2026-08-14T12:00:00Z")
        assertEquals(
            listOf(
                "Board and settings sync between Studio and Laptop is blocked by a rejected record."
            ),
            MachineRows.syncWarnings(rows, issues, connected = true, now),
        )
        assertEquals(emptyList(), MachineRows.syncWarnings(rows, issues, connected = false, now))
    }

    @Test
    fun formatsTelemetryWithoutInventingPrecision() {
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
        assertEquals(
            "8 cores · load 1.5 / 0.8 / 0.3",
            MachineFormats.load(
                MachineInformation(
                    logical_cpu_count = 8,
                    load_1 = 1.5,
                    load_5 = 0.75,
                    load_15 = 0.25,
                )
            ),
        )
    }

    @Test
    fun subtitlesAndGpuLabelsDescribeTheHardware() {
        val info =
            MachineInformation(
                hardware_model = "Mac16,1",
                processor = "M4 Max",
                os_name = "macOS",
                os_version = "26.1",
                uptime_seconds = 3_700,
            )
        assertEquals(
            "Mac16,1 · M4 Max  ·  macOS 26.1  ·  up 1h 1m",
            MachineFormats.subtitle(row("a"), info),
        )
        assertEquals("Loading machine information…", MachineFormats.subtitle(row("a"), null))
        assertEquals("Waiting", MachineFormats.subtitle(row("a", online = false), null))
        assertEquals("Apple", MachineFormats.gpuVendor(GPUVendor.GPU_VENDOR_APPLE))
        assertNull(MachineFormats.gpuVendor(GPUVendor.GPU_VENDOR_UNSPECIFIED))
        assertEquals(
            "2.0 GB / 24.0 GB unified",
            MachineFormats.gpuMemory(
                GPUDevice(
                    memory_kind = GPUMemoryKind.GPU_MEMORY_KIND_UNIFIED,
                    memory_used_bytes = 2L shl 30,
                    memory_total_bytes = 24L shl 30,
                )
            ),
        )
        assertEquals(
            "8.0 GB VRAM",
            MachineFormats.gpuMemory(GPUDevice(memory_total_bytes = 8L shl 30)),
        )
        assertEquals(
            "3.0 GB VRAM",
            MachineFormats.gpuMemory(unified = false, used = 3L shl 30, total = null),
        )
        assertEquals(
            "Mac16,1 · M4 Max  ·  macOS 26.1  ·  up 1h 1m",
            MachineFormats.subtitle("Mac16,1", "M4 Max", "macOS", "26.1", 3_700),
        )
        assertEquals("up 12m", MachineFormats.subtitle("", "", "", "", 720))
    }

    @Test
    fun telemetryDetailsReadTheSameOnEveryClient() {
        assertEquals("1 device", MachineFormats.count(1, "device"))
        assertEquals("2 devices", MachineFormats.count(2, "device"))
        assertEquals("0 devices", MachineFormats.count(0, "device"))
        assertEquals("1 agent active", MachineFormats.activeAgents(1))
        assertEquals("3 agents active", MachineFormats.activeAgents(3))
        assertEquals("12 cores · load 1.2 / 0.8 / 0.5", MachineFormats.load(12, 1.2, 0.8, 0.5))
        assertEquals("41°C", MachineFormats.temperature(40.6))
        assertEquals("45 W", MachineFormats.power(44.5))
        assertEquals("120 GB free", MachineFormats.disk(120L shl 30))
        assertEquals("↓ 1.2 MB/s · ↑ 0 B/s", MachineFormats.network(1_250_000.0, 0.0))
        assertEquals(
            "pid 412 · harness worker",
            MachineFormats.processDetail(412, "harness worker"),
        )
        assertEquals("pid 412", MachineFormats.processDetail(412, ""))
        assertEquals("0.4.340 · 0123456789", MachineFormats.version("0.4.340", "0123456789abcdef"))
        assertEquals("Unknown", MachineFormats.version("", "unknown"))
        // The daemon's own build wins over the release the gateway reports.
        assertEquals("0.4.341 · abc", MachineFormats.daemonVersion("0.4.341", "0.4.340", "abc"))
        assertEquals("0.4.340", MachineFormats.daemonVersion("", "0.4.340", ""))
    }
}
