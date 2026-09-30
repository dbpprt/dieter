package com.dbpprt.dieter.core.admin

import com.dbpprt.dieter.api.gateway.v1.Daemon
import com.dbpprt.dieter.api.gateway.v1.DaemonRef
import com.dbpprt.dieter.api.gateway.v1.GatewayServiceClient
import com.dbpprt.dieter.api.gateway.v1.RenameDaemonRequest
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.api.v1.MachineOperationRequest
import com.dbpprt.dieter.api.v1.MachineOperationResponse
import com.dbpprt.dieter.api.v1.PeerSyncDiagnostic
import com.dbpprt.dieter.core.board.Runtimes
import com.dbpprt.dieter.core.outbox.OutboxView
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.Timestamps
import com.dbpprt.dieter.core.runtime.withDeadline
import com.dbpprt.dieter.core.session.MachineSessions
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.coroutineScope

/** What is known about one machine: its latest information and recent load. */
data class MachineSnapshot(
    val information: MachineInformation? = null,
    val loading: Boolean = false,
    val error: String? = null,
    /** Last 12 CPU samples, oldest first. */
    val cpuHistory: List<Double> = emptyList(),
    /** Per GPU: last 12 utilization samples. */
    val gpuHistory: Map<String, List<Double>> = emptyMap(),
)

data class TelemetryView(
    /** The machine shown in detail and polled every 2 s. */
    val daemonId: String? = null,
    /** Every machine read so far, the selected one included; one history per machine. */
    val machines: Map<String, MachineSnapshot> = emptyMap(),
    val operationPending: Boolean = false,
    val operationResult: String? = null,
) {
    private val selected: MachineSnapshot? get() = daemonId?.let(machines::get)
    val information: MachineInformation? get() = selected?.information
    val loading: Boolean get() = selected?.loading == true
    val error: String? get() = selected?.error
    val cpuHistory: List<Double> get() = selected?.cpuHistory.orEmpty()
    val gpuHistory: Map<String, List<Double>> get() = selected?.gpuHistory.orEmpty()
}

/**
 * The selected machine's live telemetry (every 2 s while shown) and its
 * power and update operations. Confined to the core dispatcher.
 */
class MachineTelemetry(private val sessions: MachineSessions, private val scope: CoroutineScope) {
    private val mutableView = MutableStateFlow(TelemetryView())
    val view: StateFlow<TelemetryView> = mutableView.asStateFlow()
    private var poller: Job? = null
    private var generation = 0L
    private var pendingKey: Pair<MachineOperationAction, String>? = null

    /** Shows [daemonId] while [active]; switching machines resets the operation state, not what was read. */
    fun select(daemonId: String?, active: Boolean) {
        if (daemonId != view.value.daemonId) {
            generation++
            pendingKey = null
            mutableView.update { it.copy(daemonId = daemonId, operationPending = false, operationResult = null) }
        }
        poller?.cancel()
        if (daemonId == null || !active) return
        val bound = generation
        poller = scope.launch {
            while (bound == generation) {
                refresh(bound)
                delay(INTERVAL)
            }
        }
    }

    private suspend fun refresh(bound: Long) {
        val daemonId = view.value.daemonId ?: return
        read(daemonId)
    }

    /** Reads every machine in [daemonIds] once, four at a time, e.g. for the machine list. */
    suspend fun refreshAll(daemonIds: List<String>) = coroutineScope {
        val permits = Semaphore(PARALLEL_READS)
        daemonIds.distinct().map { daemonId -> launch { permits.withPermit { read(daemonId) } } }.joinAll()
    }

    /** Records why [daemonId] cannot be read now, e.g. it is offline. */
    fun unavailable(daemonId: String, message: String) = change(daemonId) { it.copy(loading = false, error = message) }

