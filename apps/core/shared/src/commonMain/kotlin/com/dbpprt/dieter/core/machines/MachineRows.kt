package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.core.admin.PeerSyncHealth
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.session.MachineRoute
import com.dbpprt.dieter.core.sync.MachineFreshness
import kotlin.time.Instant

enum class MachineLink { PENDING, TRYING, CONNECTED, FAILED }

/** One enrolled machine as lists and pickers show it. [id] is the daemon ID. */
data class MachineRow(
    val id: String,
    val label: String,
    val address: String,
    val phase: MachineLink = MachineLink.PENDING,
    val detail: String = "Waiting",
    val latencyMs: Long? = null,
    val online: Boolean = true,
    val daemonId: String? = null,
    val lastSeenAt: String = "",
    val releaseVersion: String = "",
    val compatibility: CompatibilityStatus = CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE,
    val minimumReleaseVersion: String = "",
    val remoteDesktopReady: Boolean = true,
    val remoteDesktopReason: String = "",
    val remoteDesktopPlatform: String = "",
) {
    val isCompatible: Boolean get() = compatibility == CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE

    /** Can host a new project or checkout: an enrolled, online, current machine. */
    val hostsProjects: Boolean get() = online && daemonId != null && isCompatible

    /** What a host picker says about this machine. */
    val hostDetail: String
        get() = when {
            !online -> "Offline"
            !isCompatible -> "Update required · ${minimumReleaseVersion.ifBlank { "newer Dieter release" }}"
            else -> detail
        }

    /** What a chosen host says about itself. */
    val hostSummary: String
        get() = when {
            !online -> "Offline"
            !isCompatible -> "Requires Dieter ${minimumReleaseVersion.ifBlank { "update" }}"
            else -> "Online · repository and agents run here"
        }

    /** Why this machine cannot take work now, or null. */
    val unavailableMessage: String?
        get() = when {
            !online -> "$label is offline."
            !isCompatible -> "Dieter ${releaseVersion.ifBlank { "unknown" }} needs an update to ${minimumReleaseVersion.ifBlank { "the required release" }}."
            else -> null
        }
}

/** The fleet summary over the machines that reported information. */
data class FleetTotals(val reporting: Int, val machines: Int, val agents: Long, val cores: Long, val memoryBytes: Long, val gpus: Int)

object MachineRows {
    /** [machine]'s row: connected over a route, else online or offline; an outdated release says so. */
    fun of(machine: Machine, online: Boolean, route: MachineRoute?, attached: String?): MachineRow = MachineRow(
        id = machine.id,
        label = machine.name.ifBlank { machine.id },
        address = machine.id,
        phase = when {
            route != null -> MachineLink.CONNECTED
            online -> MachineLink.PENDING
            else -> MachineLink.FAILED
        },
        detail = when {
            !machine.compatible -> machine.incompatibilityDescription.orEmpty()
            route != null -> route.kind.label
            machine.id == attached && online -> "Attached"
            online -> "Online"
            else -> "Offline"
        },
        latencyMs = route?.latency?.inWholeMilliseconds,
        online = online,
        daemonId = machine.id,
        lastSeenAt = machine.lastSeenAt,
        releaseVersion = machine.releaseVersion,
        compatibility = machine.compatibility,
        minimumReleaseVersion = machine.minimumReleaseVersion,
        remoteDesktopReady = machine.remoteDesktop?.ready == true,
        remoteDesktopReason = machine.remoteDesktop?.reason.orEmpty(),
        remoteDesktopPlatform = machine.remoteDesktop?.platform.orEmpty(),
    )

    /**
     * What lists show: the machines, plus rows for machines that only have
     * queued changes. Without a live gateway connection, cached presence is
     * never shown as online.
     */
    fun presented(rows: List<MachineRow>, phase: ConnectionPhase, queued: Set<String>, names: Map<String, String>): List<MachineRow> {
        val shown = if (phase == ConnectionPhase.CONNECTED) rows else rows.map { row ->
            if (row.daemonId == null) row else row.copy(
                phase = MachineLink.PENDING,
                detail = if (phase == ConnectionPhase.SYNCING) "Synchronizing" else "Unavailable",
                latencyMs = null,
                online = false,
            )
        }
        val known = shown.mapTo(HashSet()) { it.id }
        return shown + queued.filterNot(known::contains).map { daemonId ->
            MachineRow(id = daemonId, label = names[daemonId] ?: "Dieter machine", address = daemonId, detail = "Unavailable", online = false, daemonId = daemonId)
        }
    }

    /** The machine list: enrolled machines, online first, then by name. */
    fun listed(rows: List<MachineRow>): List<MachineRow> =
        rows.filter { it.daemonId != null }.distinctBy { it.id }.sortedWith(compareBy<MachineRow> { !it.online }.thenBy { it.label.lowercase() })

    fun fleet(rows: List<MachineRow>, information: (String) -> MachineInformation?): FleetTotals {
        val measured = rows.mapNotNull { information(it.id) }
        return FleetTotals(
            reporting = measured.size,
            machines = rows.size,
            agents = measured.sumOf { it.active_agent_count.toLong() },
            cores = measured.sumOf { it.logical_cpu_count.toLong() },
            memoryBytes = measured.sumOf { it.memory_total_bytes },
            gpus = measured.sumOf { it.gpu?.devices?.size ?: 0 },
        )
    }

    /** Every machine's current peer-sync warnings, each line once, named by the rows. */
    fun syncWarnings(rows: List<MachineRow>, freshness: Map<String, MachineFreshness>, connected: Boolean, now: Instant): List<String> {
        val byId = rows.associateBy { it.id }
        val peers = rows.associate { it.id to (it.label to it.online) }
        return freshness.flatMap { (daemonId, fresh) ->
            val reporter = byId[daemonId]
            PeerSyncHealth.warnings(reporter?.label ?: daemonId, reporter?.online == true, connected, fresh.peerSyncIssues, peers, now)
        }.distinct()
    }

    /** Keeps [current] while it can host projects; else the first connected host, else any host, else "". */
    fun defaultHost(rows: List<MachineRow>, current: String): String =
        if (rows.any { it.id == current && it.hostsProjects }) current
        else (rows.firstOrNull { it.phase == MachineLink.CONNECTED && it.hostsProjects } ?: rows.firstOrNull { it.hostsProjects })?.id.orEmpty()

    /** A machine's display name: its row, else a project host that names it, else the ID. */
    fun label(rows: List<MachineRow>, hostNames: Map<String, String>, daemonId: String): String =
        rows.firstOrNull { it.daemonId == daemonId }?.label?.takeIf { it.isNotBlank() }
            ?: hostNames[daemonId]?.takeIf { it.isNotBlank() }
            ?: daemonId.ifBlank { "Unassigned" }
}
