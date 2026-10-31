package com.getdieter.core.navigation

import com.getdieter.api.v1.KVDeleteRequest
import com.getdieter.api.v1.KVEntry
import com.getdieter.api.v1.KVMoveRequest
import com.getdieter.api.v1.KVPutRequest
import com.getdieter.api.v1.KVRef
import com.getdieter.api.v1.KVServiceClient
import com.getdieter.core.runtime.Backoff
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.KvDelete
import com.getdieter.core.v1.KvIntent
import com.getdieter.core.v1.KvMove
import com.getdieter.core.v1.KvPending
import com.getdieter.core.v1.KvPut
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

/** Reaches one machine's KV service. */
interface KvMachines {
    suspend fun <T> call(machineId: String, block: suspend (KVServiceClient) -> T): T
}

/** [KvMachines] over this device's shared data planes. */
fun MachineSessions.kvMachines(): KvMachines =
    object : KvMachines {
        override suspend fun <T> call(machineId: String, block: suspend (KVServiceClient) -> T): T =
            this@kvMachines.call(machineId, block)
    }

/**
 * An account-wide, replicated key-value namespace on the daemons (SharedKV). Its entries are the
 * account view's joined records ([apply]). Edits are queued durably per gateway and delivered in
 * order to a reachable machine, this device's first. A machine that has not yet seen what this
 * client shows of the key (or of a move's neighbours) never receives the edit, so a lagging machine
 * never rolls a change back: the next reachable machine that has seen it takes the edit, and only
 * when none has is the edit waited on. Confined to the core dispatcher.
 */
