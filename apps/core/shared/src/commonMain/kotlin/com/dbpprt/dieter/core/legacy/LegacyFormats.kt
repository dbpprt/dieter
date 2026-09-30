package com.dbpprt.dieter.core.legacy

import com.dbpprt.dieter.api.v1.KVEntry
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.journal.OutboxEntry
import com.dbpprt.dieter.core.journal.OutboxKind
import com.dbpprt.dieter.core.journal.OutboxPlacement
import com.dbpprt.dieter.core.journal.OutboxState
import com.dbpprt.dieter.core.navigation.KvCache
import com.dbpprt.dieter.core.navigation.KvDelete
import com.dbpprt.dieter.core.navigation.KvIntent
import com.dbpprt.dieter.core.navigation.KvMove
import com.dbpprt.dieter.core.navigation.KvPut
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.state.CreationPreferences
import com.dbpprt.dieter.core.state.DraftText
import kotlin.math.roundToLong
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import okio.ByteString
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.encodeUtf8

/** A legacy record that belongs to one gateway, identified by its origin. */
data class ForGateway<T>(val origin: String, val value: T)

/**
 * Parsers for the macOS and iOS apps' legacy on-device encodings. Each
 * is pure and tolerant: an unreadable record is skipped, never fatal, as the
 * legacy apps themselves treated corrupt state. Platform code reads the raw
 * values (UserDefaults, files, Keychain) and passes them in.
 */
object LegacyFormats {
    /** Swift's `Date` encodes seconds since 2001-01-01. */
    private const val APPLE_EPOCH_SECONDS = 978_307_200L

