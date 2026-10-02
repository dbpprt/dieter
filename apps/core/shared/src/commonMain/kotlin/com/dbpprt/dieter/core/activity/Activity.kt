package com.dbpprt.dieter.core.activity

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.board.RuntimeState
import com.dbpprt.dieter.core.board.Runtimes
import com.dbpprt.dieter.core.presentation.Ages
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.presentation.LiveActivities
import com.dbpprt.dieter.core.runtime.Timestamps
import com.dbpprt.dieter.core.sync.mergeCardState
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant

enum class ActivityKind(val label: String, val needsYou: Boolean) {
    ANSWER("Answer", true),
    RUNNING("Running", false),
    UNREAD("Unread reply", true),
    REVIEW("Review", false),
    FAILED("Failed", false),
    RECENT("Recent", false),
}

enum class ActivitySection(val title: String) { ATTENTION("Needs attention"), RUNNING("Running"), RECENT("Recent") }

data class ActivityItem(
    val card: Card,
    val kind: ActivityKind,
    val detail: String,
    /** Latest agent activity; placement, title, and read changes never move it. */
    val at: Instant?,
    /** When the current (or last) turn started, when known. */
    val start: Instant?,
    val sortAt: Instant?,
    val projectName: String?,
    val boardName: String?,
) {
    val id: String get() = card.id
    val chat: Boolean get() = Cards.isChat(card)
    val running: Boolean get() = kind == ActivityKind.RUNNING

    /** Waits for the user: an answer or an unread reply. */
    val needsYou: Boolean get() = kind.needsYou
    val section: ActivitySection get() = when {
        kind.needsYou -> ActivitySection.ATTENTION
        running -> ActivitySection.RUNNING
        else -> ActivitySection.RECENT
    }

    /** Inbox "Finish": a board card waiting in review. */
    val canFinish: Boolean get() = !chat && Lanes.isReview(card.lane) && !running && kind != ActivityKind.ANSWER

    /** The card's title, or "Untitled chat" / "Untitled card". */
    val title: String get() = Activity.title(card)

    /** The time a row shows: when a running turn started (else its latest activity), otherwise the latest activity. */
    val shownAt: Instant? get() = if (running) start ?: at else at

    /** "Chat" or "Card". */
    val noun: String get() = if (chat) "Chat" else "Card"

    /** Where the row belongs: its project, a card's board, and [noun], e.g. "dieter · Main · Card". */
    val context: String get() = listOfNotNull(projectName, boardName?.takeUnless { chat }, noun).joinToString(" · ")
}

/**
 * One activity projection for the inbox, widgets, the island, the menu bar,
 * and notification decisions. Built from the merged directory and the bounded
 * conversation cache; it never fetches transcripts.
 */
object Activity {
    fun classify(card: Card): ActivityKind? {
        val state = Runtimes.classify(card.runtime)
        return when {
            state == RuntimeState.NEEDS_INPUT -> ActivityKind.ANSWER
            state == RuntimeState.ACTIVE || state == RuntimeState.STOPPING -> ActivityKind.RUNNING
            Runtimes.isUnread(card) -> ActivityKind.UNREAD
            !Cards.isChat(card) && Lanes.isReview(card.lane) -> ActivityKind.REVIEW
            state == RuntimeState.FAILED -> ActivityKind.FAILED
            card.runtime.isNotBlank() && !card.runtime.equals("pending", ignoreCase = true) &&
                card.initial_prompt_sent_at.isNotEmpty() && card.runtime_updated_at.isNotEmpty() -> ActivityKind.RECENT
            else -> null
        }
    }

    private val stopped = setOf("cancelled", "canceled", "stopped", "interrupted")

    fun detail(card: Card, kind: ActivityKind, liveLabel: String?): String = when {
        card.runtime.equals("cancelling", ignoreCase = true) -> "Stopping…"
        kind == ActivityKind.RUNNING -> liveLabel ?: card.summary.ifBlank { "Working on your request" }
        kind == ActivityKind.UNREAD -> "New reply"
        kind == ActivityKind.ANSWER -> "Waiting for your answer"
        kind == ActivityKind.REVIEW -> "Ready for review"
        kind == ActivityKind.FAILED -> "Agent failed"
        card.runtime.trim().lowercase() in stopped -> "Stopped"
        Cards.isChat(card) -> "Replied"
        else -> "Finished"
    }

