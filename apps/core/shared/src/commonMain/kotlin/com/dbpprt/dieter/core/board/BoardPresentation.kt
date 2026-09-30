package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Instant

enum class ProjectSort(val label: String) { MANUAL("Manual"), ATTENTION("Needs you"), NAME("Name") }

/** What tapping a project does: create its first board, open its only board, or show its boards. */
enum class ProjectTap { CREATE_BOARD, OPEN_BOARD, EXPAND }

/** The projects overview: search, sorting, and what each row shows. */
object ProjectOverview {
    /** Cards that want a look: waiting in review or with an agent at work. */
    fun attention(cards: List<Card>): Int = cards.count { Lanes.isReview(it.lane) || Runtimes.isActive(it.runtime) }

    /** A project matches by name, path, or one of its boards' names. */
    fun matches(project: Project, boards: List<Board>, query: String): Boolean {
        val term = query.trim()
        return term.isEmpty() || project.name.contains(term, ignoreCase = true) || project.path.contains(term, ignoreCase = true) ||
            boards.any { it.name.contains(term, ignoreCase = true) }
    }

    /** [projects] (already in the shared order) filtered by [query] and sorted by [sort]; ties by name. */
    fun visible(projects: List<Project>, boards: Map<String, List<Board>>, cards: Map<String, List<Card>>, query: String, sort: ProjectSort): List<Project> {
        val filtered = projects.filter { matches(it, boards[it.id].orEmpty(), query) }
        return when (sort) {
            ProjectSort.MANUAL -> filtered
            ProjectSort.ATTENTION -> filtered.sortedWith(compareByDescending<Project> { attention(cards[it.id].orEmpty()) }.thenBy { it.name.lowercase() })
            ProjectSort.NAME -> filtered.sortedBy { it.name.lowercase() }
        }
    }

    fun tap(boards: Int): ProjectTap = when (boards) {
        0 -> ProjectTap.CREATE_BOARD
        1 -> ProjectTap.OPEN_BOARD
        else -> ProjectTap.EXPAND
    }

    fun reviews(cards: List<Card>): Int = cards.count { Lanes.isReview(it.lane) }

    /** Cards with an agent at work or in a running lane. */
    fun running(cards: List<Card>): Int = cards.count { Runtimes.isActive(it.runtime) || Lanes.isRunning(it.lane) }

    /** Boards with at least one card waiting in review. */
    fun boardsInReview(boards: List<Board>, cards: List<Card>): Int = boards.count { board -> cards.any { it.board_id == board.id && Lanes.isReview(it.lane) } }

    /** A board's line in the switcher: "4 cards · 1 needs review", else its activity. */
    fun boardSummary(cards: List<Card>): String {
        val reviews = reviews(cards)
        val activity = if (reviews > 0) "$reviews ${if (reviews == 1) "needs" else "need"} review" else activity(cards)
        return "${cards.size} card${if (cards.size == 1) "" else "s"} · $activity"
    }

    /** "2 running", else "empty" or "quiet". */
    fun activity(cards: List<Card>): String {
        val running = running(cards)
        return when {
            running > 0 -> "$running running"
            cards.isEmpty() -> "empty"
            else -> "quiet"
        }
    }
}

/** A board's filters: machine, label, and text. */
object BoardFilters {
    /** Cards on [boardId] owned by [machineId] (null: any), with [labelId] (blank: any), matching [query] in title or summary. */
    fun cards(cards: List<Card>, boardId: String, machineId: String?, labelId: String, query: String): List<Card> {
        val term = query.trim()
        return cards.filter { card ->
            card.board_id == boardId && (machineId == null || card.owner_daemon_id == machineId) &&
                (labelId.isBlank() || labelId in card.label_ids) &&
                (term.isEmpty() || card.title.contains(term, ignoreCase = true) || card.summary.contains(term, ignoreCase = true))
        }
    }

    /** The machines owning the board's cards, by their [label]; worth a filter only when there are several. */
    fun machines(cards: List<Card>, boardId: String, label: (String) -> String): List<String> =
        cards.filter { it.board_id == boardId }.map { it.owner_daemon_id }.distinct().sortedBy(label)

    fun labelCount(cards: List<Card>, labelId: String): Int = if (labelId.isBlank()) cards.size else cards.count { labelId in it.label_ids }
}

object CardAges {
    /** "now", "5min", "3h", "2d", "3w" since the card was last modified or active, whichever is later; empty when unknown. */
    fun compact(card: Card, now: Instant): String {
        val at = listOfNotNull(Timestamps.parse(card.updated_at), Timestamps.parse(card.last_activity_at)).maxOrNull() ?: return ""
        val age = (now - at).coerceAtLeast(kotlin.time.Duration.ZERO)
        val minutes = age.inWholeMinutes
        return when {
            age.inWholeSeconds < 60 -> "now"
            minutes < 60 -> "${minutes}min"
            age.inWholeHours < 24 -> "${age.inWholeHours}h"
            age.inWholeDays < 7 -> "${age.inWholeDays}d"
            else -> "${age.inWholeDays / 7}w"
        }
    }
}
