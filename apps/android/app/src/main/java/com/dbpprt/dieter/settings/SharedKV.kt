package com.dbpprt.dieter.settings

import android.content.SharedPreferences
import android.util.Base64
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.v1.*
import com.google.protobuf.ByteString
import io.grpc.Status
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Account cache and durable, daemon-bound outbox for portable navigation. */
class SharedKV(private val preferences: SharedPreferences, private val namespace: String = "navigation") {
    // State, protobuf/JSON projection and durable commits share one IO lane.
    // Network suspensions may interleave; each non-suspending mutation stays
    // atomic, as it did on Main, without blocking UI input or rendering.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))
    private val commands = Channel<() -> Unit>(1024)
    private var repository: DieterRepository? = null
    private var watch: Job? = null
    private var delivery: Job? = null
    private var generation = 0
    private var account = ""
    private var daemon = ""
    private var entries = mutableMapOf<String, KVEntry>()
    private var pending = mutableListOf<JSONObject>()
    private val _values = MutableStateFlow<Map<String, String>>(emptyMap())
    val values = _values.asStateFlow()
    private val _status = MutableStateFlow(SharedKVStatus())
    val status = _status.asStateFlow()
    private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)
    private val cacheKey get() = "account.$account.$namespace" + if (account == "local") ".$daemon" else ""
    private fun restore() {
        val saved = runCatching { JSONObject(preferences.getString(cacheKey, "{}")!!) }.getOrDefault(JSONObject())
        val records = saved.optJSONObject("entries") ?: JSONObject()
        entries = records.keys().asSequence().mapNotNull { key ->
            runCatching { key to KVEntry.parseFrom(decode(records.getString(key))) }.getOrNull()
        }.toMap().toMutableMap()
        val queue = saved.optJSONArray("pending") ?: JSONArray()
        pending = (0 until queue.length()).map { queue.getJSONObject(it) }.toMutableList()
        publish()
    }
    init {
        scope.launch {
            account = preferences.getString("activeAccount", "").orEmpty()
            daemon = preferences.getString("activeDaemon", "").orEmpty()
            if (account.isNotEmpty()) restore()
            for (command in commands) {
                try { command() }
                catch (error: Exception) { _status.value = _status.value.copy(error = error.message) }
            }
        }
    }

    private fun submit(command: () -> Unit) {
        if (commands.trySend(command).isFailure) {
            _status.value = _status.value.copy(error = "Navigation is busy. Try again after pending edits finish.")
        }
    }

    /** Completes after earlier commands and their durable writes, without waiting for network delivery. */
    internal suspend fun awaitPendingWrites() {
        val completed = CompletableDeferred<Unit>()
        commands.send { completed.complete(Unit) }
        completed.await()
    }

    suspend fun close() { commands.cancel(); scope.coroutineContext.job.cancelAndJoin() }

    // Read-modify-write projections must read after earlier queued edits.
    // Calculating their diff on Main would lose rapid successive reorderings.
    fun edit(transform: Editor.(Map<String, String>) -> Unit) = submit { Editor().transform(_values.value) }
    inner class Editor internal constructor() {
        fun put(key: String, value: Any, requiresExisting: Boolean = false) = putNow(key, value, requiresExisting)
        fun delete(key: String) = enqueue(JSONObject().put("key", key).put("deleted", true))
        fun move(key: String, parent: String = "", after: String = "", before: String = "") = enqueue(JSONObject()
            .put("key", key).put("parent", parent).put("after", after).put("before", before))
    }
    fun bind(connection: DieterRepository?) = submit { bindNow(connection) }
    private fun bindNow(connection: DieterRepository?) {
        generation++; val token = generation
        watch?.cancel(); delivery?.cancel(); delivery = null; repository = connection
        if (connection == null) return
        watch = scope.launch(start = CoroutineStart.LAZY) {
            while (isActive && token == generation) {
                try {
                    val info = connection.listKV(KVListRequest.newBuilder().setNamespace(namespace).build())
                    if (token != generation) return@launch
                    if (account != info.account || (account == "local" && daemon != info.daemonId)) {
                        account = info.account; daemon = info.daemonId; restore()
                        // A transport can survive an enrollment/account change.
                        // Invalidate old admissions before consuming another cache.
                        bindNow(connection); return@launch
                    }
                    daemon = info.daemonId
                    val replacement = mutableMapOf<String, KVEntry>()
                    connection.watchKV(KVWatchRequest.newBuilder().setNamespace(namespace).setAccount(account).build()).collect { frame ->
                        if (token != generation || frame.account != account) return@collect
                        if (frame.reset) replacement.clear()
                        frame.entriesList.forEach { replacement[it.key] = it }
                        if (frame.caughtUp) {
                            replacement.forEach { (key, incoming) ->
                                val covers = entries[key]?.versionsList?.all { prior ->
                                    incoming.versionsList.any { next -> prior.clockMap.all { (actor, count) -> (next.clockMap[actor] ?: 0) >= count } }
                                } ?: true
                                if (covers) entries[key] = incoming
                            }
                            if (save()) { publish(); flush() }
                        }
                    }
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { if (token == generation) _status.value = SharedKVStatus(pending.size, e.message) }
                delay(2_000)
            }
        }
        watch?.start()
    }
    fun clearAccount() = submit {
        bindNow(null)
        if (account.isNotEmpty()) {
            account = ""; daemon = ""; entries.clear(); pending.clear()
            preferences.edit().remove("activeAccount").remove("activeDaemon").commit()
        }
        publish()
    }
    fun put(key: String, value: Any, requiresExisting: Boolean = false) = submit { putNow(key, value, requiresExisting) }
    private fun putNow(key: String, value: Any, requiresExisting: Boolean) {
        val encoded = JSONArray().put(value).toString().let { it.substring(1, it.length - 1) }
        if (encoded.toByteArray(Charsets.UTF_8).size > 32 * 1024) {
            _status.value = SharedKVStatus(pending.size, "Shared values must be at most 32 KiB."); return
        }
        enqueue(JSONObject().put("key", key).put("value", encoded).put("requiresExisting", requiresExisting))
    }
    fun delete(key: String) = submit { enqueue(JSONObject().put("key", key).put("deleted", true)) }
    fun move(key: String, parent: String = "", after: String = "", before: String = "") = submit { enqueue(JSONObject()
        .put("key", key).put("parent", parent).put("after", after).put("before", before)) }
    private fun enqueue(intent: JSONObject) {
        if (account.isEmpty()) { _status.value = SharedKVStatus(pending.size, "Connect to an account before organizing navigation."); return }
        if (pending.size >= 1024) { _status.value = SharedKVStatus(pending.size, "Reconnect to deliver pending navigation edits."); return }
        intent.put("id", UUID.randomUUID().toString()); pending.add(intent)
        if (!save()) { pending.removeAt(pending.lastIndex); return }
        publish(); flush()
    }
    private fun save(): Boolean {
        if (account.isEmpty()) return true
        return try {
            val records = JSONObject(); entries.forEach { (key, entry) -> records.put(key, encode(entry.toByteArray())) }
            check(preferences.edit().putString("activeAccount", account).putString("activeDaemon", daemon).putString(cacheKey,
                JSONObject().put("entries", records).put("pending", JSONArray(pending)).toString()).commit()) { "Could not persist shared navigation" }
            true
        } catch (e: Exception) {
            _status.value = SharedKVStatus(pending.size, e.message); delivery?.cancel(); repository = null; false
        }
    }
    private fun publish() {
        val values = entries.filterValues { !it.deleted }.mapValues { it.value.valueJson.toStringUtf8() }.toMutableMap()
        pending.forEach { intent ->
            val key = intent.getString("key")
            when {
                intent.optBoolean("deleted") -> values.remove(key)
                intent.has("parent") -> {
                    val parent = intent.getString("parent")
                    val positions = values.mapNotNull { (k,v) -> runCatching { k to JSONObject(v) }.getOrNull() }.toMap()
                    val after = intent.optString("after"); val before = intent.optString("before")
                    val left = positions[after]?.optString("rank") ?: if (before.isEmpty()) positions.filter {
                        it.key != key && it.key.substringBefore('.') == key.substringBefore('.') && it.value.optString("parent") == parent
                    }.values.map { it.optString("rank") }.maxOrNull().orEmpty() else ""
                    val right = positions[before]?.optString("rank").orEmpty()
                    values[key] = JSONObject().put("parent", parent).put("rank", between(left,right) + intent.getString("id").replace("-", "") + "h").toString()
                }
                !intent.optBoolean("requiresExisting") || entries[key]?.deleted != true -> values[key] = intent.getString("value")
            }
        }
        _values.value = values; _status.value = SharedKVStatus(pending.size)
    }
    private fun flush() {
        val connection = repository ?: return
        if (delivery?.isActive == true || pending.isEmpty()) return
        val token = generation
        delivery = scope.launch {
            while (isActive && token == generation && pending.isNotEmpty()) {
                try {
                    val intent = pending.first()
                    if (intent.has("daemon") && intent.getString("daemon") != daemon) {
                        _status.value = SharedKVStatus(pending.size, "A pending navigation edit awaits its accepting machine."); return@launch
                    }
                    if (!intent.has("prepared")) {
                        val ref = KVRef.newBuilder().setNamespace(namespace).setKey(intent.getString("key")).setAccount(account).build()
                        val current = try { connection.getKV(ref) } catch(e: Exception) {
                            if (Status.fromThrowable(e).code == Status.Code.NOT_FOUND) null else throw e
                        }
                        if (token != generation) return@launch
                        if (entries[ref.key]?.let { !covers(current, it) } == true) {
                            _status.value = SharedKVStatus(pending.size, "Waiting for this machine to receive earlier navigation edits.")
                            delay(1_000); continue
                        }
                        if (intent.optBoolean("requiresExisting") && (current == null || current.deleted)) {
                            pending.removeAt(0); if (!save()) return@launch; publish(); continue
                        }
                        val revision = current?.revision.orEmpty(); val id = intent.getString("id")
                        var after = intent.optString("after"); var before = intent.optString("before")
                        if (intent.has("parent")) {
                            suspend fun rank(key: String): String? {
                                if (key.isEmpty()) return null
                                val entry = try { connection.getKV(ref.toBuilder().setKey(key).build()) }
                                    catch (e: Exception) { if (Status.fromThrowable(e).code == Status.Code.NOT_FOUND) return null else throw e }
                                val position = runCatching { JSONObject(entry.valueJson.toStringUtf8()) }.getOrNull()
                                return position?.takeIf { !entry.deleted && it.optString("parent") == intent.getString("parent") }?.optString("rank")
                            }
                            val left = rank(after); val right = rank(before)
                            if (left == null || (right != null && left >= right)) after = ""
                            if (right == null) before = ""
                        }
                        if (token != generation) return@launch
                        val bytes = when {
                            intent.has("parent") -> KVMoveRequest.newBuilder().setRef(ref).setParent(intent.getString("parent"))
                                .setAfterKey(after).setBeforeKey(before)
                                .setExpectedRevision(revision).setOperationId(id).setDaemonId(daemon).build().toByteArray()
                            intent.optBoolean("deleted") -> KVDeleteRequest.newBuilder().setRef(ref).setExpectedRevision(revision)
                                .setOperationId(id).setDaemonId(daemon).build().toByteArray()
                            else -> KVPutRequest.newBuilder().setRef(ref).setValueJson(ByteString.copyFromUtf8(intent.getString("value")))
                                .setExpectedRevision(revision).setOperationId(id).setDaemonId(daemon).build().toByteArray()
                        }
                        intent.put("prepared", encode(bytes)).put("daemon", daemon); if (!save()) return@launch
                    }
                    val bytes = decode(intent.getString("prepared"))
                    val result = when {
                        intent.has("parent") -> connection.moveKV(KVMoveRequest.parseFrom(bytes))
                        intent.optBoolean("deleted") -> connection.deleteKV(KVDeleteRequest.parseFrom(bytes))
                        else -> connection.putKV(KVPutRequest.parseFrom(bytes))
                    }
                    if (token != generation) return@launch
                    if (entries[result.key]?.let { covers(result,it) } != false) entries[result.key] = result
                    pending.removeAt(0); if (!save()) return@launch; publish()
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    if (token != generation) return@launch
                    if (Status.fromThrowable(e).code == Status.Code.ABORTED) {
                        pending.first().apply { remove("prepared"); remove("daemon"); put("id", UUID.randomUUID().toString()) }; if (!save()) return@launch
                    } else _status.value = SharedKVStatus(pending.size, e.message)
                    delay(2_000)
                }
            }
        }
    }
    private fun covers(incoming: KVEntry?, prior: KVEntry): Boolean = prior.versionsList.all { old ->
        incoming?.versionsList?.any { next -> old.clockMap.all { (actor,count) -> (next.clockMap[actor] ?: 0) >= count } } == true
    }
    companion object {
        private fun between(left: String, right: String): String {
            val alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"; val prefix = StringBuilder(); var upper = right
            repeat(512) { index ->
                val lo = left.getOrNull(index)?.let { alphabet.indexOf(it).coerceAtLeast(0) } ?: 0
                val hi = upper.getOrNull(index)?.let { alphabet.indexOf(it).coerceAtLeast(0) } ?: 35
                if (hi-lo > 1) return prefix.append(alphabet[(lo+hi)/2]).toString()
                prefix.append(alphabet[lo]); if (hi > lo) upper = ""
            }
            return left + "h"
        }
    }
}
data class SharedKVStatus(val pending: Int = 0, val error: String? = null)
