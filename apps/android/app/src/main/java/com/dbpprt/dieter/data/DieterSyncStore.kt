package com.dbpprt.dieter.data

import android.content.Context
import android.util.AtomicFile
import android.util.Base64
import com.dbpprt.dieter.v1.GlobalSnapshot
import com.dbpprt.dieter.v1.State
import com.dbpprt.dieter.v1.SyncCursor
import com.dbpprt.dieter.v1.SyncFrame
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

enum class OutboxKind { CREATE_CARD, CREATE_CHAT, SEND_MESSAGE, START_CARD }
enum class OutboxState { QUEUED, RETRYING, FAILED }

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
    val state: OutboxState = OutboxState.QUEUED,
    val nextAttemptAtMillis: Long? = null,
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
class DieterSyncStore(
    context: Context,
    root: File? = null,
) {
    // Construction happens while the application graph is being created on the UI thread.
    // Directory creation and SharedPreferences reads are intentionally deferred until the
    // connection manager's IO dispatcher first needs them.
    private val appContext = context.applicationContext
    private val root by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        root ?: File(appContext.filesDir, "global-sync")
    }
    private val outboxFile by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AtomicFile(File(this.root, "outbox.json"))
    }
    private val preferences by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        appContext.getSharedPreferences("dieter_sync", Context.MODE_PRIVATE)
    }

    val clientId: String by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        preferences.getString("client_id", null)?.takeIf(String::isNotBlank)
            ?: "android_${UUID.randomUUID().toString().lowercase()}".also {
                check(preferences.edit().putString("client_id", it).commit()) {
                    "Unable to persist the Android sync client ID"
                }
            }
    }

    // Snapshot and cursor are one AtomicFile transaction. Legacy split files
    // are only used as an unverified snapshot: force a reset before resuming.
    @Synchronized
    fun loadSnapshot(scope: String): GlobalSnapshot? = loadProjection(scope)?.takeIf { it.hasSnapshot() }?.snapshot
        ?: read(projectionFile(scope, "snapshot.pb"))?.let { runCatching { GlobalSnapshot.parseFrom(it) }.getOrNull() }

    @Synchronized
    fun loadCursor(scope: String): SyncCursor? = loadProjection(scope)?.takeIf { it.hasSnapshot() && it.hasCursor() }?.cursor

    @Synchronized
    fun loadProjection(scope: String): SyncFrame? = read(projectionFile(scope, "projection.pb"))
        ?.let { runCatching { SyncFrame.parseFrom(it) }.getOrNull() }
        ?: read(projectionFile(scope, "snapshot.pb"))?.let { bytes ->
            runCatching { SyncFrame.newBuilder().setSnapshot(GlobalSnapshot.parseFrom(bytes)).build() }.getOrNull()
        }

    @Synchronized
    fun projectionRefreshedAtMillis(scope: String): Long? =
        maxOf(projectionFile(scope, "projection.pb").baseFile.lastModified(),
            projectionFile(scope, "snapshot.pb").baseFile.lastModified()).takeIf { it > 0L }

    @Synchronized
    fun projectionPersistedAtMillis(scope: String): Long? = projectionRefreshedAtMillis(scope)

    @Synchronized
    fun saveProjection(scope: String, snapshot: GlobalSnapshot?, cursor: SyncCursor?) {
        val previous = loadProjection(scope)
        val nextSnapshot = snapshot ?: previous?.takeIf { it.hasSnapshot() }?.snapshot ?: return
        val nextCursor = cursor ?: previous?.takeIf { snapshot == null && it.hasCursor() }?.cursor
        val projection = SyncFrame.newBuilder().setSnapshot(nextSnapshot)
            .also { if (nextCursor != null) it.cursor = nextCursor }.build()
        write(projectionFile(scope, "projection.pb"), projection.toByteArray())
    }

    /** Clears disposable server projections while leaving the durable outbox and client identity intact. */
    @Synchronized
    fun clearProjections() {
        root.listFiles()
            ?.filter { it.isDirectory && it.name.startsWith("projection-") }
            ?.forEach(File::deleteRecursively)
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
                    state = item.optString("state").takeIf(String::isNotBlank)
                        ?.let(OutboxState::valueOf) ?: OutboxState.QUEUED,
                    nextAttemptAtMillis = item.optLong("nextAttemptAtMillis").takeIf { it > 0 },
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
                    .put("state", entry.state.name)
                    .put("nextAttemptAtMillis", entry.nextAttemptAtMillis ?: 0)
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
        check(file.baseFile.parentFile?.let { it.isDirectory || it.mkdirs() } != false) {
            "Unable to create sync storage directory"
        }
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
