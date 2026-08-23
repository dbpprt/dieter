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
    val includeChats: Boolean = true,
) {
    companion object {
        const val DEFAULT_MAX_ITEMS = 12
        val MAX_ITEM_CHOICES = listOf(6, 12, 20)
    }
}

enum class WidgetRowKind { WAITING, RUNNING, REVIEW, DONE, FAILED, CHAT }

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
 * Projects the cached connection state into widget rows: attention first
 * (waiting on you, ready for review), then live work, then finished cards
 * grouped by day — mirroring the in-app activity ordering.
 */
fun buildWidgetModel(
    cards: List<Card>,
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
        ?: if (card.scope == "chat") "Chat" else "Board"

    val boardCards = cards.filter { !it.archived }
    val chatCards = if (config.includeChats) chats.filter { !it.archived } else emptyList()
    val all = boardCards + chatCards

    val waiting = all.filter { it.runtime.equals("waiting_for_user", ignoreCase = true) }
        .sortedByDescending { parseInstant(waitingSince(it)) ?: Instant.EPOCH }
    val running = all.filter { isActiveRuntime(it.runtime) }
        .sortedByDescending { parseInstant(it.lastActivityAt.ifBlank { it.updatedAt }) ?: Instant.EPOCH }
    val review = boardCards.filter { card ->
        card.lane.equals("review", ignoreCase = true) &&
            !isActiveRuntime(card.runtime) &&
            !card.runtime.equals("waiting_for_user", ignoreCase = true)
    }.sortedByDescending { parseInstant(card = it) ?: Instant.EPOCH }
    val finished = (finishedBoardCards(boardCards) + finishedChats(chatCards))
        .sortedByDescending { it.at ?: Instant.EPOCH }

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
            headerTitle = "Last finished",
            statusText = statusLine(hostname, lastSyncAtMs, now),
            online = isOnline(lastSyncAtMs, now),
            rows = items,
            emptyTitle = "Nothing finished yet",
            emptyBody = "Completed work shows up here",
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
    addItems(
        review.map { card ->
            WidgetRow.Item(
                cardId = card.id,
                kind = WidgetRowKind.REVIEW,
                title = card.title.ifBlank { "Untitled" },
                subtitle = "${projectLabel(card)} · ready for review",
                trailing = sinceLabel(parseInstant(card.phaseChangedAt.ifBlank { card.updatedAt }), now),
                highlighted = true,
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
            date == today -> "Finished today"
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
        headerTitle = "Activity",
        statusText = statusLine(hostname, lastSyncAtMs, now),
        online = isOnline(lastSyncAtMs, now),
        rows = rows,
        emptyTitle = "No activity yet",
        emptyBody = "Open Dieter to connect and start agents",
    )
}

internal data class FinishedEntry(val card: Card, val at: Instant?, val kind: WidgetRowKind)

private fun finishedBoardCards(cards: List<Card>): List<FinishedEntry> = cards
    .filter { it.lane.contains("done", ignoreCase = true) && !isActiveRuntime(it.runtime) }
    .map { card ->
        FinishedEntry(
            card = card,
            at = parseInstant(card.phaseChangedAt.ifBlank { card.lastActivityAt.ifBlank { card.updatedAt } }),
            kind = if (card.runtime.equals("failed", ignoreCase = true)) WidgetRowKind.FAILED else WidgetRowKind.DONE,
        )
    }

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
    WidgetRowKind.CHAT -> "$project · chat replied"
    WidgetRowKind.FAILED -> "$project · failed"
    else -> entry.card.summary.replace(Regex("\\s+"), " ").trim().ifBlank { "$project · marked done" }
}

private fun compactPhrase(entry: FinishedEntry): String = when (entry.kind) {
    WidgetRowKind.CHAT -> "replied"
    WidgetRowKind.FAILED -> "failed"
    else -> "marked done"
}

private fun waitingSince(card: Card): String =
    card.runtimeUpdatedAt.ifBlank { card.phaseChangedAt.ifBlank { card.updatedAt } }

private fun parseInstant(card: Card): Instant? = parseInstant(card.phaseChangedAt.ifBlank { card.updatedAt })

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