    private suspend fun read(daemonId: String) {
        if (view.value.machines[daemonId]?.loading == true) return
        change(daemonId) { it.copy(loading = true, error = null) }
        try {
            val info = withDeadline(15.seconds) { sessions.call(daemonId) { it.GetMachineInformation().execute(Unit) } }
            change(daemonId) { state ->
                val gpuHistory = info.gpu?.devices.orEmpty().associate { device ->
                    val previous = state.gpuHistory[device.id].orEmpty()
                    device.id to (device.utilization_percent?.let { (previous + it).takeLast(HISTORY) } ?: previous)
                }
                state.copy(information = info, loading = false, error = null, cpuHistory = (state.cpuHistory + info.cpu_usage_percent).takeLast(HISTORY), gpuHistory = gpuHistory)
            }
        } catch (error: Throwable) {
            change(daemonId) { it.copy(loading = false, error = if (error is CancellationException) it.error else Failures.message(error)) }
            if (error is CancellationException) throw error
        }
    }

    private fun change(daemonId: String, update: (MachineSnapshot) -> MachineSnapshot) =
        mutableView.update { it.copy(machines = it.machines + (daemonId to update(it.machines[daemonId] ?: MachineSnapshot()))) }

    /**
     * Restarts, shuts down, or updates the machine. The idempotency key is
     * created once per confirmed action and reused for a bounded retry, so a
     * lost reply never schedules the action twice.
     */
    suspend fun perform(action: MachineOperationAction): MachineOperationResponse? {
        val daemonId = view.value.daemonId ?: return null
        if (view.value.operationPending) return null
        if (!MachineOperations.available(view.value.information, action)) throw CoreException(FailureKind.PERMANENT, MachineOperations.unavailableReason(view.value.information, action) ?: "This machine does not support that operation.")
        val bound = generation
        val key = pendingKey?.takeIf { it.first == action }?.second ?: Uuid.random().toString().also { pendingKey = action to it }
        val request = MachineOperationRequest(action = action, confirmation = MachineOperations.confirmation(action), idempotency_key = key)
        mutableView.update { it.copy(operationPending = true, operationResult = null) }
        try {
            var attempt = 0
            while (true) {
                try {
                    val response = withDeadline(60.seconds) { sessions.call(daemonId) { it.PerformMachineOperation().execute(request) } }
                    pendingKey = null
                    if (bound == generation) mutableView.update { it.copy(operationResult = response.message.ifEmpty { "Machine operation accepted." }) }
                    return response
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    if (Failures.isRetryableRead(error) && attempt++ < 1) continue
                    throw error
                }
            }
        } finally {
            if (bound == generation) mutableView.update { it.copy(operationPending = false) }
        }
    }

    private companion object {
        val INTERVAL = 2.seconds
        const val HISTORY = 12
        const val PARALLEL_READS = 4
    }
}

object MachineOperations {
    fun confirmation(action: MachineOperationAction): String = when (action) {
        MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART -> "RESTART"
        MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN -> "SHUT DOWN"
        MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON -> "UPDATE"
        else -> ""
    }

    /** Explicit capabilities win; older daemons only report restart and shutdown flags. */
    fun available(info: MachineInformation?, action: MachineOperationAction): Boolean {
        info ?: return false
        info.operation_capabilities.firstOrNull { it.action == action }?.let { return it.supported && it.authorized }
        return when (action) {
            MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART -> info.supports_restart
            MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN -> info.supports_shutdown
            else -> false
        }
    }

    fun unavailableReason(info: MachineInformation?, action: MachineOperationAction): String? =
        info?.operation_capabilities?.firstOrNull { it.action == action && !(it.supported && it.authorized) }?.unavailable_reason?.ifEmpty { null }
}

/** Gateway-side machine management: rename and revoke. */
object MachineAdmin {
    /** A display name stored on the gateway and shown on every signed-in client. */
    suspend fun rename(gateway: GatewayServiceClient, daemonId: String, name: String): Daemon {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed.length > 80) throw CoreException(FailureKind.PERMANENT, "daemon name is required and must be at most 80 characters")
        return withDeadline(15.seconds) { gateway.RenameDaemon().execute(RenameDaemonRequest(daemon_id = daemonId, name = trimmed)) }
    }

    /** The machine loses gateway and direct access until it is enrolled again. */
    suspend fun revoke(gateway: GatewayServiceClient, daemonId: String) {
        withDeadline(15.seconds) { gateway.RevokeDaemon().execute(DaemonRef(daemon_id = daemonId)) }
    }
}