    /**
     * Folds duplicate copies of each card (the causal merge wins over
     * timestamps), drops archived ones, and builds the items, newest first
     * except that running rows keep their start order.
     */
    fun project(
        cards: List<Card>,
        conversations: Map<String, ConversationSnapshot>,
        projects: List<Project>,
        boards: List<Board>,
        hiddenMessageIds: Set<String> = emptySet(),
        excludedIds: Set<String> = emptySet(),
    ): List<ActivityItem> {
        val projectNames = projects.associate { it.id to it.name }
        val boardNames = boards.associate { it.id to it.name }
        val merged = cards.filter { it.id.isNotBlank() && it.id !in excludedIds }.groupBy { it.id }.mapNotNull { (_, copies) ->
            val latest = copies.maxBy { copy -> listOf(copy.updated_at, copy.runtime_updated_at, copy.last_activity_at).mapNotNull(Timestamps::parse).maxOrNull() ?: Instant.DISTANT_PAST }
            copies.fold(latest) { acc, copy -> if (copy === latest) acc else mergeCardState(acc, copy) }.takeUnless { it.archived }
        }
        return merged.mapNotNull { card ->
            val kind = classify(card) ?: return@mapNotNull null
            val at = listOfNotNull(Timestamps.parse(card.last_activity_at), Timestamps.parse(card.runtime_updated_at)).maxOrNull()
            // A cached transcript only describes this turn when it was read for the same runtime update.
            val snapshot = conversations[card.id]?.takeIf { it.detail?.card?.runtime_updated_at == card.runtime_updated_at }
            val messages = snapshot?.conversation?.messages.orEmpty().filterNot { it.id in hiddenMessageIds }
            val live = snapshot?.conversation?.takeIf { kind == ActivityKind.RUNNING }?.let { conversation ->
                LiveActivities.resolve(messages, conversation.pending_tools, conversation.task_plans, false, conversation.status, card.runtime, conversation.provider_status).english()
            }
            val detailStart = snapshot?.let { LiveActivities.turnStart(messages, null) }
            val start = detailStart?.takeIf { at != null && it <= at } ?: if (kind == ActivityKind.RUNNING) Timestamps.parse(card.runtime_updated_at) else null
            val sortAt = if (kind == ActivityKind.RUNNING) {
                Timestamps.parse(card.runtime_updated_at) ?: Timestamps.parse(card.initial_prompt_sent_at) ?: Timestamps.parse(card.created_at)
            } else {
                at
            }
            ActivityItem(card, kind, detail(card, kind, live), at, start, sortAt, projectNames[card.project_id], card.board_id.takeIf { it.isNotEmpty() }?.let(boardNames::get))
        }.sortedWith(compareByDescending<ActivityItem> { it.sortAt ?: Instant.DISTANT_PAST }.thenBy { it.id })
    }

    fun sections(items: List<ActivityItem>): Map<ActivitySection, List<ActivityItem>> =
        ActivitySection.entries.associateWith { section -> items.filter { it.section == section } }

    /** Project (blank = all) and a trimmed, case-insensitive query over title, project, and board. */
    fun filter(items: List<ActivityItem>, projectId: String?, query: String): List<ActivityItem> =
        items.filter { item ->
            (projectId.isNullOrBlank() || item.card.project_id == projectId) && matches(query, item.card.title, item.projectName, item.boardName)
        }

    /** Whether the trimmed [query] occurs in [title], [projectName], or [boardName], ignoring case; a blank query matches. */
    fun matches(query: String, title: String, projectName: String?, boardName: String?): Boolean {
        val term = query.trim()
        return term.isEmpty() || listOfNotNull(title, projectName, boardName).any { it.contains(term, ignoreCase = true) }
    }

    /** A conversation's title, or "Untitled chat" / "Untitled card" when it has none. */
    fun title(card: Card): String = card.title.ifBlank { if (Cards.isChat(card)) "Untitled chat" else "Untitled card" }

    fun needsYouCount(items: List<ActivityItem>): Int = items.count { it.kind.needsYou }

    /** The Inbox header: "3 projects · 1 needs attention · 2 running" over [items]. */
    fun overview(projects: Int, items: List<ActivityItem>): String {
        val attention = needsYouCount(items)
        val running = items.count { it.running }
        return "${Counts.of(projects, "project")} · $attention ${Counts.word(attention, "needs", "need")} attention · $running running"
    }