class SharedKv(
    private val namespace: String,
    private val machines: KvMachines,
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
        pending =
            storage
                ?.read(file)
                ?.let { runCatching { KvPending.ADAPTER.decode(it).intents }.getOrNull() }
                .orEmpty()
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
        enqueue(
            listOf(
                KvIntent(
                    id = newId(),
                    key = key,
                    put = KvPut(value_json = value, requires_existing = requiresExisting),
                )
            )
        )

    fun delete(key: String) =
        enqueue(listOf(KvIntent(id = newId(), key = key, delete = KvDelete())))

    fun move(key: String, parent: String, after: String = "", before: String = "") =
        enqueue(
            listOf(
                KvIntent(
                    id = newId(),
                    key = key,
                    move = KvMove(parent = parent, after = after, before = before),
                )
            )
        )

    /** Queues several edits atomically, in order. */
    fun enqueue(intents: List<KvIntent>) {
        if (intents.isEmpty()) return
        if (storage == null)
            throw CoreException(
                FailureKind.TRANSIENT,
                "Connect to an account before organizing navigation.",
            )
        for (intent in intents) {
            val value = intent.put?.value_json ?: continue
            if (value.size > MAX_VALUE_BYTES)
                throw CoreException(FailureKind.PERMANENT, "Shared values must be at most 32 KiB.")
        }
        if (pending.size + intents.size > MAX_PENDING) {
            throw CoreException(
                FailureKind.PERMANENT,
                "Navigation has 1,024 pending edits. Reconnect before editing more.",
            )
        }
        val previous = pending
        pending = pending + intents
        try {
            persist()
        } catch (error: Throwable) {
            pending = previous
            mutableStatus.update {
                it.copy(localError = "Could not save navigation changes on this device.")
            }
            throw CoreException(
                FailureKind.OUT_OF_STORAGE,
                "Could not save navigation changes on this device.",
                error,
            )
        }
        mutableStatus.update { it.copy(pending = pending.size, localError = null) }
        publish()
        wake.trySend(Unit)
    }

    // --- Delivery ----------------------------------------------------------

    /**
     * Delivers queued edits until cancelled to the machines [reachable] lists, the first preferred.
     * [caughtUp] says whether some machine's complete view is applied.
     */
    suspend fun run(reachable: Flow<List<String>>, caughtUp: Flow<Boolean>): Nothing =
        coroutineScope {
            val targets = MutableStateFlow<List<String>>(emptyList())
            launch {
                caughtUp.collect { value -> mutableStatus.update { it.copy(caughtUp = value) } }
            }
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
        // Machines passed over for the head edit: behind what this client shows, or failing before
        // the edit was prepared for them. Each edit asks this device's preferred machine first.
        var head = ""
        val passed = HashSet<String>()
        var failing = false
        while (true) {
            val intent = pending.firstOrNull()
            if (intent?.id != head) {
                head = intent?.id.orEmpty()
                passed.clear()
                failing = false
            }
            val candidates = intent?.let { candidates(it, targets.value) }.orEmpty()
            if (intent == null || candidates.isEmpty()) {
                if (intent != null && intent.daemon_id.isNotEmpty()) {
                    mutableStatus.update {
                        it.copy(
                            deliveryError =
                                "A pending navigation edit awaits its accepting machine."
                        )
                    }
                }
                wake.receive()
                continue
            }
            val target = candidates.firstOrNull { it.first !in passed }
            if (target == null) {
                // No reachable machine can take the edit yet: wait, then ask them all again.
                if (!failing) {
                    mutableStatus.update {
                        it.copy(
                            deliveryError =
                                "Waiting for a machine to receive earlier navigation edits."
                        )
                    }
                }
                delay(if (failing) Backoff.NAVIGATION.delay(attempt++) else COVER_WAIT)
                passed.clear()
                failing = false
                continue
            }
            val (machineId, accepting) = target
            val gen = generation
            // Once prepared, the edit belongs to this machine: only its receipt makes a retry
            // idempotent.
            var bound = intent.prepared.size > 0
            try {
                val prepared =
                    if (bound) intent
                    else
                        when (val preparation = prepare(machineId, accepting, intent)) {
                            Preparation.Dropped -> continue
                            Preparation.Behind -> {
                                passed += machineId
                                continue
                            }
                            is Preparation.Ready -> preparation.intent
                        }
                bound = true
                if (gen != generation) continue
                val result =
                    machines.call(machineId) { client ->
                        when {
                            prepared.move != null ->
                                client
                                    .MoveKV()
                                    .execute(KVMoveRequest.ADAPTER.decode(prepared.prepared))
                            prepared.delete != null ->
                                client
                                    .DeleteKV()
                                    .execute(KVDeleteRequest.ADAPTER.decode(prepared.prepared))
                            else ->
                                client
                                    .PutKV()
                                    .execute(KVPutRequest.ADAPTER.decode(prepared.prepared))
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
                        replaceHead(intent.id) {
                            it.copy(id = newId(), prepared = ByteString.EMPTY, daemon_id = "")
                        }
                        delay(ABORTED_RETRY)
                    }
                    Failures.kind(error) == FailureKind.PERMANENT -> {
                        // Retrying an invalid edit can never succeed; drop it instead of blocking
                        // the queue.
                        logger.warn(
                            TAG,
                            "dropping navigation edit ${intent.key}: ${Failures.message(error)}",
                        )
                        pop(intent.id)
                        mutableStatus.update { it.copy(deliveryError = Failures.message(error)) }
                    }
                    error is CoreException && error.kind == FailureKind.OUT_OF_STORAGE -> {
                        mutableStatus.update {
                            it.copy(
                                localError = "Could not save navigation changes on this device."
                            )
                        }
                        wake.receive()
                    }
                    // Nothing was sent for this edit yet, e.g. the machine is too busy to read
                    // the key: the next reachable machine may take it.
                    !bound -> {
                        passed += machineId
                        failing = true
                        mutableStatus.update { it.copy(deliveryError = Failures.message(error)) }
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
     * Where [intent] may go, preferred first: a prepared edit only to the machine it was prepared
     * for, since only that machine's receipt makes a retry idempotent; a new one to any reachable
     * machine with an applied view.
     */
    private fun candidates(
        intent: KvIntent,
        reachable: List<String>,
    ): List<Pair<String, KvAcceptor>> = reachable.mapNotNull { machineId ->
        acceptor(machineId)
            ?.takeIf { intent.daemon_id.isEmpty() || it.daemonId == intent.daemon_id }
            ?.let { machineId to it }
    }

    private sealed interface Preparation {
        /** The exact request, persisted for the machine it was prepared for. */
        data class Ready(val intent: KvIntent) : Preparation

        /** The machine has not seen what this client shows of the key or a move's neighbours. */
        data object Behind : Preparation

        /** The edit no longer applies and left the queue. */
        data object Dropped : Preparation
    }

    /** Builds the exact request for [intent] against the key's current revision on [machineId]. */
    private suspend fun prepare(
        machineId: String,
        accepting: KvAcceptor,
        intent: KvIntent,
    ): Preparation {
        val current = get(machineId, accepting.account, intent.key)
        if (!seen(intent.key, current)) return Preparation.Behind
        if (intent.put?.requires_existing == true && (current == null || current.deleted)) {
            pop(intent.id)
            return Preparation.Dropped
        }
        val ref = KVRef(namespace = namespace, key = intent.key, account = accepting.account)
        val revision = current?.revision.orEmpty()
        val move = intent.move
        val bytes =
            when {
                move != null -> {
                    // A move anchors on its neighbours as this client shows them, e.g. where an
                    // earlier edit of this client placed them.
                    val afterEntry = get(machineId, accepting.account, move.after)
                    val beforeEntry = get(machineId, accepting.account, move.before)
                    if (
                        (move.after.isNotEmpty() && !seen(move.after, afterEntry)) ||
                            (move.before.isNotEmpty() && !seen(move.before, beforeEntry))
                    )
                        return Preparation.Behind
                    var after = anchor(move.after, afterEntry, move.parent)
                    val before = anchor(move.before, beforeEntry, move.parent)
                    // Neighbours that crossed meanwhile: keep the position relative to the later
                    // one.
                    if (after != null && before != null && after.second >= before.second)
                        after = null
                    KVMoveRequest.ADAPTER.encode(
                        KVMoveRequest(
                            ref = ref,
                            parent = move.parent,
                            after_key = after?.first.orEmpty(),
                            before_key = before?.first.orEmpty(),
                            expected_revision = revision,
                            operation_id = intent.id,
                            daemon_id = accepting.daemonId,
                        )
                    )
                }
                intent.delete != null ->
                    KVDeleteRequest.ADAPTER.encode(
                        KVDeleteRequest(
                            ref = ref,
                            expected_revision = revision,
                            operation_id = intent.id,
                            daemon_id = accepting.daemonId,
                        )
                    )
                else ->
                    KVPutRequest.ADAPTER.encode(
                        KVPutRequest(
                            ref = ref,
                            value_json = intent.put?.value_json ?: ByteString.EMPTY,
                            expected_revision = revision,
                            operation_id = intent.id,
                            daemon_id = accepting.daemonId,
                        )
                    )
            }
        val prepared = intent.copy(prepared = bytes.toByteString(), daemon_id = accepting.daemonId)
        // Persist before sending, so a crash retries the same operation.
        replaceHead(intent.id) { prepared }
        return Preparation.Ready(prepared)
    }

    /** Whether a machine holding [current] for [key] has seen everything this client shows. */
    private fun seen(key: String, current: KVEntry?): Boolean {
        val shown = acknowledged[key] ?: entries[key] ?: return true
        return covers(current, shown)
    }

    /**
     * [key] with its rank when [entry] is a usable neighbour: it exists, is live, is a position,
     * and shares the parent.
     */
    private fun anchor(key: String, entry: KVEntry?, parent: String): Pair<String, String>? {
        if (key.isEmpty() || entry == null || entry.deleted) return null
        val position = decodePosition(entry.value_json) ?: return null
        return if (position.parent == parent) key to position.rank else null
    }

    private suspend fun get(machineId: String, account: String, key: String): KVEntry? {
        if (key.isEmpty()) return null
        return try {
            machines.call(machineId) {
                it.GetKV().execute(KVRef(namespace = namespace, key = key, account = account))
            }
        } catch (error: GrpcException) {
            if (error.grpcStatus == GrpcStatus.NOT_FOUND) null else throw error
        }
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
            throw CoreException(
                FailureKind.OUT_OF_STORAGE,
                "Could not persist navigation: ${Failures.message(error)}",
                error,
            )
        }
    }

    private fun persist() {
        storage?.write(file, KvPending.ADAPTER.encode(KvPending(intents = pending)))
    }

    // --- Projection --------------------------------------------------------

    private fun publish() {
        val next = LinkedHashMap<String, ByteString>()
        for ((key, entry) in entries + acknowledged) if (!entry.deleted)
            next[key] = entry.value_json
        val shownDeleted = { key: String -> (acknowledged[key] ?: entries[key])?.deleted == true }
        for (intent in pending) {
            val move = intent.move
            val put = intent.put
            when {
                intent.delete != null -> next.remove(intent.key)
                move != null -> {
                    val prefix = intent.key.substringBefore('.') + "."
                    val positions =
                        next
                            .mapNotNull { (key, value) -> decodePosition(value)?.let { key to it } }
                            .toMap()
                    val left =
                        positions[move.after]?.rank
                            ?: if (move.before.isEmpty()) {
                                positions
                                    .filter { (key, position) ->
                                        key != intent.key &&
                                            key.startsWith(prefix) &&
                                            position.parent == move.parent
                                    }
                                    .values
                                    .maxOfOrNull { it.rank }
                                    .orEmpty()
                            } else {
                                ""
                            }
                    val right = positions[move.before]?.rank.orEmpty()
                    val rank = between(left, right) + intent.id.lowercase().replace("-", "") + "h"
                    next[intent.key] = encodePosition(KvPosition(move.parent, rank))
                }
                put != null ->
                    if (!(put.requires_existing && shownDeleted(intent.key)))
                        next[intent.key] = put.value_json
            }
        }
        mutableValues.value = next
    }

    private val file
        get() = "kv-pending-" + CoreStorage.safeName(namespace) + ".pb"

    private fun newId() = Uuid.random().toString()

    companion object {
        const val MAX_PENDING = 1_024
        const val MAX_VALUE_BYTES = 32 * 1024

        private val COVER_WAIT = 1.seconds
        private val ABORTED_RETRY = 250.milliseconds
        private const val TAG = "SharedKv"

        private const val DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

        /**
         * True when [incoming] reflects every version of [prior]: each prior clock is dominated by
         * some incoming version.
         */
        fun covers(incoming: KVEntry?, prior: KVEntry): Boolean {
            if (incoming == null) return prior.versions.isEmpty()
            return prior.versions.all { old ->
                incoming.versions.any { next ->
                    old.clock.all { (actor, count) ->
                        (next.clock[actor] ?: 0L).toULong() >= count.toULong()
                    }
                }
            }
        }

        /**
         * A local placeholder rank strictly between [left] and [right]; the daemon assigns the real
         * one.
         */
        fun between(left: String, right: String): String {
            var prefix = ""
            var bound = right
            for (index in 0 until 512) {
                val low = left.getOrNull(index)?.let { DIGITS.indexOf(it).coerceAtLeast(0) } ?: 0
                val high =
                    bound.getOrNull(index)?.let {
                        DIGITS.indexOf(it).takeIf { found -> found >= 0 } ?: 35
                    } ?: 35
                if (high - low > 1) return prefix + DIGITS[(low + high) / 2]
                prefix += DIGITS[low]
                if (high > low) bound = ""
            }
            return left + "h"
        }

        fun decodePosition(value: ByteString): KvPosition? = runCatching {
            val json = Json.parseToJsonElement(value.utf8()).jsonObject
            KvPosition(
                json["parent"]?.jsonPrimitive?.contentOrNull ?: return null,
                json["rank"]?.jsonPrimitive?.contentOrNull ?: return null,
            )
        }
            .getOrNull()

        fun encodePosition(position: KvPosition): ByteString =
            JsonObject(
                    mapOf(
                        "parent" to JsonPrimitive(position.parent),
                        "rank" to JsonPrimitive(position.rank),
                    )
                )
                .toString()
                .encodeUtf8()
    }
}
