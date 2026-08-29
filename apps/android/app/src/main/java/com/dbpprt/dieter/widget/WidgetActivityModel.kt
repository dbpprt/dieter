package com.dbpprt.dieter.widget

import com.dbpprt.dieter.connection.currentModelActivities
import com.dbpprt.dieter.connection.isActiveRuntime
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.Project
import java.time.Duration
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

enum class WidgetStyle { AUTO, ACTIVITY, LAST_FINISHED }

data class WidgetConfig(
    val style: WidgetStyle = WidgetStyle.AUTO,
    val maxItems: Int = DEFAULT_MAX_ITEMS,
    val showSections: Boolean = true,
) {
    companion object {
        const val DEFAULT_MAX_ITEMS = 12
        val MAX_ITEM_CHOICES = listOf(6, 12, 20)
    }
}

enum class WidgetRowKind { WAITING, RUNNING, FAILED, CHAT }

sealed interface WidgetRow {
    data class Section(val title: String) : WidgetRow

    data class Item(
        val cardId: String,
        val kind: WidgetRowKind,
        val title: String,
        val subtitle: String,
        val trailing: String,
        val highlighted: Boolean = false,
    ) : WidgetRow
}

data class WidgetActivityModel(
    val compact: Boolean,
    val headerTitle: String,
    val statusText: String,
    val online: Boolean,
    val rows: List<WidgetRow>,
    val emptyTitle: String,
    val emptyBody: String,
)

/**
 * Projects standalone chats from the cached connection state into home-screen
 * rows: attention first, then live work, then recent replies grouped by day.
 */
fun buildWidgetModel(
    chats: List<Card>,
    conversations: Map<String, ConversationSnapshot>,
    projects: List<Project>,
    hostname: String?,
    lastSyncAtMs: Long,
    config: WidgetConfig,
    compact: Boolean,
    now: Instant = Instant.now(),
    zoneId: ZoneId = ZoneId.systemDefault(),
): WidgetActivityModel {
    val projectNames = projects.associate { it.id to it.name }
    fun projectLabel(card: Card): String = projectNames[card.projectId]?.takeIf(String::isNotBlank)
        ?: "Chat"

    val chatCards = chats.filter { !it.archived }

    val waiting = chatCards.filter { it.runtime.equals("waiting_for_user", ignoreCase = true) }
        .sortedByDescending { parseInstant(waitingSince(it)) ?: Instant.EPOCH }
    val running = chatCards.filter { isActiveRuntime(it.runtime) }
        .sortedByDescending { parseInstant(it.lastActivityAt.ifBlank { it.updatedAt }) ?: Instant.EPOCH }
    val finished = finishedChats(chatCards).sortedByDescending { it.at ?: Instant.EPOCH }

    if (compact) {
        val items = finished.take(config.maxItems).map { entry ->
            WidgetRow.Item(
                cardId = entry.card.id,
                kind = entry.kind,
                title = "${entry.card.title.ifBlank { "Untitled" }} · ${compactPhrase(entry)}",
                subtitle = "",
                trailing = entry.at?.let { shortAge(Duration.between(it, now)) }.orEmpty(),
            )
        }
        return WidgetActivityModel(
            compact = true,
            headerTitle = "Recent replies",
            statusText = statusLine(hostname, lastSyncAtMs, now),
            online = isOnline(lastSyncAtMs, now),
            rows = items,
            emptyTitle = "No replies yet",
            emptyBody = "Recent chat replies show up here",
        )
    }

    val rows = mutableListOf<WidgetRow>()
    var remaining = config.maxItems

    fun addItems(items: List<WidgetRow.Item>) {
        val taken = items.take(remaining)
        rows += taken
        remaining -= taken.size
    }

    addItems(
        waiting.map { card ->
            WidgetRow.Item(
                cardId = card.id,
                kind = WidgetRowKind.WAITING,
                title = card.title.ifBlank { "Untitled" },
                subtitle = "${projectLabel(card)} · waiting on you",
                trailing = sinceLabel(parseInstant(waitingSince(card)), now),
                highlighted = true,
            )
        },
    )
    addItems(
        running.map { card ->
            val detail = currentModelActivities(card, conversations[card.id]).firstOrNull()?.detail
                ?: "Working on your request"
            WidgetRow.Item(
                cardId = card.id,
                kind = WidgetRowKind.RUNNING,
                title = card.title.ifBlank { "Untitled" },
                subtitle = "${projectLabel(card)} · $detail",
                trailing = elapsedLabel(parseInstant(card.runtimeUpdatedAt), now),
            )
        },
    )
    val today = now.atZone(zoneId).toLocalDate()
    val clock = DateTimeFormatter.ofPattern("HH:mm")
    val dayStamp = DateTimeFormatter.ofPattern("MMM d")
    var section: String? = null
    finished.take(remaining.coerceAtLeast(0)).forEach { entry ->
        val date = entry.at?.atZone(zoneId)?.toLocalDate()
        val title = when {
            date == null -> "Earlier"
            date == today -> "Replied today"
            date == today.minusDays(1) -> "Yesterday"
            else -> "Earlier"
        }
        if (config.showSections && title != section) {
            section = title
            rows += WidgetRow.Section(title)
        }
        val trailing = when {
            entry.at == null -> ""
            date == today || date == today.minusDays(1) -> clock.format(entry.at.atZone(zoneId))
            else -> dayStamp.format(entry.at.atZone(zoneId))
        }
        rows += WidgetRow.Item(
            cardId = entry.card.id,
            kind = entry.kind,
            title = entry.card.title.ifBlank { "Untitled" },
            subtitle = finishedSubtitle(entry, projectLabel(entry.card)),
            trailing = trailing,
        )
    }

    return WidgetActivityModel(
        compact = false,
        headerTitle = "Chats",
        statusText = statusLine(hostname, lastSyncAtMs, now),
        online = isOnline(lastSyncAtMs, now),
        rows = rows,
        emptyTitle = "No chats yet",
        emptyBody = "Start a chat in Dieter",
    )
}