    private fun parse(text: String?): JsonElement? = text?.takeIf { it.isNotBlank() }?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull && it.isString }?.content
    private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
    private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
    private fun JsonObject.bytes(key: String): ByteString? = string(key)?.decodeBase64()

    private fun appleMillis(seconds: Double): Long = ((seconds + APPLE_EPOCH_SECONDS) * 1000).roundToLong()

    /** `<origin>#<daemonId>`, a bare daemon ID, or empty; legacy entries used all three. */
    fun splitEndpoint(endpointId: String, fallbackOrigin: String?): Pair<String, String>? {
        val hash = endpointId.indexOf('#')
        return when {
            hash > 0 -> Gateway.parse(endpointId.substring(0, hash))?.origin?.let { it to endpointId.substring(hash + 1) }
            fallbackOrigin == null -> null
            endpointId.contains("://") -> Gateway.parse(endpointId)?.origin?.let { it to "" }
            else -> fallbackOrigin to endpointId
        }
    }

    /**
     * Gateways the core accepts, migrated and deduplicated by origin: remote
     * plaintext gateways are dropped, as the core requires TLS off loopback.
     */
    fun gateways(candidates: List<Gateway>): List<Gateway> =
        candidates.map(Gateway::migrated).filter(Gateway::permitted).distinctBy { it.origin.lowercase() }

    private fun state(value: String?): OutboxState = when (value?.lowercase()) {
        "retrying" -> OutboxState.OUTBOX_STATE_RETRYING
        "failed" -> OutboxState.OUTBOX_STATE_FAILED
        else -> OutboxState.OUTBOX_STATE_QUEUED
    }

    private fun kvEntries(element: JsonElement?): List<KVEntry> =
        (element as? JsonObject).orEmpty().mapNotNull { (_, value) ->
            (value as? JsonPrimitive)?.content?.decodeBase64()?.let { runCatching { KVEntry.ADAPTER.decode(it) }.getOrNull() }
        }

    private fun intent(item: JsonObject?): KvIntent? {
        item ?: return null
        val key = item.string("key") ?: return null
        val base = KvIntent(
            id = item.string("id") ?: return null, key = key,
            prepared = item.bytes("prepared") ?: ByteString.EMPTY, daemon_id = item.string("daemonID").orEmpty(),
        )
        val parent = item.string("parent")
        return when {
            item.bool("deleted") == true -> base.copy(delete = KvDelete())
            parent != null -> base.copy(move = KvMove(parent, item.string("after").orEmpty(), item.string("before").orEmpty()))
            else -> {
                val json = item.bytes("value") ?: return null
                base.copy(put = KvPut(json, item.bool("requiresExisting") ?: false))
            }
        }
    }

    /**
     * `DieterEndpoints` (gateways) and `DieterActiveEndpoint` (the attached
     * machine, with its `daemonID`): the gateways, the active origin, and the
     * preferred machine there. Only TLS gateways were ever kept.
     */
    fun appleEndpoints(endpointsJson: String?, activeJson: String?): Triple<List<Gateway>, String?, String?> {
        fun gateway(item: JsonObject): Gateway? {
            val host = item.string("host")?.takeIf { it.isNotBlank() } ?: return null
            return Gateway(item.string("name")?.ifBlank { null } ?: host, host, item.int("port") ?: 443, item.bool("secure") ?: false)
        }
        val gateways = gateways(
            (parse(endpointsJson) as? JsonArray).orEmpty().mapNotNull { element ->
                (element as? JsonObject)?.takeIf { it.string("daemonID") == null && it.bool("secure") == true }?.let(::gateway)
            },
        )
        val active = (parse(activeJson) as? JsonObject)?.takeIf { it.bool("secure") == true }
        val activeGateway = active?.let(::gateway)?.migrated()
        val origin = activeGateway?.origin?.takeIf { candidate -> gateways.any { it.origin == candidate } } ?: gateways.firstOrNull()?.origin
        val all = if (activeGateway != null && gateways.none { it.origin == activeGateway.origin }) gateways + activeGateway else gateways
        return Triple(all, activeGateway?.origin ?: origin, active?.string("daemonID")?.takeIf { it.isNotBlank() })
    }

    /** macOS `gateway-sessions.json`: origin → token. */
    fun macTokens(json: String?): Map<String, String> = (parse(json) as? JsonObject).orEmpty().mapNotNull { (origin, token) ->
        val value = (token as? JsonPrimitive)?.content?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
        (Gateway.parse(origin)?.origin ?: return@mapNotNull null) to value
    }.toMap()

    /** `Application Support/Dieter/pending-commands.json` (version 1). */
    fun macOutbox(json: String?, activeOrigin: String?): List<ForGateway<OutboxEntry>> {
        val journal = parse(json) as? JsonObject ?: return emptyList()
        if ((journal.int("version") ?: 1) != 1) return emptyList()
        return (journal["entries"] as? JsonArray).orEmpty().mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val kind = when (item.string("kind")) {
                "createCard" -> OutboxKind.OUTBOX_KIND_CREATE_CARD
                "createChat" -> OutboxKind.OUTBOX_KIND_CREATE_CHAT
                "sendMessage" -> OutboxKind.OUTBOX_KIND_SEND_MESSAGE
                else -> return@mapNotNull null
            }
            val (origin, daemon) = splitEndpoint(item.string("endpointID").orEmpty(), activeOrigin) ?: return@mapNotNull null
            ForGateway(
                origin,
                OutboxEntry(
                    command_id = item.string("commandID") ?: return@mapNotNull null,
                    client_id = item.string("clientID").orEmpty(),
                    daemon_id = daemon,
                    kind = kind,
                    request = item.bytes("request") ?: return@mapNotNull null,
                    optimistic_id = item.string("optimisticID") ?: return@mapNotNull null,
                    server_id = item.string("serverID").orEmpty(),
                    attempts = item.int("attempts") ?: 0,
                    last_error = item.string("lastError").orEmpty(),
                    state = state(item.string("state")),
                    next_attempt_at_millis = (item["nextAttemptAt"] as? JsonPrimitive)?.doubleOrNull?.let(::appleMillis) ?: 0,
                    placement = if (item.string("optimisticPlacement") == "queue") OutboxPlacement.OUTBOX_PLACEMENT_QUEUE else OutboxPlacement.OUTBOX_PLACEMENT_TRANSCRIPT,
                    created_at_millis = (item["createdAt"] as? JsonPrimitive)?.doubleOrNull?.let(::appleMillis) ?: 0,
                ),
            )
        }
    }

    /** The file name of a macOS shared-KV cache: `sha256("DieterSharedKV.<account>.navigation[.<daemon>]").json`. */
    fun macSharedKvFile(account: String, daemonId: String): String =
        ("DieterSharedKV.$account.navigation" + if (account == "local") ".$daemonId" else "").encodeUtf8().sha256().hex() + ".json"

    /** One `shared-kv/<hash>.json` cache; values are base64 JSON. */
    fun macSharedKv(json: String?, account: String, daemonId: String): KvCache? {
        val cache = parse(json) as? JsonObject ?: return null
        return KvCache(
            account = account, daemon_id = if (account == "local") daemonId else "",
            entries = kvEntries(cache["entries"]),
            pending = (cache["pending"] as? JsonArray).orEmpty().mapNotNull { intent(it as? JsonObject) },
        )
    }

    /** `DieterConversationDraftTexts` (version 1), newest first. */
    fun macDrafts(json: String?): List<ForGateway<DraftText>> {
        val store = parse(json) as? JsonObject ?: return emptyList()
        return (store["drafts"] as? JsonArray).orEmpty().mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val target = item["target"] as? JsonObject ?: return@mapNotNull null
            val (origin, daemon) = splitEndpoint(target.string("endpointID").orEmpty(), null) ?: return@mapNotNull null
            val conversation = target.string("conversationID")?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val text = item.string("text")?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            ForGateway(origin, DraftText(daemon, conversation, text, (item["updatedAt"] as? JsonPrimitive)?.doubleOrNull?.let(::appleMillis) ?: 0))
        }
    }

    /** `DieterSelectedTerminalsByTarget`: `<origin>#<daemon>|<project>|<card>` → terminal ID. */
    fun macTerminalSelections(selections: Map<String, String>): List<ForGateway<Pair<String, String>>> = selections.mapNotNull { (key, terminal) ->
        val parts = key.split('|')
        if (parts.size != 3 || terminal.isBlank()) return@mapNotNull null
        val (origin, daemon) = splitEndpoint(parts[0], null) ?: return@mapNotNull null
        if (daemon.isEmpty()) return@mapNotNull null
        ForGateway(origin, "$daemon|${parts[1]}|${parts[2]}" to terminal)
    }

    /** `quickTask.lastChoices` plus the conversation-creation defaults. */
    fun macCreation(choicesJson: String?, workspaceMode: String?): CreationPreferences {
        val choices = parse(choicesJson) as? JsonObject
        fun map(key: String) = (choices?.get(key) as? JsonObject).orEmpty().mapNotNull { (k, v) -> (v as? JsonPrimitive)?.content?.let { k to it } }.toMap()
        return CreationPreferences(
            provider = choices?.string("provider").orEmpty(), model = choices?.string("model").orEmpty(), effort = choices?.string("effort").orEmpty(),
            workspace_mode = workspaceMode?.takeIf { it.isNotBlank() } ?: "worktree",
            provider_options = map("options"), boards = map("boards"), project_id = choices?.string("project").orEmpty(),
        )
    }

    /** macOS `DieterNotifications`: absent meant off there, unlike the core's default. */
    fun macNotifications(enabled: Boolean?): NotificationSettings = NotificationSettings(enabled = enabled ?: false)

    private fun JsonArray?.orEmpty(): List<JsonElement> = this ?: emptyList()
    private fun JsonObject?.orEmpty(): Map<String, JsonElement> = this ?: emptyMap()
}
