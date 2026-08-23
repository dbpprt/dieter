package com.dbpprt.dieter.data

import android.content.Context
import android.util.AtomicFile
import android.util.Base64
import com.dbpprt.dieter.v1.GlobalSnapshot
import com.dbpprt.dieter.v1.State
import com.dbpprt.dieter.v1.SyncCursor
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

enum class OutboxKind { CREATE_CARD, CREATE_CHAT, SEND_MESSAGE }

data class AndroidOutboxEntry(
    val commandId: String,
    val clientId: String,
    /** Gateway-scoped daemon endpoint ID (`<gateway credential ID>#<daemon ID>`). */
    val endpointId: String,
    val kind: OutboxKind,
    val request: ByteArray,
    val optimisticId: String,
    val serverId: String? = null,
    val attempts: Int = 0,
    val lastError: String? = null,
    val createdAtMillis: Long = System.currentTimeMillis(),
)

data class CachedProjectHost(
    val endpointId: String,
    val daemonId: String,
    val hostname: String,
)

data class CachedMachineDirectory(
    val state: State,
    val hosts: Map<String, CachedProjectHost>,
)

/** Atomic, disposable native projection plus the durable client outbox. */
class DieterSyncStore(context: Context) {
    private val root = File(context.filesDir, "global-sync").apply { mkdirs() }
    private val outboxFile = AtomicFile(File(root, "outbox.json"))
    private val preferences = context.getSharedPreferences("dieter_sync", Context.MODE_PRIVATE)

    val clientId: String = preferences.getString("client_id", null)?.takeIf(String::isNotBlank)
        ?: "android_${UUID.randomUUID().toString().lowercase()}".also {
            preferences.edit().putString("client_id", it).commit()
        }

    @Synchronized
    fun loadSnapshot(scope: String): GlobalSnapshot? = read(projectionFile(scope, "snapshot.pb"))
        ?.let { runCatching { GlobalSnapshot.parseFrom(it) }.getOrNull() }

    @Synchronized
    fun loadCursor(scope: String): SyncCursor? = read(projectionFile(scope, "cursor.pb"))
        ?.let { runCatching { SyncCursor.parseFrom(it) }.getOrNull() }

    @Synchronized
    fun saveProjection(scope: String, snapshot: GlobalSnapshot?, cursor: SyncCursor?) {
        if (snapshot != null) write(projectionFile(scope, "snapshot.pb"), snapshot.toByteArray())
        if (cursor != null) write(projectionFile(scope, "cursor.pb"), cursor.toByteArray())
    }

    @Synchronized
    fun loadMachineDirectory(scope: String): CachedMachineDirectory? {
        val raw = read(projectionFile(scope, "machine-directory.json")) ?: return null
        return runCatching {
            val root = JSONObject(raw.toString(Charsets.UTF_8))
            val state = State.parseFrom(Base64.decode(root.getString("state"), Base64.NO_WRAP))
            val hosts = root.getJSONArray("hosts")
            val byProject = buildMap {
                for (index in 0 until hosts.length()) {
                    val item = hosts.getJSONObject(index)
                    put(
                        item.getString("projectId"),
                        CachedProjectHost(
                            endpointId = item.getString("endpointId"),
                            daemonId = item.getString("daemonId"),
                            hostname = item.getString("hostname"),
                        ),
                    )
                }
            }
            CachedMachineDirectory(state, byProject)
        }.getOrNull()
    }

    @Synchronized
    fun saveMachineDirectory(scope: String, state: State, hosts: Map<String, CachedProjectHost>) {
        val encodedHosts = JSONArray().apply {
            hosts.toSortedMap().forEach { (projectId, host) ->
                put(
                    JSONObject()
                        .put("projectId", projectId)
                        .put("endpointId", host.endpointId)
                        .put("daemonId", host.daemonId)
                        .put("hostname", host.hostname),
                )
            }
        }
        val root = JSONObject()
            .put("state", Base64.encodeToString(state.toByteArray(), Base64.NO_WRAP))
            .put("hosts", encodedHosts)
        write(projectionFile(scope, "machine-directory.json"), root.toString().toByteArray())
    }

    @Synchronized
    fun loadOutbox(): MutableList<AndroidOutboxEntry> {
        val raw = read(outboxFile) ?: return mutableListOf()
        return runCatching {
            val array = JSONArray(raw.toString(Charsets.UTF_8))
            MutableList(array.length()) { index ->
                val item = array.getJSONObject(index)
                AndroidOutboxEntry(
                    commandId = item.getString("commandId"),
                    clientId = item.getString("clientId"),
                    endpointId = item.optString("endpointId").ifBlank { item.getString("daemonId") },
                    kind = OutboxKind.valueOf(item.getString("kind")),
                    request = Base64.decode(item.getString("request"), Base64.NO_WRAP),
                    optimisticId = item.getString("optimisticId"),
                    serverId = item.optString("serverId").takeIf(String::isNotBlank),
                    attempts = item.optInt("attempts"),
                    lastError = item.optString("lastError").takeIf(String::isNotBlank),
                    createdAtMillis = item.optLong("createdAtMillis"),
                )
            }
        }.getOrElse { mutableListOf() }
    }

    @Synchronized
    fun saveOutbox(entries: List<AndroidOutboxEntry>) {
        val array = JSONArray()
        entries.forEach { entry ->
            array.put(
                JSONObject()
                    .put("commandId", entry.commandId)
                    .put("clientId", entry.clientId)
                    .put("endpointId", entry.endpointId)
                    .put("kind", entry.kind.name)
                    .put("request", Base64.encodeToString(entry.request, Base64.NO_WRAP))
                    .put("optimisticId", entry.optimisticId)
                    .put("serverId", entry.serverId ?: "")
                    .put("attempts", entry.attempts)
                    .put("lastError", entry.lastError ?: "")
                    .put("createdAtMillis", entry.createdAtMillis),
            )
        }
        write(outboxFile, array.toString().toByteArray())
    }

    private fun read(file: AtomicFile): ByteArray? = runCatching { file.openRead().use { it.readBytes() } }.getOrNull()

    private fun projectionFile(scope: String, name: String): AtomicFile {
        val digest = MessageDigest.getInstance("SHA-256").digest(scope.toByteArray())
            .take(12).joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val directory = File(root, "projection-$digest").apply { mkdirs() }
        return AtomicFile(File(directory, name))
    }

    private fun write(file: AtomicFile, data: ByteArray) {
        val output = file.startWrite()
        try {
            output.write(data)
            output.fd.sync()
            file.finishWrite(output)
        } catch (error: Throwable) {
            file.failWrite(output)
            throw error
        }
    }
}
