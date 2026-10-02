package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.GetStateRequest
import com.dbpprt.dieter.api.v1.PeerSyncDiagnostic
import com.dbpprt.dieter.api.v1.State
import com.dbpprt.dieter.api.v1.SyncCursor
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.WorkspaceStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout

/** How current one machine's contribution to the directory is. */
data class MachineFreshness(
    val refreshedAt: Instant? = null,
    /** The last refresh failed; data shown for this machine may be old. */
    val error: String? = null,
    val peerSyncIssues: List<PeerSyncDiagnostic> = emptyList(),
)

data class PollerConfig(
    val interval: Duration = 15.seconds,
    val parallel: Int = 3,
    val timeout: Duration = 15.seconds,
)

/**
 * Refreshes every online machine except the attached one with a conditional
 * `GetState(all_projects)`. Each machine's last full view is persisted so it
 * renders offline; failures are reported per machine, never swallowed.
 */
class DirectoryPoller(
    private val sessions: MachineSessions,
    private val storage: CoreStorage,
    private val store: WorkspaceStore,
    private val config: PollerConfig,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    private val cursors = HashMap<String, SyncCursor>()
    private val mutableFreshness = MutableStateFlow<Map<String, MachineFreshness>>(emptyMap())
    val freshness: StateFlow<Map<String, MachineFreshness>> = mutableFreshness.asStateFlow()

    /** Applies every persisted machine view, for offline-first rendering. */
    fun restoreCached(exceptDaemonId: String?) {
        val snapshots = storage.names().mapNotNull { name ->
            val daemonId = decodeDaemonId(name)?.takeIf { it != exceptDaemonId } ?: return@mapNotNull null
            val state = runCatching { storage.read(name)?.let(State.ADAPTER::decode) }.getOrNull() ?: return@mapNotNull null
            state.toMachineSnapshot(daemonId)
        }
        if (snapshots.isNotEmpty()) store.applyMachines(snapshots)
    }

    /** One refresh pass over [machines]. */
    suspend fun refresh(machines: List<Machine>) = coroutineScope {
        val gate = Semaphore(config.parallel)
        val snapshots = machines.map { machine ->
            async { gate.withPermit { refresh(machine) } }
        }.awaitAll().filterNotNull()
        if (snapshots.isNotEmpty()) store.applyMachines(snapshots)
    }

    private suspend fun refresh(machine: Machine): MachineSnapshot? = try {
        val state = withTimeout(config.timeout) {
            sessions.call(machine.id) { client ->
                client.GetState().execute(GetStateRequest(all_projects = true, if_not_modified = cursors[machine.id]))
            }
        }
        state.cursor?.let { cursors[machine.id] = it }
        mutableFreshness.update { it + (machine.id to MachineFreshness(clock.now(), null, state.peer_sync_issues)) }
        if (state.not_modified) {
            MachineSnapshot(machine.id, emptyList(), emptyList(), emptyList(), emptyList(), unchanged = true)
        } else {
            runCatching { storage.write(fileName(machine.id), State.ADAPTER.encode(state.copy(peer_sync_issues = emptyList()))) }
            state.toMachineSnapshot(machine.id)
        }
    } catch (cancelled: CancellationException) {
        if (cancelled is TimeoutCancellationException) {
            reportFailure(machine.id, "Refreshing ${machine.name} timed out.")
            null
        } else {
            throw cancelled
        }
    } catch (error: Throwable) {
        reportFailure(machine.id, Failures.message(error))
        null
    }

    private fun reportFailure(daemonId: String, message: String) {
        logger.info(TAG, "directory refresh failed for $daemonId: $message")
        mutableFreshness.update { it + (daemonId to (it[daemonId] ?: MachineFreshness()).copy(error = message)) }
    }

    fun forget(daemonId: String) {
        cursors.remove(daemonId)
        mutableFreshness.update { it - daemonId }
    }

    private fun fileName(daemonId: String) = cacheName(daemonId)

    companion object {
        /** Cached machine views are named with this prefix in the gateway's storage. */
        const val CACHE_PREFIX = "machine-"
        private const val TAG = "Directory"
        private const val PREFIX = CACHE_PREFIX

        // Daemon IDs are URL-safe base64 (d_…); keep them readable and reversible.
        private fun encode(daemonId: String) = daemonId.replace("/", "%2F")

        /** The storage name of [daemonId]'s cached view; tools may seed one for an offline demo. */
        fun cacheName(daemonId: String) = "$PREFIX${encode(daemonId)}.pb"

        private fun decodeDaemonId(name: String): String? =
            name.takeIf { it.startsWith(PREFIX) && it.endsWith(".pb") }?.removePrefix(PREFIX)?.removeSuffix(".pb")?.replace("%2F", "/")
    }
}
