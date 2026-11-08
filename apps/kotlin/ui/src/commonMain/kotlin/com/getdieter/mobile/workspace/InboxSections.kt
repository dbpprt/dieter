package com.getdieter.mobile.workspace

import com.getdieter.client.v1.ActivityRow

/**
 * Where a row sits in the Inbox, top to bottom. Running work always leads, pinned or not; pins
 * follow, then what needs the user, cards waiting for review, and the rest.
 */
internal enum class InboxSection {
    RUNNING,
    PINNED,
    ATTENTION,
    REVIEW,
    RECENT,
}

internal val ActivityRow.inboxSection: InboxSection
    get() =
        when {
            section == ActivityRow.Section.SECTION_RUNNING -> InboxSection.RUNNING
            pinned -> InboxSection.PINNED
            section == ActivityRow.Section.SECTION_ATTENTION -> InboxSection.ATTENTION
            kind == "REVIEW" -> InboxSection.REVIEW
            else -> InboxSection.RECENT
        }

/** [rows] grouped in Inbox order, each group in its given order; empty groups are left out. */
internal fun inboxSections(rows: List<ActivityRow>): List<Pair<InboxSection, List<ActivityRow>>> {
    val groups = rows.filter { it.card != null }.groupBy { it.inboxSection }
    return InboxSection.entries.mapNotNull { section -> groups[section]?.let { section to it } }
}
