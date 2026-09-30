package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.KVDeleteRequest
import com.dbpprt.dieter.api.v1.KVEntry
import com.dbpprt.dieter.api.v1.KVFrame
import com.dbpprt.dieter.api.v1.KVListRequest
import com.dbpprt.dieter.api.v1.KVMoveRequest
import com.dbpprt.dieter.api.v1.KVPutRequest
import com.dbpprt.dieter.api.v1.KVRef
import com.dbpprt.dieter.api.v1.KVWatchRequest
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
import kotlin.time.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
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

/** Delivery and subscription health of one shared namespace. */
data class KvStatus(
    val account: String = "",
    val pending: Int = 0,
    /** A full replay has been applied since the machine was attached. */
    val caughtUp: Boolean = false,
    val watchError: String? = null,
    /** When the subscription started failing, so UIs can hide brief reconnects. */
    val watchErrorSince: Instant? = null,
    val deliveryError: String? = null,
    /** This device could not save an edit; it was not queued. */
    val localError: String? = null,
)

/** A `{"parent","rank"}` ordering value. */
data class KvPosition(val parent: String, val rank: String)

/**
 * An account-wide, replicated key-value namespace on the daemons (SharedKV).
 * Edits are queued durably per account and delivered in order to the
 * attached machine; the watch applies only replicas that cover what this
 * client already saw, so a lagging machine never rolls a change back.
 * Ported from the Mac and Android `SharedKV`. Confined to the core dispatcher.
 */
