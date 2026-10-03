package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.client.v1.Tone
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

    /** Can open a screen share: an enrolled, online, current machine; [screenStatus] says whether its host is ready. */
    val canShareScreen: Boolean get() = online && daemonId != null && isCompatible

    /** What a screen picker says about this machine. */
    val screenStatus: String
        get() = when {
            !online -> "Offline"
            !isCompatible -> "Update required"
            !remoteDesktopReady -> "Screen sharing unavailable"
            else -> "Ready to connect"
        }

    /** "Dieter 1.2.0", or empty while the release is unknown. */
    val releaseLabel: String get() = releaseVersion.takeIf { it.isNotBlank() }?.let { "Dieter $it" }.orEmpty()

    /** What a screen picker adds under [screenStatus]: the host's platform and release, e.g. "macOS · Dieter 1.2.0"; empty when neither is known. */
    val screenMetadata: String
        get() {
            val platform = when (remoteDesktopPlatform) {
                "darwin" -> "macOS"
                "linux" -> "Linux"
                else -> remoteDesktopPlatform
            }
            return listOf(platform, releaseLabel).filter { it.isNotBlank() }.joinToString(" · ")
        }
}

/**
 * A machine list row's status line, free of relative times. With
 * [showsLastSeen], views follow [detail] with [MachineFormats.lastSeen],
 * worded when rendered.
 */
data class MachineStatus(val detail: String, val showsLastSeen: Boolean = false) {
    /** The line as shown at [now]: [detail], followed by when the machine was last seen ([lastSeenAt]) when [showsLastSeen]. */
    fun line(lastSeenAt: String, now: Instant): String = if (showsLastSeen) "$detail · ${MachineFormats.lastSeen(lastSeenAt, now)}" else detail
}

/** The fleet summary over the machines that reported information. */
data class FleetTotals(val reporting: Int, val machines: Int, val agents: Long, val cores: Long, val memoryBytes: Long, val gpus: Int) {
    /** "2/3 reporting". */
    val reportingLabel: String get() = "$reporting/$machines reporting"
}

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
            else -> presence(online)
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

    /** Every machine list and picker: by name ignoring case, then by ID, so presence and latency never move a row. */
    val ORDER: Comparator<MachineRow> = compareBy<MachineRow> { it.label.lowercase() }.thenBy { it.id }

    /** The machine list: enrolled machines in [ORDER]. */
    fun listed(rows: List<MachineRow>): List<MachineRow> =
        rows.filter { it.daemonId != null }.distinctBy { it.id }.sortedWith(ORDER)

    /**
     * [row]'s status line, first match wins: why it needs an update, the
     * attached machine's connection failure, its shared-update warnings,
     * "Synchronizing" while the workspace loads, "Unavailable" while cached
     * presence cannot be trusted, "Offline", its route and latency
     * ("Direct TLS · 12 ms"), else "Attached" or "Online". [row] is the
     * machine's own row from [of], not the presented one; [feedLive] is the
     * attached machine's feed with its projection applied.
     */
    fun status(row: MachineRow, attached: Boolean, phase: ConnectionPhase, connectionError: String?, syncWarnings: List<String>, feedLive: Boolean): MachineStatus = when {
        !row.isCompatible -> MachineStatus(row.detail)
        attached && !connectionError.isNullOrBlank() && phase in FAILING -> MachineStatus(connectionError.orEmpty())
        syncWarnings.isNotEmpty() -> MachineStatus(syncWarnings.joinToString("\n"))
        phase == ConnectionPhase.SYNCING || (attached && phase == ConnectionPhase.CONNECTED && !feedLive) -> MachineStatus("Synchronizing")
        phase != ConnectionPhase.CONNECTED -> MachineStatus("Unavailable", showsLastSeen = true)
        !row.online -> MachineStatus("Offline", showsLastSeen = true)
        row.phase == MachineLink.CONNECTED -> MachineStatus("${row.detail} · ${row.latencyMs ?: 0} ms")
        else -> MachineStatus(if (attached) "Attached" else "Online")
    }

    /** "2 of 3 machines online" over the enrolled [rows] as presented; "Discovering enrolled machines" before any is known. */
    fun onlineSummary(rows: List<MachineRow>): String {
        val enrolled = rows.filter { it.daemonId != null }
        if (enrolled.isEmpty()) return "Discovering enrolled machines"
        return "${enrolled.count { it.online }} of ${MachineFormats.count(enrolled.size, "machine")} online"
    }

    /** Why a machine the account no longer lists cannot be used. */
    const val UNENROLLED = "This machine is no longer enrolled."

    /** "Online" or "Offline". */
    fun presence(online: Boolean): String = if (online) "Online" else "Offline"

    /** How a machine's row reads: available succeeds, a compatible machine that cannot take work warns, an outdated one is danger. */
    fun tone(available: Boolean, compatible: Boolean): Tone = when {
        available -> Tone.TONE_SUCCESS
        compatible -> Tone.TONE_WARNING
        else -> Tone.TONE_DANGER
    }

    /** "2 online": the enrolled [rows] that are online as presented. */
    fun onlineLabel(rows: List<MachineRow>): String = "${rows.count { it.daemonId != null && it.online }} online"

    /** Why the machine [id] cannot be read or operated now: it left [rows], is offline, or is outdated; null when it can. */
    fun unavailableMessage(rows: List<MachineRow>, id: String): String? {
        val row = rows.firstOrNull { it.id == id } ?: return UNENROLLED
        return row.unavailableMessage
    }

    /** Phases in which the attached machine's connection error explains its row. */
    private val FAILING = setOf(ConnectionPhase.RECONNECTING, ConnectionPhase.NO_MACHINE, ConnectionPhase.UPDATE_REQUIRED)

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

    /** [syncWarnings] by the machine that reports them, for each machine's own [status]; machines without warnings are left out. */
    fun syncWarningsByMachine(rows: List<MachineRow>, freshness: Map<String, MachineFreshness>, connected: Boolean, now: Instant): Map<String, List<String>> =
        freshness.mapValues { (daemonId, fresh) -> syncWarnings(rows, mapOf(daemonId to fresh), connected, now) }.filterValues { it.isNotEmpty() }

    /** Keeps [current] while it can host projects; else the first connected host, else any host, else "". */
    fun defaultHost(rows: List<MachineRow>, current: String): String =
        if (rows.any { it.id == current && it.hostsProjects }) current
        else (rows.firstOrNull { it.phase == MachineLink.CONNECTED && it.hostsProjects } ?: rows.firstOrNull { it.hostsProjects })?.id.orEmpty()

    /**
     * [daemonId]'s row among presented [rows] (a project's host, a
     * conversation's owner), else an offline row named by its ID.
     */
    fun host(rows: List<MachineRow>, daemonId: String): MachineRow =
        rows.firstOrNull { it.daemonId == daemonId }
            ?: MachineRow(id = daemonId, label = label(rows, emptyMap(), daemonId), address = daemonId, detail = "Unavailable", online = false, daemonId = daemonId)

    /** A machine's display name: its row, else a project host that names it, else the ID. */
    fun label(rows: List<MachineRow>, hostNames: Map<String, String>, daemonId: String): String =
        rows.firstOrNull { it.daemonId == daemonId }?.label?.takeIf { it.isNotBlank() }
            ?: hostNames[daemonId]?.takeIf { it.isNotBlank() }
            ?: daemonId.ifBlank { "Unassigned" }
}
