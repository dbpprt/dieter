package com.dbpprt.dieter.widget

import com.dbpprt.dieter.ui.ActivityKind
import com.dbpprt.dieter.ui.activityAge
import com.dbpprt.dieter.ui.activityDetails
import com.dbpprt.dieter.ui.buildActivityEntries
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.Project
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// LAST_FINISHED is a persisted style identifier. All styles now show the same
// Inbox; this option only chooses a compact presentation.
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

enum class WidgetRowKind { WAITING, RUNNING, REVIEW, FAILED, CHAT }

sealed interface WidgetRow {
    data class Section(val title: String) : WidgetRow
    data class Item(
        val cardId: String,
        val kind: WidgetRowKind,
        val title: String,
        val subtitle: String,
        val detail: String,
        val trailing: String,
        val highlighted: Boolean = false,
    ) : WidgetRow
}

data class WidgetActivityModel(
    val compact: Boolean,
    val headerTitle: String,
    val summary: String,
    val statusText: String,
    val rows: List<WidgetRow>,
    val emptyTitle: String,
    val emptyBody: String,
)

/** The same canonical conversation selection, timestamps and attention rules as Inbox. */
fun buildWidgetModel(
    cards: List<Card>,
    conversations: Map<String, ConversationSnapshot>,
    projects: List<Project>,
    lastSyncAtMs: Long,
    connected: Boolean,
    config: WidgetConfig,
    compact: Boolean,
    now: Instant = Instant.now(),
): WidgetActivityModel {
    val entries = buildActivityEntries(cards, activityDetails(conversations))
    val attention = entries.filter { it.needsYou }
    val running = entries.filter { it.running }
    val recent = entries.filter { !it.needsYou && !it.running }
    val names = projects.associate { it.id to it.name }
    var remaining = config.maxItems.coerceIn(1, WidgetConfig.MAX_ITEM_CHOICES.last())
    val rows = buildList {
        listOf("Needs attention" to attention, "Running" to running, "Recent" to recent).forEach { (title, group) ->
            val visible = group.take(remaining)
            if (visible.isNotEmpty() && config.showSections && !compact) add(WidgetRow.Section("$title · ${group.size}"))
            visible.forEach { entry ->
                val card = entry.card
                add(WidgetRow.Item(
                    cardId = card.id,
                    kind = when (entry.kind) {
                        ActivityKind.ANSWER, ActivityKind.UNREAD -> WidgetRowKind.WAITING
                        ActivityKind.RUNNING -> WidgetRowKind.RUNNING
                        ActivityKind.REVIEW -> WidgetRowKind.REVIEW
                        ActivityKind.FAILED -> WidgetRowKind.FAILED
                        ActivityKind.RECENT -> WidgetRowKind.CHAT
                    },
                    title = card.title.ifBlank { "Untitled conversation" },
                    subtitle = listOfNotNull(names[card.projectId]?.takeIf(String::isNotBlank),
                        if (card.scope == "chat" && card.boardId.isBlank()) "Chat" else "Card").joinToString(" · "),
                    detail = entry.detail,
                    trailing = entry.at?.let { activityAge(it, now) }.orEmpty(),
                    highlighted = entry.needsYou,
                ))
            }
            remaining -= visible.size
        }
    }
    return WidgetActivityModel(
        compact = compact,
        headerTitle = "Inbox",
        summary = when {
            compact && (attention.isNotEmpty() || running.isNotEmpty()) -> "${attention.size} need attention\n${running.size} running"
            attention.isNotEmpty() || running.isNotEmpty() -> "${attention.size} need attention · ${running.size} running"
            entries.isNotEmpty() -> "${entries.size} recent ${if (entries.size == 1) "conversation" else "conversations"}"
            else -> "Cards and chats, together"
        },
        statusText = widgetStatusText(lastSyncAtMs, connected, now),
        rows = rows,
        emptyTitle = if (lastSyncAtMs <= 0 && !connected) "Open Dieter to connect" else "All quiet here",
        emptyBody = "Activity from cards and chats appears here.",
    )
}

internal fun widgetStatusText(lastSyncAtMs: Long, connected: Boolean, now: Instant): String {
    if (lastSyncAtMs <= 0) return if (connected) "Syncing…" else "Not synced yet"
    // An absolute timestamp stays truthful when Android suspends background
    // execution and the host retains this RemoteViews snapshot for hours.
    val time = DateTimeFormatter.ofPattern("MMM d, HH:mm").withZone(ZoneId.systemDefault())
        .format(Instant.ofEpochMilli(lastSyncAtMs))
    return if (connected) "Updated $time" else "Offline · updated $time"
}
