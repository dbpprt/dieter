package com.dbpprt.dieter.core.schedules

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.sync.MachineSnapshot
import com.dbpprt.dieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class SchedulesTest {
    private fun store(): WorkspaceStore = WorkspaceStore().apply {
        applyMachines(
            listOf(
                MachineSnapshot(
                    "d1",
                    projects = listOf(Project(id = "p", name = "Dieter", checkouts = listOf(Checkout(id = "c1", project_id = "p", daemon_id = "d1")))),
                    boards = listOf(Board(id = "b1", project_id = "p"), Board(id = "b2", project_id = "p")),
                    cards = emptyList(),
                    chats = emptyList(),
                ),
            ),
        )
    }

    @Test
    fun aNewDraftStartsOnTheProjectsBoardAndCheckout() = runTest {
        val schedules = Schedules(offlineSessions(), store(), backgroundScope)
        assertFailsWith<CoreException> { schedules.draft(null, null, null, "UTC") }
        schedules.bind("p")
        val draft = schedules.draft(null, null, "b2", "Europe/Berlin")
        assertEquals(
            listOf("p", "c1", "b2", "Europe/Berlin", "0 9 * * 1-5", "Scheduled work · {{date}}", "worktree", ""),
            listOf(draft.project_id, draft.checkout_id, draft.board_id, draft.timezone, draft.cron, draft.title_template, draft.workspace_mode, draft.provider),
        )
        val fallback = schedules.draft(null, "gone", "gone", " ")
        assertEquals(listOf("c1", "b1", "UTC"), listOf(fallback.checkout_id, fallback.board_id, fallback.timezone), "the only checkout, the first board, and UTC")
    }

    @Test
    fun aFailedChangeIsTheViewsActionError() = runTest {
        val schedules = Schedules(offlineSessions(), store(), backgroundScope)
        schedules.bind("p")
        assertFailsWith<CoreException> { schedules.setEnabled("gone", enabled = false) }
        assertEquals("The schedule is no longer available.", schedules.view.value.actionError, "a schedule that is gone is reported like any failed change")
        schedules.clearActionError()
        assertEquals(null, schedules.view.value.actionError)
    }

    @Test
    fun aPendingPreviewShowsUntilTheEditorCloses() = runTest {
        val schedules = Schedules(offlineSessions(), store(), backgroundScope)
        schedules.bind("p")
        schedules.preview("0 9 * * 1-5", "UTC")
        assertTrue(schedules.view.value.previewLoading)
        schedules.preview(" ", "UTC")
        assertFalse(schedules.view.value.previewLoading, "a blank timing previews nothing")
        schedules.preview("0 9 * * *", "UTC")
        assertTrue(schedules.view.value.previewLoading)
        schedules.closeEditor()
        assertFalse(schedules.view.value.previewLoading)
        schedules.preview("0 9 * * *", "UTC")
        schedules.bind("q")
        assertFalse(schedules.view.value.previewLoading, "another project starts without a preview")
    }
}
