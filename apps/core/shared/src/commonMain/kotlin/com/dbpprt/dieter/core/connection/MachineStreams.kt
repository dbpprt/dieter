package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.api.v1.ChangesRequest
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.sync.AccountSync
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** How current one machine's part of the account view is. */
enum class SyncState {
    /** No frame from it in this session yet; its cached view, if any, shows meanwhile. */
    CONNECTING,

    /** Replaying what changed since its cached view. */
    CATCHING_UP,

    /** Caught up, with heartbeats on time. */
    LIVE,

    /** Online, but its stream has been failing past the grace period; its view may be old. */
    STALE,

    /** Not online; its view is the cached one. */
    OFFLINE,

    /** Below the release the gateway requires; it is not read. */
    INCOMPATIBLE,
}

/**
 * [state] of one machine's stream. [since] is when its view was last
 * current, for stale and offline machines. [interruptedAt] marks a stream
 * that broke and is still within its grace period; it keeps its state.
 */
data class MachineSync(
    val state: SyncState = SyncState.CONNECTING,
    val since: Instant? = null,
    val error: String? = null,
    val interruptedAt: Instant? = null,
) {
    /** Caught up; a reconnect within the grace period stays live. */
    val live: Boolean get() = state == SyncState.LIVE

    /** Caught up, and its stream is open now. */
    val current: Boolean get() = live && interruptedAt == null

    /** Its cards may show old data. */
    val stale: Boolean get() = state == SyncState.STALE || state == SyncState.OFFLINE

    /** "Live", "Catching up", "Connecting", "Not responding", "Offline", "Update required". */
    val label: String
        get() = when (state) {
            SyncState.CONNECTING -> "Connecting"
            SyncState.CATCHING_UP -> "Catching up"
            SyncState.LIVE -> "Live"
            SyncState.STALE -> "Not responding"
            SyncState.OFFLINE -> "Offline"
            SyncState.INCOMPATIBLE -> "Update required"
        }
}

object MachineSyncs {
    /** What a card shows while its owner's view is old: "Studio is offline", "Studio is not responding", "Studio needs an update"; null while current. */
    fun staleness(sync: MachineSync?, name: String): String? = when (sync?.state) {
        SyncState.OFFLINE -> "$name is offline"
        SyncState.STALE -> "$name is not responding"
        SyncState.INCOMPATIBLE -> "$name needs an update"
        else -> null
    }

    /** Every online, compatible machine in [directory] is caught up over an open stream; true when there is none. */
    fun current(directory: MachineDirectory, syncs: Map<String, MachineSync>): Boolean =
        directory.all.filter { it.online(directory.evaluatedAt) && it.compatible }.all { syncs[it.id]?.current == true }
}

data class StreamConfig(
    val heartbeat: Duration = 5.seconds,
    /** Silence that declares a stream dead; daemons heartbeat even while idle. */
    val silence: Duration = 15.seconds,
    /** A broken stream that recovers within this shows no staleness: token cuts and route changes stay invisible. */
    val grace: Duration = 10.seconds,
)

/**
 * One change stream per online, compatible machine, each with its own
 * backoff and cursor, all feeding [AccountSync]. Streams start and stop with
 * presence; a failing machine never affects another. Confined to the core
 * dispatcher.
 */