    /** "Just now", "5m", "3h", "2d"; [suffix] appends " ago" except to "Just now". */
    fun age(at: Instant?, now: Instant, suffix: Boolean = false): String {
        at ?: return "Time unavailable"
        val age = Ages.span(now - at) ?: return "Just now"
        return if (suffix) "${age.compact} ago" else age.compact
    }

    data class TimelineBar(val item: ActivityItem, val from: Double, val to: Double, val point: Boolean)

    /** A row's place in a timeline window, as fractions of it; [point] when only its end is known. */
    data class TimelineSpan(val from: Double, val to: Double, val point: Boolean)

    /** Bars within the last [hours], in [items]' order; running work extends to [now], which is the last sync while offline. */
    fun timeline(items: List<ActivityItem>, now: Instant, hours: Int): List<TimelineBar> = items.mapNotNull { item ->
        span(item.start, item.at, item.running, now, hours)?.let { TimelineBar(item, it.from, it.to, it.point) }
    }

    /**
     * One row's bar within the last [hours] before [now]: from [start] (or
     * its end, as a point) to [at], or to [now] while [running]; null when
     * it lies outside the window or has no time.
     */
    fun span(start: Instant?, at: Instant?, running: Boolean, now: Instant, hours: Int): TimelineSpan? {
        val window = now - hours.hours
        val length = (now - window).inWholeMilliseconds.toDouble()
        val end = if (running) now else at ?: return null
        val begin = start ?: end
        if (end < window || begin > now) return null
        fun fraction(value: Instant) = ((value - window).inWholeMilliseconds / length).coerceIn(0.0, 1.0)
        return TimelineSpan(fraction(begin), fraction(end), point = start == null)
    }
}

/** The home-screen widget's rows. */
data class WidgetModel(val rows: List<Row>, val summary: String, val compact: Boolean) {
    enum class RowKind { WAITING, RUNNING, REVIEW, FAILED, CHAT }

    sealed interface Row {
        data class Header(val title: String) : Row
        /** [subtitle] is the project and kind, or in compact rows the detail and age; [detail] is what happens now. */
        data class Item(val id: String, val kind: RowKind, val title: String, val subtitle: String, val trailing: String, val highlighted: Boolean, val detail: String = "") : Row
    }

    enum class Style { AUTO, ACTIVITY, COMPACT }

    companion object {
        const val TITLE = "Inbox"
        const val EMPTY_BODY = "Activity from cards and chats appears here."

        /** Before the first sync while offline, the widget asks to open the app. */
        fun emptyTitle(synced: Boolean, connected: Boolean): String = if (!synced && !connected) "Open Dieter to connect" else "All quiet here"

        /**
         * The widget's freshness line. An absolute [time] (the platform's
         * formatting of the last sync) stays truthful when the host keeps a
         * snapshot for hours.
         */
        fun status(time: String?, connected: Boolean): String = when {
            time == null -> if (connected) "Syncing…" else "Not synced yet"
            connected -> "Updated $time"
            else -> "Offline · updated $time"
        }

        fun build(items: List<ActivityItem>, now: Instant, maxItems: Int = 12, showSections: Boolean = true, style: Style = Style.AUTO, widthDp: Int = 0, heightDp: Int = 0): WidgetModel {
            val compact = when (style) {
                Style.ACTIVITY -> false
                Style.COMPACT -> true
                Style.AUTO -> widthDp in 1..239 || heightDp in 1..199
            }
            var remaining = maxItems.coerceIn(1, 20)
            val rows = mutableListOf<Row>()
            val sections = Activity.sections(items)
            for (section in ActivitySection.entries) {
                val group = sections.getValue(section)
                val visible = group.take(remaining)
                if (visible.isEmpty()) continue
                remaining -= visible.size
                if (showSections && !compact) rows += Row.Header("${section.title} · ${group.size}")
                for (item in visible) {
                    val kind = when (item.kind) {
                        ActivityKind.ANSWER, ActivityKind.UNREAD -> RowKind.WAITING
                        ActivityKind.RUNNING -> RowKind.RUNNING
                        ActivityKind.REVIEW -> RowKind.REVIEW
                        ActivityKind.FAILED -> RowKind.FAILED
                        ActivityKind.RECENT -> RowKind.CHAT
                    }
                    val trailing = Activity.age(item.at, now)
                    val subtitle = if (compact) listOf(item.detail, trailing.takeIf { it != "Just now" }).filterNotNull().joinToString(" · ")
                    else listOfNotNull(item.projectName, if (item.chat) "Chat" else "Card").joinToString(" · ")
                    rows += Row.Item(item.id, kind, item.title, subtitle, trailing, item.kind.needsYou, item.detail)
                }
            }
            val attention = sections.getValue(ActivitySection.ATTENTION).size
            val running = sections.getValue(ActivitySection.RUNNING).size
            val summary = when {
                attention + running > 0 && compact -> "$attention need attention\n$running running"
                attention + running > 0 -> "$attention need attention · $running running"
                items.isNotEmpty() -> "${items.size} recent conversation${if (items.size == 1) "" else "s"}"
                else -> "Cards and chats, together"
            }
            return WidgetModel(rows, summary, compact)
        }
    }
}

