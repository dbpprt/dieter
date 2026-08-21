package com.dbpprt.nauclio.data

import android.content.Context
import android.util.AtomicFile
import android.util.Base64
import com.dbpprt.nauclio.v1.GlobalSnapshot
import com.dbpprt.nauclio.v1.SyncCursor
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

enum class OutboxKind { CREATE_CARD, CREATE_CHAT, SEND_MESSAGE }

data class AndroidOutboxEntry(
    val commandId: String,
    val clientId: String,
    val daemonId: String,
    val kind: OutboxKind,
    val request: ByteArray,
    val optimisticId: String,
    val serverId: String? = null,
    val attempts: Int = 0,
    val lastError: String? = null,
    val createdAtMillis: Long = System.currentTimeMillis(),
)

/** Atomic, disposable native projection plus the durable client outbox. */
class NauclioSyncStore(context: Context) {
    private val root = File(context.filesDir, "global-sync").apply { mkdirs() }
    private val outboxFile = AtomicFile(File(root, "outbox.json"))
    private val preferences = context.getSharedPreferences("nauclio_sync", Context.MODE_PRIVATE)

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
    fun loadOutbox(): MutableList<AndroidOutboxEntry> {
        val raw = read(outboxFile) ?: return mutableListOf()
        return runCatching {
            val array = JSONArray(raw.toString(Charsets.UTF_8))
            MutableList(array.length()) { index ->
                val item = array.getJSONObject(index)
                AndroidOutboxEntry(
                    commandId = item.getString("commandId"),
                    clientId = item.getString("clientId"),
                    daemonId = item.getString("daemonId"),
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
                    .put("daemonId", entry.daemonId)
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
