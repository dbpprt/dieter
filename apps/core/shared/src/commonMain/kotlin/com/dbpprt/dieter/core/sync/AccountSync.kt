package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.ChangesCursor
import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.WorkspaceStore
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * The account view from every machine's change stream: one replica per machine, joined per register
 * and projected. No machine is special; any order of frames from any number of machines converges
 * to the same view. Each machine's applied view is persisted, so a cold start renders at once and
 * resumes every stream where it left off. The view goes to [store]. Confined to the core
 * dispatcher.
 */
class AccountSync(
    private val store: WorkspaceStore,
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val logger: CoreLogger,
    private val persistDebounce: Duration = 2.seconds,
) {
    private var storage: CoreStorage? = null
    private val replicas = LinkedHashMap<String, MachineReplica>()
    private val records = AccountRecords()
    private val projector = AccountProjector()
    private val unsaved = HashSet<String>()
    private var persistJob: Job? = null
    private var projectJob: Job? = null

    private val mutableSnapshot = MutableStateFlow(AccountSnapshot())

    /** The current account view. */
    val snapshot: StateFlow<AccountSnapshot> = mutableSnapshot.asStateFlow()

    private val mutableUpdatedAt = MutableStateFlow<Map<String, Instant>>(emptyMap())

    /** Machine ID → when its view last changed; kept with the cached view. */
    val updatedAt: StateFlow<Map<String, Instant>> = mutableUpdatedAt.asStateFlow()

    private val mutableLoaded = MutableStateFlow(false)

    /** Some machine's complete view, live or cached, has been applied. */
    val loaded: StateFlow<Boolean> = mutableLoaded.asStateFlow()

    /** Switches to [storage] (one gateway's namespace), restoring every machine's cached view. */
    fun bind(storage: CoreStorage?) {
        if (storage?.directory == this.storage?.directory) return
        flush()
        persistJob?.cancel()
        this.storage = storage
        replicas.clear()
        records.clear()
        projector.clear()
        unsaved.clear()
        val updated = HashMap<String, Instant>()
        for (name in storage?.names().orEmpty()) {
            val machineId = decodeMachineId(name) ?: continue
            val frame =
                runCatching { storage?.read(name)?.let(ChangesFrame.ADAPTER::decode) }
                    .onFailure {
                        logger.warn(TAG, "discarding an unreadable cached view of $machineId", it)
                    }
                    .getOrNull() ?: continue
            replicas[machineId] = MachineReplica(machineId, frame)
            storage?.read(updatedName(machineId))?.decodeToString()?.trim()?.toLongOrNull()?.let {
                updated[machineId] = Instant.fromEpochMilliseconds(it)
            }
        }
        records.update(replicas.values, replicas.values.flatMap { it.recordKeys }.toSet())
        mutableUpdatedAt.value = updated
        publish()
    }

    /** Where [machineId]'s stream resumes; null starts it from the beginning. */
    fun cursor(machineId: String): ChangesCursor? = replicas[machineId]?.cursor

    fun replica(machineId: String): MachineReplica? = replicas[machineId]

    /** Machines that observed every version of the register [key]. */
    fun observers(key: String): List<String> = records[key]?.observers.orEmpty()

    /** Applies a frame, publishing a complete view before its stream may report Live. */
    fun apply(machineId: String, frame: ChangesFrame): ReplicaChange {
        val replica = replicas.getOrPut(machineId) { MachineReplica(machineId) }
        val before = replica.cursor
        val change = replica.apply(frame)
        if (change.records.isNotEmpty()) records.update(replicas.values, change.records)
        if (change.any) {
            mutableUpdatedAt.value = mutableUpdatedAt.value + (machineId to clock.now())
            scheduleProjection()
        }
        if (change.any || replica.cursor != before) schedulePersist(machineId)
        // Live is also the readiness barrier for widgets and Smart background
        // windows. They must inspect the state this cursor covers, rather than
        // the previous projection while scheduleProjection is still queued.
        if (
            frame.caught_up &&
                !replica.replaying &&
                (projectJob != null || mutableLoaded.value != replicas.values.any { it.hasView })
        )
            publish()
        return change
    }

    /** [machineId] left the account: its view and cache go. */
    fun forget(machineId: String) {
        val replica = replicas.remove(machineId) ?: return
        unsaved.remove(machineId)
        storage?.delete(fileName(machineId))
        storage?.delete(updatedName(machineId))
        records.update(replicas.values, replica.recordKeys)
        mutableUpdatedAt.value = mutableUpdatedAt.value - machineId
        scheduleProjection()
    }

    /** Forgets every machine but [machineIds], e.g. those the account still lists. */
    fun retain(machineIds: Set<String>) {
        for (machineId in replicas.keys.filter { it !in machineIds }) forget(machineId)
    }

    /**
     * Replays every machine's stream from the beginning, e.g. for a clean sync. Each machine's view
     * stays shown until its replay caught up.
     */
    fun rewind() {
        for ((machineId, replica) in replicas) {
            replica.rewind()
            schedulePersist(machineId)
        }
    }

    /**
     * Projects now instead of waiting for the dispatcher, e.g. before reading the view in a test.
     */
    fun publish() {
        projectJob?.cancel()
        projectJob = null
        val snapshot = projector.project(records, replicas.values)
        val loaded = replicas.values.any { it.hasView }
        mutableSnapshot.value = snapshot
        mutableLoaded.value = loaded
        store.applyDirectory(snapshot.directory, loaded)
    }

    /** Writes every machine's view that changed since it was last saved. */
    fun flush() {
        val target = storage ?: return
        for (machineId in unsaved.toList()) {
            val replica = replicas[machineId] ?: continue
            if (!replica.hasView) continue
            runCatching {
                target.write(fileName(machineId), ChangesFrame.ADAPTER.encode(replica.snapshot()))
                mutableUpdatedAt.value[machineId]?.let {
                    target.write(
                        updatedName(machineId),
                        it.toEpochMilliseconds().toString().encodeToByteArray(),
                    )
                }
            }
                .onFailure { logger.warn(TAG, "could not persist the view of $machineId", it) }
            unsaved.remove(machineId)
        }
    }

    /** Coalesces a burst of frames from any machines into one projection. */
    private fun scheduleProjection() {
        if (projectJob?.isActive == true) return
        projectJob = scope.launch {
            yield()
            projectJob = null
            publish()
        }
    }

    private fun schedulePersist(machineId: String) {
        unsaved += machineId
        if (persistJob?.isActive == true) return
        persistJob = scope.launch {
            delay(persistDebounce)
            flush()
        }
    }

    companion object {
        private const val TAG = "AccountSync"
        private const val PREFIX = "replica-"

        /** Cached machine views are named with [PREFIX] in the gateway's storage. */
        fun isCache(name: String): Boolean = name.startsWith(PREFIX)

        /**
         * The file [machineId]'s cached view is kept in, a [MachineReplica.snapshot]; tools that
         * seed a view write it there.
         */
        fun cacheName(machineId: String): String = fileName(machineId)

        // Daemon IDs are URL-safe; keep the names readable and reversible.
        private fun fileName(machineId: String) = "$PREFIX${machineId.replace("/", "%2F")}.pb"

        private fun updatedName(machineId: String) =
            "$PREFIX${machineId.replace("/", "%2F")}.updated"

        private fun decodeMachineId(name: String): String? =
            name
                .takeIf { it.startsWith(PREFIX) && it.endsWith(".pb") }
                ?.removePrefix(PREFIX)
                ?.removeSuffix(".pb")
                ?.replace("%2F", "/")
    }
}
