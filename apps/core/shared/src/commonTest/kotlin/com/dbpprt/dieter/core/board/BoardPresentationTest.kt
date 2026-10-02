package com.dbpprt.dieter.core.board

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.navigation.NavigationFolder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.time.Instant

class BoardPresentationTest {
    private val board = Board(id = "b", lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running"), Lane("review", "Review"), Lane("done", "Done")))

    @Test fun placementWinsOverCreationTimeInBothDirections() {
        val cards = listOf(
            Card(id = "a", order_key = "100", created_at = "2099-01-01T00:00:00Z"),
            Card(id = "b", order_key = "300", created_at = "2020-01-01T00:00:00Z"),
            Card(id = "c", order_key = "200"),
        )
        assertEquals(listOf("b", "c", "a"), Lanes.ordered(cards).map { it.id })
        assertEquals(listOf("a", "c", "b"), Lanes.ordered(cards, descending = false).map { it.id })
    }

    @Test fun simultaneousPlacementTiesUseStableIdentity() {
        val cards = listOf("b", "a", "c").map { Card(id = it, order_key = "same") }
        assertEquals(listOf("c", "b", "a"), Lanes.ordered(cards).map { it.id })
    }

    @Test fun pendingMovesApplyBeforeTheDirection() {
        val cards = listOf(Card(id = "a", lane = "todo", order_key = "1"), Card(id = "b", lane = "todo", order_key = "2"), Card(id = "c", lane = "todo", order_key = "3"))
        val moves = mapOf("c" to PendingMove(lane = "todo", beforeCardId = "a"))
        assertEquals(listOf("c", "a", "b"), Lanes.ordered(cards, moves, descending = false).map { it.id })
        assertEquals(listOf("b", "a", "c"), Lanes.ordered(cards, moves).map { it.id })
    }

    @Test fun startMovesAStartableCardToTheRunningLane() {
        val card = Card(id = "c", scope = "board", lane = "todo", initial_prompt = "Fix it")
        assertEquals("running", CardPolicy.startLane(card, board))
        assertNull(CardPolicy.startLane(card.copy(initial_prompt_sent_at = "2026-01-01T00:00:00Z"), board))
        assertNull(CardPolicy.startLane(card, Board(id = "b", lanes = listOf(Lane("todo", "Todo")))))
        assertNull(CardPolicy.startLane(card, null))
    }

    @Test fun runtimeBadgeUsesAgentStateAndPendingOperations() {
        listOf("running", "working", "streaming", " Running ").forEach { assertEquals("Running", Runtimes.badge(it), it) }
        listOf("idle", "completed", "failed", "cancelled", "").forEach { assertNull(Runtimes.badge(it), it) }
        assertEquals("Starting…", Runtimes.badge("starting"))
        assertEquals("Starting…", Runtimes.badge("idle", CardOperation.STARTING))
        assertEquals("Stopping…", Runtimes.badge("running", CardOperation.CANCELLING))
        assertEquals("Stopping…", Runtimes.badge("cancelling"))
        assertEquals("Running", Runtimes.badge("running", CardOperation.MOVING))
    }

    @Test fun projectSortSupportsManualAttentionAndName() {
        val projects = listOf(Project(id = "zulu", name = "Zulu"), Project(id = "alpha", name = "Alpha"), Project(id = "beta", name = "Beta"))
        val cards = mapOf("beta" to listOf(Card(id = "r", lane = "review")))
        fun sorted(sort: ProjectSort) = ProjectOverview.visible(projects, emptyMap(), cards, "", sort).map { it.id }
        assertEquals(listOf("zulu", "alpha", "beta"), sorted(ProjectSort.MANUAL))
        assertEquals(listOf("beta", "alpha", "zulu"), sorted(ProjectSort.ATTENTION))
        assertEquals(listOf("alpha", "beta", "zulu"), sorted(ProjectSort.NAME))
    }

    @Test fun projectSearchMatchesNamePathAndBoards() {
        val project = Project(id = "p", name = "Dieter", path = "/src/dieter")
        val boards = listOf(Board(id = "b", name = "Release train"))
        assertEquals(true, ProjectOverview.matches(project, boards, " train "))
        assertEquals(true, ProjectOverview.matches(project, emptyList(), "SRC"))
        assertEquals(false, ProjectOverview.matches(project, boards, "gateway"))
        assertEquals(ProjectTap.CREATE_BOARD, ProjectOverview.tap(0))
        assertEquals(ProjectTap.OPEN_BOARD, ProjectOverview.tap(1))
        assertEquals(ProjectTap.EXPAND, ProjectOverview.tap(3))
    }

    @Test fun boardSummariesPreferReviewsThenActivity() {
        assertEquals("0 cards · empty", ProjectOverview.boardSummary(emptyList()))
        assertEquals("1 card · quiet", ProjectOverview.boardSummary(listOf(Card(id = "a", lane = "todo"))))
        assertEquals("2 cards · 1 running", ProjectOverview.boardSummary(listOf(Card(id = "a", lane = "todo"), Card(id = "b", lane = "todo", runtime = "working"))))
        assertEquals("2 cards · 2 need review", ProjectOverview.boardSummary(listOf(Card(id = "a", lane = "review"), Card(id = "b", lane = "In review"))))
    }

    @Test fun cardAgesUseTheLaterOfModificationAndActivity() {
        val now = Instant.parse("2026-08-14T12:00:00Z")
        fun age(updated: String, activity: String) = CardAges.compact(Card(id = "c", updated_at = updated, last_activity_at = activity), now)
        assertEquals("10min", age("2026-08-14T11:50:00Z", "2026-08-14T10:00:00Z"))
        assertEquals("2h", age("2026-08-09T12:00:00Z", "2026-08-14T10:00:00Z"))
        assertEquals("5d", age("2026-08-09T12:00:00Z", ""))
        assertEquals("2w", age("2026-07-30T12:00:00Z", ""))
        assertEquals("now", age("2026-08-14T12:00:30Z", ""))
        assertEquals("", age("", "not-a-timestamp"))
    }

    @Test fun boardAttentionCountsReviewLanesAndWorkingAgentsPerBoard() {
        val cards = listOf(
            Card(id = "r", board_id = "b1", lane = "In review"),
            Card(id = "w", board_id = "b1", lane = "todo", runtime = "streaming"),
            Card(id = "q", board_id = "b1", lane = "todo", runtime = "waiting_for_user"),
            Card(id = "i", board_id = "b2", lane = "todo", runtime = "idle"),
            Card(id = "c", scope = "chat", runtime = "running"),
            Card(id = "f", scope = "chat", board_id = "b3", lane = "review"),
        )
        assertEquals(mapOf("b1" to 2, "b3" to 1), ProjectOverview.boardAttention(cards), "boards with none and unfiled chats are left out")
    }

    @Test fun projectListsGroupPinnedFoldersAndUnfiledProjects() {
        val projects = listOf("zulu", "alpha", "beta", "gamma", "delta").map { Project(id = it, name = it.replaceFirstChar { char -> char.uppercase() }) }
        val boards = mapOf("alpha" to listOf(Board(id = "a1", project_id = "alpha"), Board(id = "a2", project_id = "alpha")), "beta" to listOf(Board(id = "b1", project_id = "beta")))
        val cards = mapOf("beta" to listOf(Card(id = "r", board_id = "b1", lane = "review")))
        val folders = listOf(
            NavigationFolder("work", "Work", listOf("beta", "offline", "alpha")),
            NavigationFolder("later", "Later", listOf("delta"), expanded = false),
        )
        val pinned = listOf("gamma", "offline", "alpha", "gamma")
        fun sections(query: String = "", sort: ProjectSort = ProjectSort.MANUAL, apart: Boolean = false) =
            ProjectOverview.sections(projects, boards, cards, folders, pinned, query, sort, apart)

        val all = sections()
        assertEquals(listOf("gamma", "alpha"), all.pinned.map { it.id }, "pin order, available projects once each")
        assertEquals(listOf("beta", "alpha"), all.folders[0].projects.map { it.id }, "the folder's order")
        assertEquals("2 projects · 1 needs review", all.folders[0].summary)
        assertEquals(1, all.folders[0].count)
        assertEquals(true, all.folders[0].showProjects)
        assertEquals("1 project · 0 boards", all.folders[1].summary)
        assertEquals(1, all.folders[1].count, "without reviews the header counts projects")
        assertEquals(false, all.folders[1].showProjects)
        assertEquals(listOf("zulu", "gamma"), all.unfiled.map { it.id }, "pinned projects stay in their groups")

        val apart = sections(apart = true)
        assertEquals(listOf("beta"), apart.folders[0].projects.map { it.id })
        assertEquals(listOf("zulu"), apart.unfiled.map { it.id })

        val byName = sections(sort = ProjectSort.NAME, apart = true)
        assertEquals(listOf("alpha", "gamma"), byName.pinned.map { it.id })
        assertEquals(listOf("alpha", "beta", "gamma", "zulu"), sections(sort = ProjectSort.NAME).folders[0].projects.map { it.id } + sections(sort = ProjectSort.NAME).unfiled.map { it.id })

        val search = sections(query = "ALP")
        assertEquals(emptyList<Project>(), search.pinned, "the pinned shortcut hides while searching")
        assertEquals(listOf("work"), search.folders.map { it.folder.id }, "folders without a match hide")
        assertEquals(listOf("alpha"), search.folders.single().projects.map { it.id })
        assertEquals(true, sections(query = "delta").folders.single().showProjects, "a search opens collapsed folders")
        assertEquals(listOf("alpha"), sections(query = "alp", apart = true).pinned.map { it.id }, "apart, pinned matches stay in their section")
        assertEquals(false, search.empty)
        assertEquals(true, sections(query = "nothing").empty)
        assertEquals("3 projects · 1 folder", ProjectOverview.summary(3, 1))
        assertEquals("1 project · 0 folders", ProjectOverview.summary(1, 0))
    }
}
