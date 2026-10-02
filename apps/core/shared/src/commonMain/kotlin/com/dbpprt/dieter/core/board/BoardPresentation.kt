package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.presentation.AgeUnit
import com.dbpprt.dieter.core.presentation.Ages
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Instant

enum class ProjectSort(val label: String) { MANUAL("Manual"), ATTENTION("Needs you"), NAME("Name") }

/** What tapping a project does: create its first board, open its only board, or show its boards. */
enum class ProjectTap { CREATE_BOARD, OPEN_BOARD, EXPAND }

/** One project folder as a project list shows it. */
data class ProjectFolderGroup(
    val folder: NavigationFolder,
    /** Its matching projects, in the list's order. */
    val projects: List<Project>,
    /** Its projects show: the folder is expanded, or a search runs. */
    val showProjects: Boolean,
    /** Boards of its projects with a card waiting in review. */
    val reviewBoards: Int,
    /** "2 projects · 1 needs review", else "2 projects · 3 boards". */
    val summary: String,
) {
    /** The header's count: boards waiting in review, else its projects. */
    val count: Int get() = reviewBoards.takeIf { it > 0 } ?: projects.size
}

/** A project list: pinned projects, folders with their projects, and the projects in no folder. */
data class ProjectSections(
    val pinned: List<Project> = emptyList(),
    val folders: List<ProjectFolderGroup> = emptyList(),
    val unfiled: List<Project> = emptyList(),
) {
    /** No project shows, though folders may. */
    val empty: Boolean get() = pinned.isEmpty() && unfiled.isEmpty() && folders.all { it.projects.isEmpty() }
}

/** The projects overview: search, sorting, and what each row shows. */
object ProjectOverview {
    /** "3 projects · 2 folders". */
    fun summary(projects: Int, folders: Int): String = "${Counts.of(projects, "project")} · ${Counts.of(folders, "folder")}"

    /**
     * [projects] (in the shared order) as a list shows them, filtered by
     * [query] and sorted by [sort], where MANUAL keeps the pin and folder
     * orders: the [pinned] projects (IDs in pin order), the [folders] in
     * order with their projects, and the projects in no folder. A search
     * hides folders without a match and opens the rest. With [pinnedApart],
     * pinned projects show only in the pinned section; otherwise that
     * section is a shortcut above the full list and stays empty while
     * searching.
     */
    fun sections(
        projects: List<Project>,
        boards: Map<String, List<Board>>,
        cards: Map<String, List<Card>>,
        folders: List<NavigationFolder>,
        pinned: List<String>,
        query: String,
        sort: ProjectSort,
        pinnedApart: Boolean = false,
    ): ProjectSections {
        val shown = visible(projects, boards, cards, query, sort)
        val byId = shown.associateBy { it.id }
        val searching = query.isNotBlank()
        val pinnedIds = pinned.toSet()
        fun arranged(ids: List<String>): List<Project> =
            if (sort == ProjectSort.MANUAL) ids.distinct().mapNotNull(byId::get) else ids.toSet().let { members -> shown.filter { it.id in members } }
        fun listed(project: Project) = !pinnedApart || project.id !in pinnedIds
        val groups = folders.mapNotNull { folder ->
            val members = arranged(folder.itemIds).filter(::listed)
            if (searching && members.isEmpty()) return@mapNotNull null
            val memberBoards = members.flatMap { boards[it.id].orEmpty() }
            val review = boardsInReview(memberBoards, members.flatMap { cards[it.id].orEmpty() })
            val detail = if (review > 0) "$review ${Counts.word(review, "needs", "need")} review" else Counts.of(memberBoards.size, "board")
            ProjectFolderGroup(folder, members, folder.expanded || searching, review, "${Counts.of(members.size, "project")} · $detail")
        }
        return ProjectSections(
            pinned = if (searching && !pinnedApart) emptyList() else arranged(pinned),
            folders = groups,
            unfiled = NavigationLayout.unfiled(folders, shown.map { it.id }).mapNotNull(byId::get).filter(::listed),
        )
    }

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

    /** Board ID → its [attention] count, for boards with any; [cards] may span boards and include unfiled chats. */
    fun boardAttention(cards: List<Card>): Map<String, Int> =
        cards.filter { it.board_id.isNotEmpty() }.groupBy { it.board_id }.mapValues { (_, onBoard) -> attention(onBoard) }.filterValues { it > 0 }

    fun reviews(cards: List<Card>): Int = cards.count { Lanes.isReview(it.lane) }

    /** Cards with an agent at work or in a running lane. */
    fun running(cards: List<Card>): Int = cards.count { Runtimes.isActive(it.runtime) || Lanes.isRunning(it.lane) }

    /** Boards with at least one card waiting in review. */
    fun boardsInReview(boards: List<Board>, cards: List<Card>): Int = boards.count { board -> cards.any { it.board_id == board.id && Lanes.isReview(it.lane) } }

    /** A board's line in the switcher: "4 cards · 1 needs review", else its activity. */
    fun boardSummary(cards: List<Card>): String {
        val reviews = reviews(cards)
        val activity = if (reviews > 0) "$reviews ${Counts.word(reviews, "needs", "need")} review" else activity(cards)
        return "${Counts.of(cards.size, "card")} · $activity"
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
        val age = Ages.span(now - at, weeks = true) ?: return "now"
        return if (age.unit == AgeUnit.MINUTES) "${age.count}min" else age.compact
    }
}