enum class BackgroundMode(val wire: String, val title: String, val detail: String) {
    /** Always connected; highest battery use. */
    LIVE("live", "Live", "Always connected · highest battery use"),

    /** Live while work is active; otherwise checks about every minute. */
    PERIODIC("periodic", "Smart", "Live for active work; otherwise checks about every minute"),

    /** Sleeps until the app opens. */
    APP_ONLY("app_only", "App only", "Sleeps completely until Dieter is opened");

    val usesBackgroundService: Boolean get() = this != APP_ONLY

    companion object {
        fun parse(value: String?): BackgroundMode = entries.firstOrNull { it.wire == value } ?: LIVE
    }
}

/**
 * When a mobile client stays connected in the background. The core owns the
 * policy and its timing; Android owns the service, wake lock, and notification.
 */
object BackgroundPolicy {
    const val MODE_KEY = "background_sync_mode"
    const val DESIRED_KEY = "desired_connected"
    val POLL_INTERVAL = 60.seconds
    val WINDOW_TIMEOUT = 30.seconds

    fun shouldRun(desired: Boolean, mode: BackgroundMode, foreground: Boolean, serviceActive: Boolean, periodicWindow: Boolean, widgetRefresh: Boolean = false): Boolean =
        desired && (widgetRefresh || foreground || (serviceActive && (mode == BackgroundMode.LIVE || (mode == BackgroundMode.PERIODIC && periodicWindow))))

    /** Work that keeps a periodic window awake: running agents or undelivered changes. */
    fun hasActiveWork(items: List<Card>, outbox: OutboxView): Boolean =
        items.any { Runtimes.isActive(it.runtime) } || outbox.pendingCardIds.isNotEmpty() || outbox.pendingMessageIds.isNotEmpty() ||
            outbox.machines.values.any { it.itemCount > 0 || it.retrying }

    /** Read synchronously at boot, before the core starts. */
    fun shouldAutostart(settings: DeviceSettings): Boolean =
        (settings.string(DESIRED_KEY)?.toBooleanStrictOrNull() ?: true) && BackgroundMode.parse(settings.string(MODE_KEY)).usesBackgroundService
}

/** Whether a peer replication problem is worth showing now. Mirrors the daemon's own rule. */
object PeerSyncHealth {
    private val transient = setOf("Unavailable", "unavailable", "DeadlineExceeded", "deadline", "ResourceExhausted", "Aborted")

    fun isCurrent(issue: PeerSyncDiagnostic, peerOnline: Boolean, now: Instant): Boolean {
        if (issue.failure_code.isEmpty()) return false
        if (issue.record_id.isNotEmpty() || issue.record_kind.isNotEmpty() || issue.field_.isNotEmpty()) return true
        if (issue.failure_code.equals("canceled", ignoreCase = true)) return false
        if (issue.failure_code in transient) {
            val attempt = Timestamps.parse(issue.last_attempt_at) ?: return false
            val age = now - attempt
            return peerOnline && !age.isNegative() && age < 5.minutes
        }
        return true
    }

    /** One line per affected pair, only while connected and the reporter is online. */
    fun warnings(
        reporterName: String,
        reporterOnline: Boolean,
        connected: Boolean,
        issues: List<PeerSyncDiagnostic>,
        peers: Map<String, Pair<String, Boolean>>,
        now: Instant,
    ): List<String> {
        if (!connected || !reporterOnline) return emptyList()
        return issues.filter { isCurrent(it, peers[it.peer_id]?.second == true, now) }.map { issue ->
            val peer = peers[issue.peer_id]?.first
            if (issue.record_id.isNotEmpty() || issue.record_kind.isNotEmpty()) {
                "Shared updates between $reporterName and ${peer ?: "another machine"} are blocked by a rejected record."
            } else {
                "Shared updates between $reporterName and ${peer ?: "another machine"} are delayed."
            }
        }.distinct()
    }
}
