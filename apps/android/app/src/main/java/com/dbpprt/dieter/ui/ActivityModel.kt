package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.currentModelActivities
import com.dbpprt.dieter.connection.isActiveRuntime
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import java.time.Duration
import java.time.Instant

internal enum class ActivityKind(val label: String) {
    UNREAD("Unread reply"), ANSWER("Answer"), REVIEW("Review"), RUNNING("Running"), FAILED("Failed"), RECENT("Recent"),
}

/** Small projection of already synchronized snapshots; Activity never loads every transcript. */
data class ActivityDetail(val runtimeUpdatedAt: String, val start: Instant?, val label: String)

internal fun activityDetails(snapshots: Map<String, ConversationSnapshot>): Map<String, ActivityDetail> =
    snapshots.mapValues { (_, snapshot) ->
        val card = snapshot.detail.card
        ActivityDetail(
            card.runtimeUpdatedAt,
            ConversationActivityPresentation.turnStartMillis(snapshot.conversation.messagesList, "")
                ?.let(Instant::ofEpochMilli),
            currentModelActivities(card, snapshot).firstOrNull()?.detail.orEmpty(),
        )
    }

/** Retain unchanged projections across connection heartbeats and token updates
 * in other conversations. Entries follow the bounded upstream cache exactly. */
internal class ActivityDetailsProjection {
    private var snapshots: Map<String, ConversationSnapshot> = emptyMap()
    private var details: Map<String, ActivityDetail> = emptyMap()

    fun apply(next: Map<String, ConversationSnapshot>): Map<String, ActivityDetail> {
        if (next === snapshots) return details
        val projected = next.mapValues { (id, snapshot) ->
            details[id]?.takeIf { snapshots[id] === snapshot }
                ?: requireNotNull(activityDetails(mapOf(id to snapshot))[id])
        }
        snapshots = next
        if (projected != details) details = projected
        return details
    }
}

internal data class ActivityEntry(
    val card: Card,
    val kind: ActivityKind,
    val at: Instant?,
    val start: Instant?,
    val detail: String,
) {
    val running: Boolean get() = kind == ActivityKind.RUNNING
    val needsYou: Boolean get() = kind == ActivityKind.ANSWER || kind == ActivityKind.UNREAD
}

internal fun activityInstant(value: String): Instant? = runCatching { Instant.parse(value) }.getOrNull()

/** Cards and standalone chats share one identity, even when present in multiple projections. */
internal fun buildActivityEntries(
    cards: List<Card>,
    details: Map<String, ActivityDetail> = emptyMap(),
): List<ActivityEntry> = cards.filter { it.id.isNotBlank() }
    .groupBy { it.id }
    .values.map { copies -> copies.maxBy { card ->
        listOf(card.updatedAt, card.runtimeUpdatedAt, card.lastActivityAt).mapNotNull(::activityInstant).maxOrNull() ?: Instant.MIN
    } }
    .filterNot { it.archived }
    .mapNotNull { card ->
        val runtime = card.runtime.lowercase()
        val active = isActiveRuntime(runtime) || runtime == "cancelling"
        val kind = when {
            runtime == "waiting_for_user" -> ActivityKind.ANSWER
            active -> ActivityKind.RUNNING
            card.responseSeq > card.seenResponseSeq -> ActivityKind.UNREAD
            card.scope != "chat" && card.lane == "review" -> ActivityKind.REVIEW
            runtime == "failed" -> ActivityKind.FAILED
            runtime.isNotBlank() && runtime != "pending" && card.initialPromptSentAt.isNotBlank() && card.runtimeUpdatedAt.isNotBlank() -> ActivityKind.RECENT
            else -> return@mapNotNull null
        }
        val at = activityInstant(card.runtimeUpdatedAt)
            ?: activityInstant(card.lastActivityAt)
            ?: activityInstant(card.phaseChangedAt)
        // A cached snapshot from a previous turn must not supply this turn's start/activity.
        val detail = details[card.id]?.takeIf { it.runtimeUpdatedAt == card.runtimeUpdatedAt }
        val start = detail?.start?.takeIf { at != null && it <= at }
            ?: if (active) activityInstant(card.runtimeUpdatedAt) else null
        ActivityEntry(card, kind, at, start, when {
            runtime == "cancelling" -> "Stopping…"
            active -> detail?.label?.takeIf(String::isNotBlank) ?: card.summary.ifBlank { "Working on your request" }
            kind == ActivityKind.UNREAD -> "New reply"
            kind == ActivityKind.ANSWER -> "Waiting for your answer"
            kind == ActivityKind.REVIEW -> "Ready for review"
            kind == ActivityKind.FAILED -> "Agent failed"
            runtime in setOf("cancelled", "canceled", "stopped", "interrupted") -> "Stopped"
            card.scope == "chat" -> "Replied"
            else -> "Finished"
        })
    }.sortedWith(compareByDescending<ActivityEntry> { it.at ?: Instant.MIN }.thenBy { it.card.id })

internal fun filterActivityEntries(
    entries: List<ActivityEntry>, projectId: String, query: String,
    projectNames: Map<String, String>, boardNames: Map<String, String>,
): List<ActivityEntry> = entries.filter {
    (projectId.isBlank() || it.card.projectId == projectId) &&
        (query.isBlank() || listOf(it.card.title, projectNames[it.card.projectId].orEmpty(),
            boardNames[it.card.boardId].orEmpty()).any { text -> text.contains(query.trim(), ignoreCase = true) })
}

internal data class ActivityInterval(val entry: ActivityEntry, val from: Float, val to: Float, val point: Boolean)

internal fun activityTimeline(entries: List<ActivityEntry>, now: Instant, hours: Int): List<ActivityInterval> {
    require(hours in listOf(1, 6, 24))
    val window = now.minusSeconds(hours * 3600L)
    fun fraction(at: Instant): Float = (Duration.between(window, at).toMillis().toDouble() /
        (hours * 3_600_000L)).toFloat().coerceIn(0f, 1f)
    return entries.mapNotNull { entry ->
        val end = if (entry.running) now else entry.at ?: return@mapNotNull null
        val start = entry.start ?: end
        if (end < window || start > now) return@mapNotNull null
        ActivityInterval(entry, fraction(start), fraction(end), entry.start == null)
    }
}

internal fun activityAge(at: Instant?, now: Instant): String {
    at ?: return "Time unavailable"
    val minutes = Duration.between(at, now).toMinutes().coerceAtLeast(0)
    return when {
        minutes < 1 -> "Just now"
        minutes < 60 -> "${minutes}m"
        minutes < 1440 -> "${minutes / 60}h"
        else -> "${minutes / 1440}d"
    }
}

internal fun activityResetText(value: String, now: Instant): String {
    val reset = activityInstant(value) ?: return "Reset time unavailable"
    val minutes = Duration.between(now, reset).toMinutes()
    return when {
        reset <= now -> "Reset due"
        minutes >= 1440 -> "Resets in ${minutes / 1440}d"
        minutes >= 60 -> "Resets in ${minutes / 60}h"
        else -> "Resets in ${minutes.coerceAtLeast(1)}m"
    }
}
