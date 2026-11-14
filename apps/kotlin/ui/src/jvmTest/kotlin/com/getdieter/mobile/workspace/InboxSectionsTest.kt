package com.getdieter.mobile.workspace

import com.getdieter.api.v1.Card
import com.getdieter.client.v1.ActivityRow
import org.junit.Assert.assertEquals
import org.junit.Test

class InboxSectionsTest {
    private fun row(
        id: String,
        section: ActivityRow.Section,
        pinned: Boolean = false,
        kind: String = "",
    ) = ActivityRow(card = Card(id = id), section = section, pinned = pinned, kind = kind)

    @Test
    fun runningLeadsKeepsItsPinnedRowsAndReviewsSitBeforeRecent() {
        val rows =
            listOf(
                row("pinned-recent", ActivityRow.Section.SECTION_RECENT, pinned = true),
                row("pinned-running", ActivityRow.Section.SECTION_RUNNING, pinned = true),
                row("pinned-answer", ActivityRow.Section.SECTION_ATTENTION, pinned = true),
                row("answer", ActivityRow.Section.SECTION_ATTENTION),
                row("running", ActivityRow.Section.SECTION_RUNNING),
                row("recent", ActivityRow.Section.SECTION_RECENT),
                row("review", ActivityRow.Section.SECTION_RECENT, kind = "REVIEW"),
            )

        assertEquals(
            listOf(
                InboxSection.RUNNING to listOf("pinned-running", "running"),
                InboxSection.PINNED to listOf("pinned-recent", "pinned-answer"),
                InboxSection.ATTENTION to listOf("answer"),
                InboxSection.REVIEW to listOf("review"),
                InboxSection.RECENT to listOf("recent"),
            ),
            inboxSections(rows).map { (section, group) -> section to group.map { it.card!!.id } },
        )
    }

    @Test
    fun leavesOutEmptySectionsAndRowsWithoutCards() {
        val rows =
            listOf(
                ActivityRow(section = ActivityRow.Section.SECTION_RUNNING),
                row("recent", ActivityRow.Section.SECTION_RECENT),
            )

        assertEquals(listOf(InboxSection.RECENT), inboxSections(rows).map { it.first })
    }
}
