package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Project

/** What the board surfaces show: a project, one of its boards, and a lane. */
data class BoardSelection(val projectId: String = "", val boardId: String = "", val lane: String = "")

object BoardSelections {
    /**
     * Keeps [current] while it still exists; otherwise falls back to the first
     * project, its first board, and that board's first lane. A retired board
     * stays selectable so it can be restored.
     */
    fun resolve(projects: List<Project>, boards: Map<String, List<Board>>, retired: List<Board>, current: BoardSelection): BoardSelection {
        val projectId = current.projectId.takeIf { id -> projects.any { it.id == id } } ?: projects.firstOrNull()?.id.orEmpty()
        val projectBoards = boards[projectId].orEmpty()
        val boardId = current.boardId.takeIf { id -> (projectBoards + retired).any { it.id == id && it.project_id == projectId } }
            ?: projectBoards.firstOrNull()?.id.orEmpty()
        val board = projectBoards.firstOrNull { it.id == boardId }
        val lane = current.lane.takeIf { id -> board?.lanes?.any { it.id == id } == true } ?: board?.lanes?.firstOrNull()?.id.orEmpty()
        return BoardSelection(projectId, boardId, lane)
    }
}
