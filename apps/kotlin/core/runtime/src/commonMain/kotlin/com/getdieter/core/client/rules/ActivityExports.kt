package com.getdieter.core.client.rules

import com.getdieter.api.v1.Card
import com.getdieter.client.v1.ActivityRow
import com.getdieter.client.v1.ActivityTimelineBar
import com.getdieter.core.activity.Activity
import com.getdieter.core.activity.InboxRuleText
import com.getdieter.core.activity.InboxSection
import com.getdieter.core.activity.InboxStatus
import kotlin.time.Instant

/**
 * Inbox rules a view applies while rendering its rows. Times are epoch milliseconds; 0 means
 * unknown.
 */
object ActivityExports {
    /**
     * Whether a row matches the search: the trimmed [query] in its title, project, or board name,
     * ignoring case; blank matches.
     */
    fun activityMatches(
        query: String,
        title: String,
        projectName: String,
        boardName: String,
    ): Boolean = Activity.matches(query, title, projectName, boardName)

    /**
     * A conversation's shown title: its [title], or "Untitled chat" / "Untitled card" when blank.
     */
    fun conversationTitle(title: String, scope: String, boardId: String): String =
        Activity.title(Card(title = title, scope = scope, board_id = boardId))

    /** What an Inbox rule does in words, e.g. "Hide project dieter or label urgent". */
    fun inboxRuleSummary(
        hide: Boolean,
        matchAll: Boolean,
        projectNames: List<String>,
        labelNames: List<String>,
    ): String = InboxRuleText.summary(hide, matchAll, projectNames, labelNames)

    /** The Inbox status filters in menu order, by name: "ALL", "NEEDS_YOU", "RUNNING", … */
    fun inboxStatuses(): List<String> = InboxStatus.entries.map { it.name }

    /** A status filter's title: "All", "Needs you", "Running", "Pinned", "Review". */
    fun inboxStatusTitle(status: String): String = InboxStatus.named(status).title

    /** Whether a row of activity [kind] passes the status filter named [status]. */
    fun inboxStatusMatches(
        status: String,
        kind: String,
        needsYou: Boolean,
        pinned: Boolean,
    ): Boolean = InboxStatus.named(status).matches(kind, needsYou, pinned)

    /** An Inbox section's header by its `ActivityRow.Section` value: "Needs you", "Pinned", … */
    fun inboxSectionTitle(section: Int): String =
        InboxSection.of(
                ActivityRow.Section.fromValue(section) ?: ActivityRow.Section.SECTION_RECENT
            )
            .title

    /** The timeline windows the range menu offers, in hours. */
    fun timelineHours(): List<Int> = Activity.TIMELINE_HOURS

    /** "Last 6h". */
    fun timelineRangeTitle(hours: Int): String = Activity.rangeTitle(hours)

    /** "No activity in the last 6h". */
    fun timelineEmpty(hours: Int): String = Activity.emptyTimeline(hours)

    /**
     * A row's bar on the timeline of the last [hours] before [nowMillis]: from [startMillis] (or a
     * point at its end) to [atMillis], or to now while [running]; not shown outside the window.
     */
    fun timelineBar(
        startMillis: Long,
        atMillis: Long,
        running: Boolean,
        nowMillis: Long,
        hours: Int,
    ): ActivityTimelineBar {
        val span =
            Activity.span(
                FormatExports.instant(startMillis),
                FormatExports.instant(atMillis),
                running,
                Instant.fromEpochMilliseconds(nowMillis),
                hours,
            ) ?: return ActivityTimelineBar()
        return ActivityTimelineBar(
            shown = true,
            start_fraction = span.from,
            end_fraction = span.to,
            point = span.point,
        )
    }
}
