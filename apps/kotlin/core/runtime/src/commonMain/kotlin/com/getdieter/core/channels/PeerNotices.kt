package com.getdieter.core.channels

import com.getdieter.api.v1.ChannelAuthor
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.UiMessage
import com.getdieter.client.v1.TimelinePeerNotice
import com.getdieter.core.presentation.MessageMetadata
import com.getdieter.core.runtime.Timestamps
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * Agent channel messages inside conversations: a message steered into a running turn is a
 * `data-peer-notice` part of the assistant message, and a turn a channel message woke starts with a
 * user message the daemon wrote (ID prefix `msg_channel_`, metadata origin "channel").
 */
object PeerNotices {
    const val PART_TYPE = "data-peer-notice"
    const val WAKE_PREFIX = "msg_channel_"
    const val WAKE_LABEL = "From agent channels"

    fun isPeerNotice(part: MessagePart): Boolean = part.type == PART_TYPE

    /** A user message that an agent channel wake started, not the user. */
    fun isChannelWake(message: UiMessage): Boolean =
        message.id.startsWith(WAKE_PREFIX) ||
            MessageMetadata.string(MessageMetadata.of(message), "origin") == "channel"

    /**
     * [part]'s notice: its JSON payload (`data_json`) with the part's text as the body. A part
     * without a readable payload still shows its text.
     */
    fun notice(part: MessagePart): TimelinePeerNotice {
        val payload =
            if (part.data_json.size == 0) null
            else
                runCatching { Json.parseToJsonElement(part.data_json.utf8()) as? JsonObject }
                    .getOrNull()
        fun string(obj: JsonObject?, key: String): String =
            (obj?.get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
        val authorJson = payload?.get("author") as? JsonObject
        val author =
            ChannelRules.author(
                ChannelAuthor(
                    kind = string(authorJson, "kind").ifEmpty { "agent" },
                    card_id = string(authorJson, "cardId"),
                    title = string(authorJson, "title"),
                    harness = string(authorJson, "harness"),
                    model = string(authorJson, "model"),
                    device_id = string(authorJson, "deviceId"),
                )
            )
        val channel = string(payload, "channel").ifEmpty { "channel" }
        val kind = ChannelRules.kind(string(payload, "kind"))
        val direct = (payload?.get("direct") as? JsonPrimitive)?.booleanOrNull == true
        val files =
            (payload?.get("files") as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { it.isString }?.content }
                .orEmpty()
        return TimelinePeerNotice(
            message_id = string(payload, "messageId"),
            project_id = string(payload, "projectId"),
            channel = channel,
            author = author,
            kind = kind,
            kind_label = ChannelRules.kindLabel(kind),
            body = part.text,
            files = files,
            direct = direct,
            title =
                if (direct) "${author.name} to this agent in #$channel"
                else "${author.name} in #$channel",
            open_label = "Open in #$channel",
            created_at_millis =
                Timestamps.parse(string(payload, "createdAt"))?.toEpochMilliseconds() ?: 0,
        )
    }
}