class SharedKv(
    private val namespace: String,
    private val sessions: MachineSessions,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    private var storage: CoreStorage? = null
    private var cache = KvCache()
    private val entries = LinkedHashMap<String, KVEntry>()
    private val replacement = LinkedHashMap<String, KVEntry>()
    private var generation = 0L
    private var servedDaemon: String? = null
    private val wake = Channel<Unit>(Channel.CONFLATED)

    private val mutableValues = MutableStateFlow<Map<String, ByteString>>(emptyMap())

    /** Current values with this device's pending edits applied, by key. Values are JSON. */
    val values: StateFlow<Map<String, ByteString>> = mutableValues.asStateFlow()

    private val mutableStatus = MutableStateFlow(KvStatus())
    val status: StateFlow<KvStatus> = mutableStatus.asStateFlow()

    /** Switches to [storage] (one gateway), restoring its last account's namespace. */
    fun bind(storage: CoreStorage?) {
        if (storage != null && storage.directory == this.storage?.directory) return
        this.storage = storage
        generation++
        servedDaemon = null
        val active = storage?.read(activeFile)?.let { runCatching { KvActive.ADAPTER.decode(it) }.getOrNull() }
        adopt(active?.account.orEmpty(), active?.daemon_id.orEmpty())
    }

    private fun adopt(account: String, daemonId: String) {
        val restored = if (account.isEmpty()) null else storage?.read(cacheFile(account, daemonId))?.let { runCatching { KvCache.ADAPTER.decode(it) }.getOrNull() }
        cache = restored ?: KvCache(account = account, daemon_id = daemonId)
        entries.clear()
        for (entry in cache.entries) entries[entry.key] = entry
        replacement.clear()
        mutableStatus.value = KvStatus(account = account, pending = cache.pending.size)
        publish()
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
        if (cache.account.isEmpty()) throw CoreException(FailureKind.TRANSIENT, "Connect to an account before organizing navigation.")
        for (intent in intents) {
            val value = intent.put?.value_json ?: continue
            if (value.size > MAX_VALUE_BYTES) throw CoreException(FailureKind.PERMANENT, "Shared values must be at most 32 KiB.")
        }
        if (cache.pending.size + intents.size > MAX_PENDING) {
            throw CoreException(FailureKind.PERMANENT, "Navigation has 1,024 pending edits. Reconnect before editing more.")
        }
        val previous = cache
        cache = cache.copy(pending = cache.pending + intents)
        try {
            persist()
        } catch (error: Throwable) {
            cache = previous
            mutableStatus.update { it.copy(localError = "Could not save navigation changes on this device.") }
            throw CoreException(FailureKind.OUT_OF_STORAGE, "Could not save navigation changes on this device.", error)
        }
        mutableStatus.update { it.copy(pending = cache.pending.size, localError = null) }
        publish()
        wake.trySend(Unit)
    }

    // --- Subscription and delivery ----------------------------------------

    /** Keeps the namespace synchronized with the attached machine, or idles while there is none. */
    suspend fun run(attached: Flow<String?>) {
        attached.distinctUntilChanged().collectLatest { daemonId ->
            generation++
            servedDaemon = null
            replacement.clear()
            mutableStatus.update { it.copy(caughtUp = false, watchError = null, watchErrorSince = null) }
            if (daemonId == null) return@collectLatest
            coroutineScope {
                launch { watch(daemonId) }
                deliver(daemonId)
            }
        }
    }

    private suspend fun watch(daemonId: String) {
        while (true) {
            try {
                val info = sessions.call(daemonId) { it.ListKV().execute(KVListRequest(namespace = namespace)) }
                val local = info.account == LOCAL_ACCOUNT
                if (info.account != cache.account || (local && info.daemon_id != cache.daemon_id)) {
                    // Late acknowledgements for the previous account are dropped by the generation.
                    generation++
                    adopt(info.account, if (local) info.daemon_id else "")
                    storage?.write(activeFile, KvActive.ADAPTER.encode(KvActive(account = info.account, daemon_id = info.daemon_id)))
                }
                servedDaemon = info.daemon_id
                wake.trySend(Unit)
                val account = info.account
                coroutineScope {
                    sessions.call(daemonId) { client ->
                        val call = client.WatchKV()
                        val frames = call.executeIn(this, KVWatchRequest(namespace = namespace, account = account))
                        try {
                            for (frame in frames) apply(frame, account)
                        } finally {
                            call.cancel()
                        }
                    }
                }
                recordWatchError("Navigation subscription ended")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                recordWatchError(Failures.message(error))
            }
            delay(WATCH_RETRY)
        }
    }

    private fun recordWatchError(message: String) {
        mutableStatus.update { it.copy(watchError = message, watchErrorSince = it.watchErrorSince ?: clock.now(), caughtUp = false) }
    }

    private fun apply(frame: KVFrame, account: String) {
        if (frame.account != account || account != cache.account) return
        if (frame.reset) replacement.clear()
        for (entry in frame.entries) replacement[entry.key] = entry
        // A paged replay is published whole, never as a partial layout.
        if (!frame.caught_up) return
        for ((key, incoming) in replacement) {
            val cached = entries[key]
            if (cached == null || covers(incoming, cached)) entries[key] = incoming
        }
        replacement.clear()
        saveEntries()
        mutableStatus.update { it.copy(caughtUp = true, watchError = null, watchErrorSince = null) }
        publish()
        wake.trySend(Unit)
    }

    private suspend fun deliver(daemonId: String) {
        var attempt = 0
        while (true) {
            val intent = cache.pending.firstOrNull()
            val served = servedDaemon
            if (intent == null || served == null) {
                wake.receive()
                continue
            }
            if (intent.daemon_id.isNotEmpty() && intent.daemon_id != served) {
                mutableStatus.update { it.copy(deliveryError = "A pending navigation edit awaits its accepting machine.") }
                wake.receive()
                continue
            }
            val gen = generation
            try {
                val prepared = if (intent.prepared.size > 0) intent else prepare(daemonId, intent, served) ?: continue
                if (gen != generation) continue
                val result = sessions.call(daemonId) { client ->
                    when {
                        prepared.move != null -> client.MoveKV().execute(KVMoveRequest.ADAPTER.decode(prepared.prepared))
                        prepared.delete != null -> client.DeleteKV().execute(KVDeleteRequest.ADAPTER.decode(prepared.prepared))
                        else -> client.PutKV().execute(KVPutRequest.ADAPTER.decode(prepared.prepared))
                    }
                }
                if (gen != generation) continue
                val cached = entries[intent.key]
                if (cached == null || covers(result, cached)) entries[intent.key] = result
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

    /** Builds the exact request for [intent] against the key's current revision, or null when it was dropped. */
    private suspend fun prepare(daemonId: String, intent: KvIntent, served: String): KvIntent? {
        val current = get(daemonId, intent.key)
        val cached = entries[intent.key]
        if (cached != null && !covers(current, cached)) {
            mutableStatus.update { it.copy(deliveryError = "Waiting for this machine to receive earlier navigation edits.") }
            delay(COVER_WAIT)
            return null
        }
        if (intent.put?.requires_existing == true && (current == null || current.deleted)) {
            pop(intent.id)
            return null
        }
        val ref = KVRef(namespace = namespace, key = intent.key, account = cache.account)
        val revision = current?.revision.orEmpty()
        val move = intent.move
        val bytes = when {
            move != null -> {
                var after = anchor(daemonId, move.after, move.parent)
                val before = anchor(daemonId, move.before, move.parent)
                // Neighbours that crossed meanwhile: keep the position relative to the later one.
                if (after != null && before != null && after.second >= before.second) after = null
                KVMoveRequest.ADAPTER.encode(
                    KVMoveRequest(
                        ref = ref, parent = move.parent, after_key = after?.first.orEmpty(), before_key = before?.first.orEmpty(),
                        expected_revision = revision, operation_id = intent.id, daemon_id = served,
                    ),
                )
            }
            intent.delete != null -> KVDeleteRequest.ADAPTER.encode(KVDeleteRequest(ref = ref, expected_revision = revision, operation_id = intent.id, daemon_id = served))
            else -> KVPutRequest.ADAPTER.encode(
                KVPutRequest(ref = ref, value_json = intent.put?.value_json ?: ByteString.EMPTY, expected_revision = revision, operation_id = intent.id, daemon_id = served),
            )
        }
        val prepared = intent.copy(prepared = bytes.toByteString(), daemon_id = served)
        // Persist before sending, so a crash retries the same operation.
        replaceHead(intent.id) { prepared }
        return prepared
    }

    /** A usable neighbour: it exists, is live, is a position, and shares the parent. */
    private suspend fun anchor(daemonId: String, key: String, parent: String): Pair<String, String>? {
        if (key.isEmpty()) return null
        val entry = get(daemonId, key)?.takeUnless { it.deleted } ?: return null
        val position = decodePosition(entry.value_json) ?: return null
        return if (position.parent == parent) key to position.rank else null
    }

    private suspend fun get(daemonId: String, key: String): KVEntry? = try {
        sessions.call(daemonId) { it.GetKV().execute(KVRef(namespace = namespace, key = key, account = cache.account)) }
    } catch (error: GrpcException) {
        if (error.grpcStatus == GrpcStatus.NOT_FOUND) null else throw error
    }

    private fun pop(id: String) {
        cache = cache.copy(pending = cache.pending.filterNot { it.id == id })
        persistOrFail()
        mutableStatus.update { it.copy(pending = cache.pending.size) }
        publish()
    }

    private fun replaceHead(id: String, change: (KvIntent) -> KvIntent) {
        cache = cache.copy(pending = cache.pending.map { if (it.id == id) change(it) else it })
        persistOrFail()
    }

    private fun persistOrFail() {
        try {
            persist()
        } catch (error: Throwable) {
            throw CoreException(FailureKind.OUT_OF_STORAGE, "Could not persist navigation: ${Failures.message(error)}", error)
        }
    }

    private fun saveEntries() = runCatching { persist() }.onFailure { logger.warn(TAG, "could not persist navigation", it) }

    private fun persist() {
        val target = storage ?: return
        if (cache.account.isEmpty()) return
        cache = cache.copy(entries = entries.values.toList())
        target.write(cacheFile(cache.account, cache.daemon_id), KvCache.ADAPTER.encode(cache))
    }

    // --- Projection --------------------------------------------------------

    private fun publish() {
        val next = LinkedHashMap<String, ByteString>()
        for ((key, entry) in entries) if (!entry.deleted) next[key] = entry.value_json
        for (intent in cache.pending) {
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
                put != null -> {
                    val tombstone = entries[intent.key]?.deleted == true
                    if (!(put.requires_existing && tombstone)) next[intent.key] = put.value_json
                }
            }
        }
        mutableValues.value = next
    }

    private val activeFile get() = activeFile(namespace)

    private fun cacheFile(account: String, daemonId: String): String = cacheFile(namespace, account, daemonId)

    private fun newId() = Uuid.random().toString()

    companion object {
        private fun activeFile(namespace: String) = "kv-active-$namespace.pb"

        private fun cacheFile(namespace: String, account: String, daemonId: String): String =
            "kv-" + CoreStorage.safeName("$namespace.$account" + if (account == LOCAL_ACCOUNT) ".$daemonId" else "") + ".pb"

        /**
         * Writes a legacy app's caches (entries and undelivered intents) into
         * [storage], one gateway's scope for [namespace]. Caches the core
         * already has win. Returns how many caches were written.
         */
        fun importInto(storage: CoreStorage, namespace: String, caches: List<KvCache>, active: KvActive?): Int {
            var written = 0
            for (cache in caches) {
                if (cache.account.isEmpty()) continue
                val name = cacheFile(namespace, cache.account, cache.daemon_id)
                if (storage.read(name) != null) continue
                storage.write(name, KvCache.ADAPTER.encode(cache.copy(pending = cache.pending.takeLast(MAX_PENDING))))
                written++
            }
            if (active != null && active.account.isNotEmpty() && storage.read(activeFile(namespace)) == null) {
                storage.write(activeFile(namespace), KvActive.ADAPTER.encode(active))
            }
            return written
        }

        const val MAX_PENDING = 1_024
        const val MAX_VALUE_BYTES = 32 * 1024
        const val LOCAL_ACCOUNT = "local"

        private val WATCH_RETRY = 2.seconds
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
