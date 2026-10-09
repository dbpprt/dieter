package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.KVDeleteRequest
import com.dbpprt.dieter.api.v1.KVEntry
import com.dbpprt.dieter.api.v1.KVMoveRequest
import com.dbpprt.dieter.api.v1.KVPutRequest
import com.dbpprt.dieter.api.v1.KVRef
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/** Delivery health of one shared namespace. */
data class KvStatus(
    val pending: Int = 0,
    /** Some machine's complete, current view of the namespace is applied. */
    val caughtUp: Boolean = false,
    val deliveryError: String? = null,
    /** This device could not save an edit; it was not queued. */
    val localError: String? = null,
)

/** A `{"parent","rank"}` ordering value. */
data class KvPosition(val parent: String, val rank: String)

/** A machine as a KV mutation names it: its peer account and identity. */
data class KvAcceptor(val account: String, val daemonId: String)

/**
 * An account-wide, replicated key-value namespace on the daemons (SharedKV).
 * Its entries are the account view's joined records ([apply]). Edits are
 * queued durably per gateway and delivered in order to a reachable machine,
 * this device's first; a machine that has not yet seen what this client shows
 * is waited for, so a lagging machine never rolls a change back. Confined to
 * the core dispatcher.
 */
class SharedKv(
    private val namespace: String,
    private val sessions: MachineSessions,
    /** The peer account and identity of a machine whose view is applied, else null. */
    private val acceptor: (machineId: String) -> KvAcceptor?,
    private val logger: CoreLogger,
) {
    private var storage: CoreStorage? = null
    private var pending: List<KvIntent> = emptyList()
    private var entries: Map<String, KVEntry> = emptyMap()

    /** Entries machines acknowledged that the account view does not show yet. */
    private val acknowledged = LinkedHashMap<String, KVEntry>()
    private var generation = 0L
    private val wake = Channel<Unit>(Channel.CONFLATED)

    private val mutableValues = MutableStateFlow<Map<String, ByteString>>(emptyMap())

    /** Current values with this device's pending edits applied, by key. Values are JSON. */
    val values: StateFlow<Map<String, ByteString>> = mutableValues.asStateFlow()

    private val mutableStatus = MutableStateFlow(KvStatus())
    val status: StateFlow<KvStatus> = mutableStatus.asStateFlow()

    /** Switches to [storage] (one gateway), restoring its undelivered edits. */
    fun bind(storage: CoreStorage?) {
        if (storage != null && storage.directory == this.storage?.directory) return
        this.storage = storage
        generation++
        pending = storage?.read(file)?.let { runCatching { KvPending.ADAPTER.decode(it).intents }.getOrNull() }.orEmpty()
        acknowledged.clear()
        mutableStatus.update { KvStatus(pending = pending.size, caughtUp = it.caughtUp) }
        publish()
        wake.trySend(Unit)
    }

    /** The account view's entries of this namespace. */
    fun apply(entries: Map<String, KVEntry>) {
        this.entries = entries
        acknowledged.entries.removeAll { (key, entry) -> covers(entries[key], entry) }
        publish()
        wake.trySend(Unit)
    }

    // --- Edits -----------------------------------------------------------

    fun put(key: String, value: ByteString, requiresExisting: Boolean = false) =
        enqueue(listOf(KvIntent(id = newId(), key = key, put = KvPut(value_json = value, requires_existing = requiresExisting))))

    fun delete(key: String) = enqueue(listOf(KvIntent(id = newId(), key = key, delete = KvDelete())))

    fun move(key: String, parent: String, after: String = "", before: String = "") =
        enqueue(listOf(KvIntent(id = newId(), key = key, move = KvMove(parent = parent, after = after, before = before))))

    /** Queues several edits atomically, in order. */
    fun enqueue(intents: List<KvIntent>) {
        if (intents.isEmpty()) return
        if (storage == null) throw CoreException(FailureKind.TRANSIENT, "Connect to an account before organizing navigation.")
        for (intent in intents) {
            val value = intent.put?.value_json ?: continue
            if (value.size > MAX_VALUE_BYTES) throw CoreException(FailureKind.PERMANENT, "Shared values must be at most 32 KiB.")
        }
        if (pending.size + intents.size > MAX_PENDING) {
            throw CoreException(FailureKind.PERMANENT, "Navigation has 1,024 pending edits. Reconnect before editing more.")
        }
        val previous = pending
        pending = pending + intents
        try {
            persist()
        } catch (error: Throwable) {
            pending = previous
            mutableStatus.update { it.copy(localError = "Could not save navigation changes on this device.") }
            throw CoreException(FailureKind.OUT_OF_STORAGE, "Could not save navigation changes on this device.", error)
        }
        mutableStatus.update { it.copy(pending = pending.size, localError = null) }
        publish()
        wake.trySend(Unit)
    }

    // --- Delivery ----------------------------------------------------------

    /**
     * Delivers queued edits until cancelled to the machines [reachable] lists,
     * the first preferred. [caughtUp] says whether some machine's complete
     * view is applied.
     */
    suspend fun run(reachable: Flow<List<String>>, caughtUp: Flow<Boolean>): Nothing = coroutineScope {
        val targets = MutableStateFlow<List<String>>(emptyList())
        launch { caughtUp.collect { value -> mutableStatus.update { it.copy(caughtUp = value) } } }
        launch {
            reachable.collect {
                targets.value = it
                wake.trySend(Unit)
            }
        }
        deliver(targets)
    }

    private suspend fun deliver(targets: StateFlow<List<String>>): Nothing {
        var attempt = 0
        while (true) {
            val intent = pending.firstOrNull()
            val target = intent?.let { target(it, targets.value) }
            if (intent == null || target == null) {
                if (intent != null && intent.daemon_id.isNotEmpty()) {
                    mutableStatus.update { it.copy(deliveryError = "A pending navigation edit awaits its accepting machine.") }
                }
                wake.receive()
                continue
            }
            val (machineId, accepting) = target
            val gen = generation
            try {
                val prepared = if (intent.prepared.size > 0) intent else prepare(machineId, accepting, intent) ?: continue
                if (gen != generation) continue
                val result = sessions.call(machineId) { client ->
                    when {
                        prepared.move != null -> client.MoveKV().execute(KVMoveRequest.ADAPTER.decode(prepared.prepared))
                        prepared.delete != null -> client.DeleteKV().execute(KVDeleteRequest.ADAPTER.decode(prepared.prepared))
                        else -> client.PutKV().execute(KVPutRequest.ADAPTER.decode(prepared.prepared))
                    }
                }
                if (gen != generation) continue
                if (!covers(entries[intent.key], result)) acknowledged[intent.key] = result
                pop(intent.id)
                attempt = 0
                mutableStatus.update { it.copy(deliveryError = null) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (gen != generation) continue
                when {
                    // A concurrent change moved the key: prepare again from its current revision.
                    error is GrpcException && error.grpcStatus == GrpcStatus.ABORTED -> {
                        replaceHead(intent.id) { it.copy(id = newId(), prepared = ByteString.EMPTY, daemon_id = "") }
                        delay(ABORTED_RETRY)
                    }
                    Failures.kind(error) == FailureKind.PERMANENT -> {
                        // Retrying an invalid edit can never succeed; drop it instead of blocking the queue.
                        logger.warn(TAG, "dropping navigation edit ${intent.key}: ${Failures.message(error)}")
                        pop(intent.id)
                        mutableStatus.update { it.copy(deliveryError = Failures.message(error)) }
                    }
                    error is CoreException && error.kind == FailureKind.OUT_OF_STORAGE -> {
                        mutableStatus.update { it.copy(localError = "Could not save navigation changes on this device.") }
                        wake.receive()
                    }
                    else -> {
                        mutableStatus.update { it.copy(deliveryError = Failures.message(error)) }
                        delay(Backoff.NAVIGATION.delay(attempt++))
                    }
                }
            }
        }
    }

    /**
     * Where [intent] goes: a prepared edit only to the machine it was prepared
     * for, since only that machine's receipt makes a retry idempotent; a new
     * one to the first reachable machine with an applied view.
     */
    private fun target(intent: KvIntent, reachable: List<String>): Pair<String, KvAcceptor>? =
        reachable.firstNotNullOfOrNull { machineId ->
            acceptor(machineId)?.takeIf { intent.daemon_id.isEmpty() || it.daemonId == intent.daemon_id }?.let { machineId to it }
        }

    /** Builds the exact request for [intent] against the key's current revision, or null when it was dropped. */
    private suspend fun prepare(machineId: String, accepting: KvAcceptor, intent: KvIntent): KvIntent? {
        val current = get(machineId, accepting.account, intent.key)
        val shown = acknowledged[intent.key] ?: entries[intent.key]
        if (shown != null && !covers(current, shown)) {
            mutableStatus.update { it.copy(deliveryError = "Waiting for this machine to receive earlier navigation edits.") }
            delay(COVER_WAIT)
            return null
        }
        if (intent.put?.requires_existing == true && (current == null || current.deleted)) {
            pop(intent.id)
            return null
        }
        val ref = KVRef(namespace = namespace, key = intent.key, account = accepting.account)
        val revision = current?.revision.orEmpty()
        val move = intent.move
        val bytes = when {
            move != null -> {
                var after = anchor(machineId, accepting.account, move.after, move.parent)
                val before = anchor(machineId, accepting.account, move.before, move.parent)
                // Neighbours that crossed meanwhile: keep the position relative to the later one.
                if (after != null && before != null && after.second >= before.second) after = null
                KVMoveRequest.ADAPTER.encode(
                    KVMoveRequest(
                        ref = ref, parent = move.parent, after_key = after?.first.orEmpty(), before_key = before?.first.orEmpty(),
                        expected_revision = revision, operation_id = intent.id, daemon_id = accepting.daemonId,
                    ),
                )
            }
            intent.delete != null -> KVDeleteRequest.ADAPTER.encode(KVDeleteRequest(ref = ref, expected_revision = revision, operation_id = intent.id, daemon_id = accepting.daemonId))
            else -> KVPutRequest.ADAPTER.encode(
                KVPutRequest(ref = ref, value_json = intent.put?.value_json ?: ByteString.EMPTY, expected_revision = revision, operation_id = intent.id, daemon_id = accepting.daemonId),
            )
        }
        val prepared = intent.copy(prepared = bytes.toByteString(), daemon_id = accepting.daemonId)
        // Persist before sending, so a crash retries the same operation.
        replaceHead(intent.id) { prepared }
        return prepared
    }

    /** A usable neighbour: it exists, is live, is a position, and shares the parent. */
    private suspend fun anchor(machineId: String, account: String, key: String, parent: String): Pair<String, String>? {
        if (key.isEmpty()) return null
        val entry = get(machineId, account, key)?.takeUnless { it.deleted } ?: return null
        val position = decodePosition(entry.value_json) ?: return null
        return if (position.parent == parent) key to position.rank else null
    }

    private suspend fun get(machineId: String, account: String, key: String): KVEntry? = try {
        sessions.call(machineId) { it.GetKV().execute(KVRef(namespace = namespace, key = key, account = account)) }
    } catch (error: GrpcException) {
        if (error.grpcStatus == GrpcStatus.NOT_FOUND) null else throw error
    }

    private fun pop(id: String) {
        pending = pending.filterNot { it.id == id }
        persistOrFail()
        mutableStatus.update { it.copy(pending = pending.size) }
        publish()
    }

    private fun replaceHead(id: String, change: (KvIntent) -> KvIntent) {
        pending = pending.map { if (it.id == id) change(it) else it }
        persistOrFail()
    }

    private fun persistOrFail() {
        try {
            persist()
        } catch (error: Throwable) {
            throw CoreException(FailureKind.OUT_OF_STORAGE, "Could not persist navigation: ${Failures.message(error)}", error)
        }
    }

    private fun persist() {
        storage?.write(file, KvPending.ADAPTER.encode(KvPending(intents = pending)))
    }

    // --- Projection --------------------------------------------------------

    private fun publish() {
        val next = LinkedHashMap<String, ByteString>()
        for ((key, entry) in entries + acknowledged) if (!entry.deleted) next[key] = entry.value_json
        val shownDeleted = { key: String -> (acknowledged[key] ?: entries[key])?.deleted == true }
        for (intent in pending) {
            val move = intent.move
            val put = intent.put
            when {
                intent.delete != null -> next.remove(intent.key)
                move != null -> {
                    val prefix = intent.key.substringBefore('.') + "."
                    val positions = next.mapNotNull { (key, value) -> decodePosition(value)?.let { key to it } }.toMap()
                    val left = positions[move.after]?.rank
                        ?: if (move.before.isEmpty()) {
                            positions.filter { (key, position) -> key != intent.key && key.startsWith(prefix) && position.parent == move.parent }
                                .values.maxOfOrNull { it.rank }.orEmpty()
                        } else {
                            ""
                        }
                    val right = positions[move.before]?.rank.orEmpty()
                    val rank = between(left, right) + intent.id.lowercase().replace("-", "") + "h"
                    next[intent.key] = encodePosition(KvPosition(move.parent, rank))
                }
                put != null -> if (!(put.requires_existing && shownDeleted(intent.key))) next[intent.key] = put.value_json
            }
        }
        mutableValues.value = next
    }

    private val file get() = "kv-pending-" + CoreStorage.safeName(namespace) + ".pb"

    private fun newId() = Uuid.random().toString()

    companion object {
        const val MAX_PENDING = 1_024
        const val MAX_VALUE_BYTES = 32 * 1024

        private val COVER_WAIT = 1.seconds
        private val ABORTED_RETRY = 250.milliseconds
        private const val TAG = "SharedKv"

        private const val DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

        /**
         * True when [incoming] reflects every version of [prior]: each prior
         * clock is dominated by some incoming version.
         */
        fun covers(incoming: KVEntry?, prior: KVEntry): Boolean {
            if (incoming == null) return prior.versions.isEmpty()
            return prior.versions.all { old ->
                incoming.versions.any { next -> old.clock.all { (actor, count) -> (next.clock[actor] ?: 0L).toULong() >= count.toULong() } }
            }
        }

        /** A local placeholder rank strictly between [left] and [right]; the daemon assigns the real one. */
        fun between(left: String, right: String): String {
            var prefix = ""
            var bound = right
            for (index in 0 until 512) {
                val low = left.getOrNull(index)?.let { DIGITS.indexOf(it).coerceAtLeast(0) } ?: 0
                val high = bound.getOrNull(index)?.let { DIGITS.indexOf(it).takeIf { found -> found >= 0 } ?: 35 } ?: 35
                if (high - low > 1) return prefix + DIGITS[(low + high) / 2]
                prefix += DIGITS[low]
                if (high > low) bound = ""
            }
            return left + "h"
        }

        fun decodePosition(value: ByteString): KvPosition? = runCatching {
            val json = Json.parseToJsonElement(value.utf8()).jsonObject
            KvPosition(json["parent"]?.jsonPrimitive?.contentOrNull ?: return null, json["rank"]?.jsonPrimitive?.contentOrNull ?: return null)
        }.getOrNull()

        fun encodePosition(position: KvPosition): ByteString =
            JsonObject(mapOf("parent" to JsonPrimitive(position.parent), "rank" to JsonPrimitive(position.rank))).toString().encodeUtf8()
    }
}