/** Counts over the whole activity feed, for the island and the menu bar. */
data class ActivityCounts(
    val running: Int = 0,
    /** Rows waiting for the user: an answer or an unread reply. */
    val attention: Int = 0,
    /** Every other row: review, failed, and finished work. */
    val recent: Int = 0,
    /** Board cards in a review lane, whatever their agent does. */
    val review: Int = 0,
    /** Delegated agents at work across every row. */
    val subagents: Int = 0,
) {
    companion object {
        fun of(items: List<ActivityItem>) = ActivityCounts(
            running = items.count { it.running },
            attention = items.count { it.needsYou },
            recent = items.count { !it.running && !it.needsYou },
            review = items.count { !it.chat && Lanes.isReview(it.card.lane) },
            subagents = items.sumOf { it.card.active_subagents.size },
        )
    }
}

/**
 * The macOS island: running work, then what waits for the user, then the
 * rest, each group in the Inbox's order, with counts over the whole feed.
 */
data class IslandModel(val items: List<ActivityItem>, val running: Int, val attention: Int, val recent: Int, val subagents: Int) {
    val accessibility: String get() = "Dieter Island. $running running, $attention need attention, $recent recent."

    companion object {
        const val MAX_ROWS = 4

        fun build(items: List<ActivityItem>): IslandModel {
            val counts = ActivityCounts.of(items)
            val running = items.filter { it.running }
            val attention = items.filter { it.needsYou }
            val rest = items.filter { !it.running && !it.needsYou }
            return IslandModel((running + attention + rest).take(MAX_ROWS), counts.running, counts.attention, counts.recent, counts.subagents)
        }
    }
}

/** The macOS menu bar: what needs you, then recent results from the last six hours. */
object MenuBar {
    const val MAX_ROWS = 4
    val RECENT_WINDOW: Duration = 6.hours

    fun items(items: List<ActivityItem>, now: Instant): List<ActivityItem> {
        val actionable = items.filter { it.kind.needsYou || it.kind == ActivityKind.REVIEW }
        val results = items.filter { recent(it) && it.at?.let { at -> now - at <= RECENT_WINDOW } == true }
        return (actionable + results).take(MAX_ROWS)
    }

    /** A row's line in the menu: "Needs you", "Unread reply", "Ready for review", "Failed", or "Finished". */
    fun title(kind: ActivityKind): String = when (kind) {
        ActivityKind.ANSWER -> "Needs you"
        ActivityKind.UNREAD -> "Unread reply"
        ActivityKind.REVIEW -> "Ready for review"
        ActivityKind.FAILED -> "Failed"
        ActivityKind.RUNNING -> "Running"
        ActivityKind.RECENT -> "Finished"
    }

    /** When the next recent row leaves the six-hour window after [now], so the menu changes; null when none will. */
    fun nextChange(items: List<ActivityItem>, now: Instant): Instant? =
        items.filter { recent(it) }.mapNotNull { it.at?.plus(RECENT_WINDOW) }.filter { it >= now }.minOrNull()?.plus(1.milliseconds)

    private fun recent(item: ActivityItem): Boolean = item.kind == ActivityKind.FAILED || item.kind == ActivityKind.RECENT
}