internal data class FinishedEntry(val card: Card, val at: Instant?, val kind: WidgetRowKind)

private fun finishedChats(chats: List<Card>): List<FinishedEntry> = chats
    .filter { chat ->
        chat.runtimeUpdatedAt.isNotBlank() &&
            chat.runtime.isNotBlank() &&
            !isActiveRuntime(chat.runtime) &&
            !chat.runtime.equals("waiting_for_user", ignoreCase = true) &&
            !chat.runtime.equals("pending", ignoreCase = true)
    }
    .map { chat ->
        FinishedEntry(
            card = chat,
            at = parseInstant(chat.runtimeUpdatedAt.ifBlank { chat.lastActivityAt }),
            kind = when {
                chat.runtime.equals("failed", ignoreCase = true) -> WidgetRowKind.FAILED
                else -> WidgetRowKind.CHAT
            },
        )
    }

private fun finishedSubtitle(entry: FinishedEntry, project: String): String = when (entry.kind) {
    WidgetRowKind.CHAT -> "$project · replied"
    WidgetRowKind.FAILED -> "$project · failed"
    WidgetRowKind.WAITING, WidgetRowKind.RUNNING -> project
}

private fun compactPhrase(entry: FinishedEntry): String = when (entry.kind) {
    WidgetRowKind.CHAT -> "replied"
    WidgetRowKind.FAILED -> "failed"
    WidgetRowKind.WAITING, WidgetRowKind.RUNNING -> "updated"
}

private fun waitingSince(card: Card): String =
    card.runtimeUpdatedAt.ifBlank { card.phaseChangedAt.ifBlank { card.updatedAt } }

internal fun parseInstant(value: String?): Instant? {
    if (value.isNullOrBlank()) return null
    return runCatching { Instant.parse(value) }.getOrNull()
        ?: runCatching { OffsetDateTime.parse(value).toInstant() }.getOrNull()
}

internal fun statusLine(hostname: String?, lastSyncAtMs: Long, now: Instant): String {
    val polled = when {
        lastSyncAtMs <= 0L -> "not synced yet"
        else -> {
            val age = Duration.between(Instant.ofEpochMilli(lastSyncAtMs), now)
            if (age.toMinutes() < 1) "just polled" else "polled ${shortAge(age)} ago"
        }
    }
    return listOfNotNull(hostname?.takeIf(String::isNotBlank), polled).joinToString(" · ")
}

internal fun isOnline(lastSyncAtMs: Long, now: Instant): Boolean = lastSyncAtMs > 0 &&
    Duration.between(Instant.ofEpochMilli(lastSyncAtMs), now).seconds in 0..ONLINE_WINDOW_SECONDS

internal fun shortAge(age: Duration): String {
    val clamped = if (age.isNegative) Duration.ZERO else age
    return when {
        clamped.toMinutes() < 1 -> "now"
        clamped.toMinutes() < 60 -> "${clamped.toMinutes()}m"
        clamped.toHours() < 24 -> "${clamped.toHours()}h"
        else -> "${clamped.toDays()}d"
    }
}

internal fun sinceLabel(at: Instant?, now: Instant): String {
    at ?: return ""
    val age = Duration.between(at, now)
    return when {
        age.toMinutes() < 1 -> "just now"
        else -> "since ${shortAge(age)}"
    }
}

internal fun elapsedLabel(at: Instant?, now: Instant): String {
    at ?: return ""
    val age = Duration.between(at, now)
    return when {
        age.toMinutes() < 1 -> "just started"
        else -> "${shortAge(age)} elapsed"
    }
}

/** One missed 15 s heartbeat plus generous slack still counts as live. */
private const val ONLINE_WINDOW_SECONDS = 150L
