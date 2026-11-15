package com.getdieter.core.activity

import com.getdieter.client.v1.ActivityRow

/**
 * Where a row sits in the Inbox, top to bottom, on every platform. Pinned holds the idle pinned
 * rows; a pinned row that needs the user or runs stays in that section.
 */
enum class InboxSection(val title: String) {
    NEEDS_YOU("Needs you"),
    RUNNING("Running"),
    PINNED("Pinned"),
    RECENT("Recent");

    val row: ActivityRow.Section
        get() =
            when (this) {
                NEEDS_YOU -> ActivityRow.Section.SECTION_ATTENTION
                RUNNING -> ActivityRow.Section.SECTION_RUNNING
                PINNED -> ActivityRow.Section.SECTION_PINNED
                RECENT -> ActivityRow.Section.SECTION_RECENT
            }

    companion object {
        fun of(section: ActivityRow.Section): InboxSection =
            when (section) {
                ActivityRow.Section.SECTION_ATTENTION -> NEEDS_YOU
                ActivityRow.Section.SECTION_RUNNING -> RUNNING
                ActivityRow.Section.SECTION_PINNED -> PINNED
                ActivityRow.Section.SECTION_RECENT -> RECENT
            }

        /**
         * [rows] (already in Inbox order) grouped into their sections, each group in its given
         * order; empty sections are left out.
         */
        fun group(rows: List<ActivityRow>): List<Pair<InboxSection, List<ActivityRow>>> {
            val groups = rows.groupBy { of(it.section) }
            return entries.mapNotNull { section -> groups[section]?.let { section to it } }
        }
    }
}

/** The Inbox's status filter; it narrows the rows but keeps their sections. */
enum class InboxStatus(val title: String) {
    ALL("All"),
    NEEDS_YOU("Needs you"),
    RUNNING("Running"),
    PINNED("Pinned"),
    REVIEW("Review");

    /** Whether a row of the core's activity [kind] passes; Pinned takes every pinned row. */
    fun matches(kind: String, needsYou: Boolean, pinned: Boolean): Boolean =
        when (this) {
            ALL -> true
            NEEDS_YOU -> needsYou
            RUNNING -> kind == ActivityKind.RUNNING.name
            PINNED -> pinned
            REVIEW -> kind == ActivityKind.REVIEW.name
        }

    fun matches(row: ActivityRow): Boolean = matches(row.kind, row.needs_you, row.pinned)

    companion object {
        /** Each status with how many of [rows] it matches, in menu order. */
        fun counts(rows: List<ActivityRow>): Map<InboxStatus, Int> =
            entries.associateWith { status ->
                rows.count(status::matches)
            }

        /** The status named [name] (an enum name), else [ALL]. */
        fun named(name: String): InboxStatus = entries.firstOrNull { it.name == name } ?: ALL
    }
}
