package com.dbpprt.dieter.connection

import com.dbpprt.dieter.settings.DieterNotificationSettings
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot

/**
 * Small semantic fingerprints keep high-frequency transcript/state frames from rebuilding and
 * reposting identical notifications. Message text and heartbeat timestamps are intentionally not
 * inputs: only values that can change what the notification displays belong here.
 */
internal fun connectionNotificationFingerprint(
    state: DieterConnectionState,
    settings: DieterNotificationSettings,
    paletteSlug: String,
): Int {
    val activeCards = (state.cards + state.chats)
        .filter { isActiveRuntime(it.runtime) }
        .associateBy(Card::getId)
    val preview = modelActivityPreview(activeCards, state.activeConversations)
    val activeSubagents = state.activeConversations.values.sumOf { snapshot ->
        snapshot.conversation.subagentsList.count {
            it.status.equals("running", true) || it.status.equals("pending", true)
        }
    }
    val hostname = state.projectHosts.values.firstOrNull { host ->
        host.online && (state.endpoint == null || host.endpointId == state.endpoint.id)
    }?.hostname ?: state.projectHosts.values.firstOrNull { it.online }?.hostname
    return listOf(
        state.phase,
        state.endpoint?.id,
        state.endpoint?.label,
        state.endpoint?.address,
        state.error,
        state.boards.size,
        state.cards.count { it.lane.equals("review", true) },
        hostname,
        preview,
        activeSubagents,
        settings.displayStyle,
        settings.liveStatusActivityEnabled,
        paletteSlug,
    ).hashCode()
}

internal fun runningChatNotificationFingerprint(
    chat: Card,
    snapshot: ConversationSnapshot?,
    session: String,
    settings: DieterNotificationSettings,
    paletteSlug: String,
): Int = listOf(
    chat.id,
    chat.title,
    session,
    currentModelActivities(chat, snapshot),
    settings.displayStyle,
    paletteSlug,
).hashCode()
