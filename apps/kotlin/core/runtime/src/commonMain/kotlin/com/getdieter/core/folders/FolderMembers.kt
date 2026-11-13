package com.getdieter.core.folders

import com.getdieter.api.v1.FolderMode
import com.getdieter.api.v1.FolderState
import com.getdieter.api.v1.KVEntry
import com.getdieter.core.runtime.Timestamps
import kotlin.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull

/** A phone homed on a daemon member, as that daemon reports it. */
data class FolderClientRecord(
    val deviceId: String,
    val name: String,
    val mode: FolderMode,
    val lastSeenAt: Instant?,
    val acknowledged: Long,
)

/**
 * A daemon member's membership and coarse state: its `folder-member` KV record (key
 * `<folderId>.<daemonId>`), which only that daemon writes, at most once a minute.
 */
data class FolderMemberRecord(
    val folderId: String,
    val daemonId: String,
    val name: String,
    val mode: FolderMode,
    val paused: Boolean,
    val state: FolderState,
    val stateDetail: String,
    val sequence: Long,
    val indexId: String,
    val lastSyncAt: Instant?,
    val needFiles: Long,
    val needBytes: Long,
    val conflicts: Int,
    val clients: List<FolderClientRecord>,
)

/** Reads daemon members from the account's KV view. */
object FolderMembers {
    const val NAMESPACE = "folder-member"

    /** [folderId]'s daemon members, by name. */
    fun of(kv: Map<String, KVEntry>, folderId: String): List<FolderMemberRecord> =
        kv.values
            .asSequence()
            .filter { !it.deleted && it.key.startsWith("$folderId.") }
            .mapNotNull(::parse)
            .filter { it.folderId == folderId }
            .sortedWith(compareBy({ it.name.lowercase() }, { it.daemonId }))
            .toList()

    /** Every daemon member, by folder ID. */
    fun all(kv: Map<String, KVEntry>): Map<String, List<FolderMemberRecord>> =
        kv.values
            .asSequence()
            .filter { !it.deleted }
            .mapNotNull(::parse)
            .groupBy { it.folderId }
            .mapValues { (_, members) ->
                members.sortedWith(compareBy({ it.name.lowercase() }, { it.daemonId }))
            }

    fun parse(entry: KVEntry): FolderMemberRecord? {
        val value =
            runCatching { Json.parseToJsonElement(entry.value_json.utf8()) }.getOrNull()
                as? JsonObject ?: return null
        val folderId = value.text("folderId").ifEmpty { entry.key.substringBefore('.') }
        val daemonId = value.text("daemonId").ifEmpty { entry.key.substringAfter('.', "") }
        if (folderId.isEmpty() || daemonId.isEmpty()) return null
        return FolderMemberRecord(
            folderId = folderId,
            daemonId = daemonId,
            name = value.text("name").ifEmpty { daemonId },
            mode = mode(value["mode"]),
            paused = value.bool("paused"),
            state = state(value["state"]),
            stateDetail = value.text("stateDetail"),
            sequence = value.long("sequence"),
            indexId = value.text("indexId"),
            lastSyncAt = time(value["lastSyncAt"]),
            needFiles = value.long("needFiles"),
            needBytes = value.long("needBytes"),
            conflicts = value.long("conflicts").toInt(),
            clients =
                (value["clients"] as? JsonArray)
                    ?.mapNotNull { element ->
                        val client = element as? JsonObject ?: return@mapNotNull null
                        val id =
                            client.text("deviceId").ifEmpty {
                                return@mapNotNull null
                            }
                        FolderClientRecord(
                            deviceId = id,
                            name = client.text("name").ifEmpty { id },
                            mode = mode(client["mode"]),
                            lastSeenAt = time(client["lastSeenAt"]),
                            acknowledged = client.long("acknowledged"),
                        )
                    }
                    .orEmpty(),
        )
    }

    /** A mode as Go names it ("two-way", "send-only", "receive-only") or as its enum. */
    fun mode(value: JsonElement?): FolderMode {
        val primitive = value as? JsonPrimitive ?: return FolderMode.FOLDER_MODE_TWO_WAY
        primitive.longOrNull?.let { number ->
            return FolderMode.fromValue(number.toInt()) ?: FolderMode.FOLDER_MODE_TWO_WAY
        }
        return when (primitive.content.lowercase().removePrefix("folder_mode_").replace('_', '-')) {
            "send-only" -> FolderMode.FOLDER_MODE_SEND_ONLY
            "receive-only" -> FolderMode.FOLDER_MODE_RECEIVE_ONLY
            else -> FolderMode.FOLDER_MODE_TWO_WAY
        }
    }

    /** A state as Go names it ("idle", "syncing", …) or as its enum. */
    fun state(value: JsonElement?): FolderState {
        val primitive = value as? JsonPrimitive ?: return FolderState.FOLDER_STATE_UNSPECIFIED
        primitive.longOrNull?.let { number ->
            return FolderState.fromValue(number.toInt()) ?: FolderState.FOLDER_STATE_UNSPECIFIED
        }
        return when (primitive.content.lowercase().removePrefix("folder_state_")) {
            "idle" -> FolderState.FOLDER_STATE_IDLE
            "scanning" -> FolderState.FOLDER_STATE_SCANNING
            "syncing" -> FolderState.FOLDER_STATE_SYNCING
            "paused" -> FolderState.FOLDER_STATE_PAUSED
            "attention" -> FolderState.FOLDER_STATE_ATTENTION
            "error" -> FolderState.FOLDER_STATE_ERROR
            else -> FolderState.FOLDER_STATE_UNSPECIFIED
        }
    }

    private fun time(value: JsonElement?): Instant? {
        val primitive = value as? JsonPrimitive ?: return null
        primitive.longOrNull?.let { millis ->
            return if (millis > 0) Instant.fromEpochMilliseconds(millis) else null
        }
        return Timestamps.parse(primitive.content)
    }

    private fun JsonObject.text(name: String): String =
        (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()

    private fun JsonObject.bool(name: String): Boolean =
        (this[name] as? JsonPrimitive)?.booleanOrNull ?: false

    private fun JsonObject.long(name: String): Long =
        (this[name] as? JsonPrimitive)?.longOrNull ?: 0
}