class MachineStreams(
    private val sessions: MachineSessions,
    private val sync: AccountSync,
    private val config: StreamConfig,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    private val mutableSyncs = MutableStateFlow<Map<String, MachineSync>>(emptyMap())

    /** Machine ID → how current its view is, for every enrolled machine. */
    val syncs: StateFlow<Map<String, MachineSync>> = mutableSyncs.asStateFlow()

    private val streams = HashMap<String, Job>()

    /**
     * Keeps a stream open to every online, compatible machine in [directory]
     * for one gateway session, until cancelled, and accounts for the others.
     */
    suspend fun run(directory: StateFlow<MachineDirectory>): Nothing = coroutineScope {
        try {
            directory.collect { machines ->
                val wanted = machines.all.filter { it.online(machines.evaluatedAt) && it.compatible }.associateBy { it.id }
                for (id in streams.keys - wanted.keys) streams.remove(id)?.cancel()
                for ((id, machine) in wanted) if (streams[id]?.isActive != true) streams[id] = launch { stream(machine) }
                mutableSyncs.update { current ->
                    machines.all.associate { machine ->
                        val previous = current[machine.id]
                        machine.id to when {
                            !machine.compatible -> MachineSync(SyncState.INCOMPATIBLE)
                            machine.id !in wanted -> MachineSync(SyncState.OFFLINE, since = previous?.lastCurrent(clock.now()))
                            previous == null || previous.state == SyncState.OFFLINE || previous.state == SyncState.INCOMPATIBLE ->
                                MachineSync(SyncState.CONNECTING, since = previous?.since)
                            else -> previous
                        }
                    }
                }
            }
            error("the machine directory ended")
        } finally {
            streams.values.forEach(Job::cancel)
            streams.clear()
            // The session ended, not the machines: their streams are interrupted, within grace.
            val now = clock.now()
            mutableSyncs.update { current -> current.mapValues { (_, sync) -> sync.interrupted(now, null) } }
        }
    }

    /** Streams [machine]'s changes until cancelled, resuming after each failure. */
    private suspend fun stream(machine: Machine) {
        var attempt = 0
        while (true) {
            try {
                sessions.call(machine.id) { client ->
                    coroutineScope {
                        val call = client.WatchChanges()
                        val frames = call.executeIn(this, ChangesRequest(after = sync.cursor(machine.id), heartbeat_ms = config.heartbeat.inWholeMilliseconds.toInt()))
                        try {
                            while (true) {
                                val received = withTimeoutOrNull(config.silence) { frames.receiveCatching() }
                                    ?: throw CoreException(FailureKind.TRANSIENT, "${machine.name} stopped sending changes.")
                                val frame = received.getOrNull()
                                    ?: throw received.exceptionOrNull() ?: CoreException(FailureKind.TRANSIENT, "${machine.name}'s change stream ended.")
                                sync.apply(machine.id, frame)
                                attempt = 0
                                val caughtUp = frame.caught_up && sync.replica(machine.id)?.replaying != true
                                set(machine.id, MachineSync(if (caughtUp) SyncState.LIVE else SyncState.CATCHING_UP))
                            }
                        } finally {
                            call.cancel()
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                val message = Failures.message(error)
                logger.info(TAG, "changes from ${machine.id} ended: $message")
                val now = clock.now()
                mutableSyncs.update { current -> current + (machine.id to (current[machine.id] ?: MachineSync()).interrupted(now, message)) }
            }
            delay(Backoff.STREAM.delay(attempt++))
        }
    }

    /** Turns streams broken longer than the grace period stale. Runs for the core's lifetime. */
    suspend fun expire(): Nothing {
        while (true) {
            val now = clock.now()
            val next = mutableSyncs.value.values.mapNotNull { it.interruptedAt?.plus(config.grace) }.minOrNull()
            if (next != null && next <= now) {
                mutableSyncs.update { current ->
                    current.mapValues { (_, sync) ->
                        val interrupted = sync.interruptedAt
                        if (interrupted != null && interrupted + config.grace <= now) {
                            MachineSync(SyncState.STALE, since = if (sync.state == SyncState.LIVE) interrupted else sync.since, error = sync.error)
                        } else {
                            sync
                        }
                    }
                }
                continue
            }
            delay(next?.let { (it - now).coerceAtLeast(Duration.ZERO) } ?: config.grace)
        }
    }

    private fun set(machineId: String, sync: MachineSync) {
        mutableSyncs.update { current -> if (current[machineId] == sync) current else current + (machineId to sync) }
    }

    /** When a view that stops being current now was last current. */
    private fun MachineSync.lastCurrent(now: Instant): Instant? = when (state) {
        SyncState.LIVE -> interruptedAt ?: now
        else -> since
    }

    /** A stream that just broke: it keeps its state for the grace period; a stale one stays stale. */
    private fun MachineSync.interrupted(now: Instant, message: String?): MachineSync = when (state) {
        SyncState.LIVE, SyncState.CONNECTING, SyncState.CATCHING_UP -> copy(error = message ?: error, interruptedAt = interruptedAt ?: now)
        SyncState.STALE -> copy(error = message ?: error)
        SyncState.OFFLINE, SyncState.INCOMPATIBLE -> this
    }

    /** The gateway session ended: every stream is gone, views stay cached. */
    fun reset() {
        mutableSyncs.value = emptyMap()
    }

    private companion object {
        const val TAG = "MachineStreams"
    }
}
