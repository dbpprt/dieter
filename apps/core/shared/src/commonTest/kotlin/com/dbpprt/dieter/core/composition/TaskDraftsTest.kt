package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Label
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.core.state.CaptureFailure
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import okio.ByteString.Companion.encodeUtf8

class TaskDraftsTest {
    private val harnesses = listOf(Harness(id = "codex", name = "Codex", default_model = "first", models = listOf(HarnessModel(id = "first", name = "First"), HarnessModel(id = "second", name = "Second"))))
    private val defaults = HarnessSelection("codex", "first", "low")
    private val board = Board(
        id = "b1", lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running"), Lane("review", "Review")),
        labels = listOf(Label(id = "l1", name = "Bug"), Label(id = "l2", name = "UI")),
    )
    private fun file(name: String, text: String = "exact bytes") = MessagePart(type = "file", filename = name, data_ = text.encodeUtf8())

    @Test fun attachmentOnlyTitleUsesTheFilenameWithoutAGeneratedTitle() {
        val draft = TaskDrafts.admit(CaptureDraft(id = "c"), file("screenshot.png"))
        assertEquals("screenshot.png", TaskDrafts.creationTitle(draft))
        assertFalse(TaskDrafts.generatesTitle(draft))
        assertTrue(TaskDrafts.generatesTitle(TaskDrafts.prompt(draft, "Fix the crash")))
        assertFalse(TaskDrafts.generatesTitle(TaskDrafts.title(TaskDrafts.prompt(draft, "Fix the crash"), "Crash")))
    }

    @Test fun aFrozenDraftIgnoresLateEditsAndKeepsItsDestination() {
        val written = TaskDrafts.admit(TaskDrafts.prompt(CaptureDraft(id = "c", project_id = "p", board_id = "b1"), "original"), file("notes.txt"))
        val frozen = written.copy(submission_id = "submission", submitted = true)
        assertTrue(frozen.frozen)
        assertSame(frozen, TaskDrafts.prompt(frozen, "late edit"))
        assertSame(frozen, TaskDrafts.project(frozen, "other"))
        assertSame(frozen, TaskDrafts.board(frozen, board))
        assertSame(frozen, TaskDrafts.checkout(frozen, "k2"))
        assertSame(frozen, TaskDrafts.admit(frozen, file("late.txt")))
        assertSame(frozen, TaskDrafts.merge(frozen, TaskDrafts.prompt(CaptureDraft(id = "share"), "shared")))

        val editor = TaskDraftEditor(frozen)
        editor.edit { TaskDrafts.prompt(it.copy(submission_id = ""), "sneaky") }
        assertEquals("original", editor.state.value.task.prompt)
        assertEquals(listOf(file("notes.txt")), editor.state.value.task.attachments)
    }

    @Test fun editsApplyAtOnceInTheEditor() {
        val editor = TaskDraftEditor(CaptureDraft(id = "c"))
        assertEquals("c", editor.id)
        val next = editor.edit { TaskDrafts.prompt(it, "Investigate the flaky test") }
        assertEquals("Investigate the flaky test", next.task.prompt)
        assertEquals(next, editor.state.value)
        assertNull(editor.error.value)
    }

    @Test fun destinationsStartOverPerProjectAndKeepOnlyWhatABoardHas() {
        var draft = CaptureDraft(id = "c", project_id = "p", board_id = "old", checkout_id = "k1")
        draft = TaskDrafts.labels(draft, listOf("l1", "gone", "l1"))
        assertEquals(listOf("l1", "gone"), draft.task.label_ids)
        assertEquals(listOf("gone"), TaskDrafts.unavailableLabels(draft, board))
        assertEquals(listOf("l1"), TaskDrafts.removeUnavailableLabels(draft, board).task.label_ids)
        draft = TaskDrafts.lane(draft, "done")
        val moved = TaskDrafts.board(draft, board)
        assertEquals("b1", moved.board_id)
        assertEquals(listOf("l1"), moved.task.label_ids)
        assertEquals("todo", moved.task.lane, "a lane the board lacks falls back to its first")
        assertEquals("running", TaskDrafts.board(TaskDrafts.lane(draft, "running"), board).task.lane)
        assertEquals(listOf("l1", "l2"), TaskDrafts.toggleLabel(moved, "l2").task.label_ids)
        assertEquals(emptyList(), TaskDrafts.toggleLabel(moved, "l1").task.label_ids)

        val otherProject = TaskDrafts.project(moved, "p2")
        assertEquals("p2", otherProject.project_id)
        assertEquals("", otherProject.board_id)
        assertEquals("", otherProject.checkout_id)
        assertEquals(emptyList(), otherProject.task.label_ids)
        assertSame(moved, TaskDrafts.project(moved, "p"))
    }

    @Test fun rememberedSettingsApplyOnceAndNeverOverUserEdits() {
        // Written before the catalog arrived: text stays, settings wait for the catalog.
        var draft = TaskDrafts.prompt(CaptureDraft(id = "c"), "Written before connection")
        draft = TaskDrafts.initialize(draft, defaults, WorkspaceMode.WORKTREE, "todo", emptyList())
        assertEquals("", draft.task.provider)
        assertEquals("todo", draft.task.lane)
        assertEquals(WorkspaceMode.WORKTREE, TaskDrafts.workspaceMode(draft))
        // Early lane and workspace edits survive the arriving catalog.
        draft = TaskDrafts.workspaceMode(TaskDrafts.lane(draft, "running"), WorkspaceMode.PROJECT)
        draft = TaskDrafts.initialize(draft, defaults, WorkspaceMode.WORKTREE, "todo", harnesses)
        assertEquals("running", draft.task.lane)
        assertEquals(WorkspaceMode.PROJECT, TaskDrafts.workspaceMode(draft))
        assertEquals(defaults, TaskDrafts.selection(draft))
        assertEquals("Written before connection", draft.task.prompt)
        // A refreshed catalog keeps the user's agent choice.
        draft = TaskDrafts.choose(draft, HarnessSelection("codex", "second", "high", mapOf("fast_mode" to "true")))
        draft = TaskDrafts.initialize(draft, defaults, WorkspaceMode.WORKTREE, "todo", harnesses.map { it.copy(name = "Refreshed") })
        assertEquals(HarnessSelection("codex", "second", "high", mapOf("fast_mode" to "true")), TaskDrafts.selection(draft))
        // A remembered agent the catalog no longer offers is not applied.
        val retired = TaskDrafts.initialize(CaptureDraft(id = "d"), HarnessSelection("codex", "retired"), WorkspaceMode.WORKTREE, "todo", harnesses)
        assertEquals("", retired.task.provider)
    }

    @Test fun importsRecordWhyAFileCannotBeAdded() {
        var draft = CaptureDraft(id = "c")
        repeat(4) { draft = TaskDrafts.admit(draft, file("f$it.txt"), "content://$it") }
        assertEquals(4, draft.task.attachments.size)
        draft = TaskDrafts.admit(draft, file("fifth.txt"), "content://5")
        assertEquals(4, draft.task.attachments.size)
        assertEquals(listOf(CaptureFailure("content://5", "You can attach up to 4 images or files.")), draft.failures)
        assertFalse(draft.ready)
        draft = TaskDrafts.removeFailure(draft, draft.failures.single())
        assertTrue(draft.ready)
        assertFalse(TaskDrafts.importing(draft, true).ready)
        assertEquals(listOf("f0.txt", "f2.txt", "f3.txt"), TaskDrafts.removeAttachment(draft, 1).task.attachments.map { it.filename })
        assertEquals("empty.txt is empty.", TaskDrafts.admit(CaptureDraft(id = "e"), MessagePart(filename = "empty.txt")).failures.single().message)
    }

    @Test fun sharesMergeIntoAnOpenDraftWithContent() {
        val open = TaskDrafts.prompt(CaptureDraft(id = "open"), "Existing notes")
        val share = TaskDrafts.admit(TaskDrafts.prompt(CaptureDraft(id = "share"), "Shared link"), file("shared.png"))
        assertTrue(TaskDrafts.asksToMerge(open, share))
        assertFalse(TaskDrafts.asksToMerge(CaptureDraft(id = "blank"), share))
        assertFalse(TaskDrafts.asksToMerge(share, share))
        assertFalse(TaskDrafts.asksToMerge(null, share))
        val merged = TaskDrafts.merge(open, share)
        assertEquals("Existing notes\nShared link", merged.task.prompt)
        assertEquals(listOf("shared.png"), merged.task.attachments.map { it.filename })
        val full = (1..4).fold(open) { draft, index -> TaskDrafts.admit(draft, file("f$index.txt")) }
        assertEquals("You can attach up to 4 images or files.", TaskDrafts.mergeProblem(full, share))
        assertEquals(4, TaskDrafts.merge(full, share).task.attachments.size)
        assertEquals("You can attach up to 4 images or files.", TaskDrafts.merge(full, share).failures.single().message)
    }

    @Test fun summariesAndInputsDescribeTheTask() {
        var draft = TaskDrafts.initialize(CaptureDraft(id = "c", checkout_id = "k1"), defaults, WorkspaceMode.WORKTREE, "running", harnesses)
        assertEquals("Running · Worktree · Codex / First", TaskDrafts.summary(draft, board, harnesses))
        assertEquals("Todo · Project directory · Agent defaults", TaskDrafts.summary(CaptureDraft(id = "d"), board, emptyList()))
        draft = TaskDrafts.title(TaskDrafts.prompt(draft, "Fix it"), "Fix")
        val project = Project(id = "p", checkouts = listOf(Checkout(id = "k1", daemon_id = "d1")))
        val input = TaskDrafts.input(draft, project, board)
        assertEquals("k1", input.checkoutId)
        assertEquals("running", input.lane)
        assertEquals("Fix", input.title)
        assertEquals(defaults, input.selection)
        assertEquals("k2", TaskDrafts.input(draft, project, board, "k2").checkoutId)
        assertEquals(CreateConversationRequest(), CaptureDraft(id = "empty").task)
    }

    @Test fun destinationsAndCatalogsDecideWhatCanBeValidated() {
        val mac = Checkout(id = "mac", daemon_id = "mac", name = "mac")
        val linux = Checkout(id = "linux", daemon_id = "linux", name = "linux")
        assertEquals(CatalogState.LIVE, Creation.catalogState(mac, "mac", machineOnline = true))
        assertEquals(CatalogState.CACHED, Creation.catalogState(mac, "mac", machineOnline = false))
        assertEquals(CatalogState.NONE, Creation.catalogState(linux, "mac", machineOnline = true), "another machine's models never validate")
        assertEquals(CatalogState.NONE, Creation.catalogState(null, "mac", machineOnline = true))
        assertEquals(CatalogState.NONE, Creation.catalogState(mac, null, machineOnline = true))

        // A task queues offline against the cached catalog; a chat starts at once and needs it live.
        assertEquals(harnesses, Creation.catalog(chat = false, CatalogState.CACHED, harnesses))
        assertNull(Creation.catalog(chat = true, CatalogState.CACHED, harnesses))
        assertEquals(harnesses, Creation.catalog(chat = true, CatalogState.LIVE, harnesses))
        assertNull(Creation.catalog(chat = false, CatalogState.NONE, harnesses))

        assertTrue(Creation.needsCatalog(linux, machineOnline = true, CatalogState.NONE))
        assertFalse(Creation.needsCatalog(linux, machineOnline = false, CatalogState.NONE))
        assertFalse(Creation.needsCatalog(mac, machineOnline = true, CatalogState.LIVE))
        assertEquals("mac", Creation.catalogMachine(mac, "replica", "attached"))
        assertEquals("replica", Creation.catalogMachine(null, "replica", "attached"))
        assertEquals("attached", Creation.catalogMachine(null, "", "attached"))

        val project = Project(id = "p", checkouts = listOf(mac, linux))
        assertEquals("No checkouts available for this project", Creation.destinationStatus(project.copy(checkouts = emptyList()), null, false, CatalogState.NONE))
        assertEquals("Choose where this task will run", Creation.destinationStatus(project, null, false, CatalogState.NONE))
        assertEquals("Machine offline · choose an online destination", Creation.destinationStatus(project, mac, false, CatalogState.CACHED))
        assertEquals("Loading agent models…", Creation.destinationStatus(project, mac, true, CatalogState.NONE))
        assertEquals("mac", Creation.destinationStatus(project, mac, true, CatalogState.LIVE))
        assertTrue(Creation.offlineHint(CatalogState.CACHED).contains("queue on this device"))
        assertTrue(Creation.offlineHint(CatalogState.NONE).contains("Your draft is kept"))
        assertEquals(listOf("todo", "running"), Creation.startLanes(board).map { it.id })
        assertTrue(Creation.startsImmediately("running"))
        assertFalse(Creation.startsImmediately("todo"))
    }

    @Test fun projectLocationsUseCheckoutOwnersOnlineFirst() {
        fun checkout(id: String, daemon: String = id, detached: Boolean = false) = Checkout(id = id, daemon_id = daemon, detached = detached)
        val names = mapOf("office" to "mini-office", "laptop" to "mbp-office")
        val project = Project(id = "p", checkouts = listOf(checkout("laptop"), checkout("office")))
        assertEquals("mini-office · mbp-office (offline)", CaptureDestinations.checkoutSummary(project, { names[it] ?: it }) { it == "office" })
        val deduplicated = Project(id = "p", checkouts = listOf(checkout("one", "mac"), checkout("two", "mac"), checkout("linux", detached = true)))
        assertEquals("mac", CaptureDestinations.checkoutSummary(deduplicated, { it }) { true })
        assertEquals("No checkouts", CaptureDestinations.checkoutSummary(deduplicated.copy(checkouts = emptyList()), { it }) { true })
        val unknown = Project(id = "p", checkouts = listOf(checkout("unknown"), checkout("mac")))
        assertEquals("mac · unknown (unavailable)", CaptureDestinations.checkoutSummary(unknown, { it }) { if (it == "mac") true else null })
        assertEquals("mac (offline) · unknown (unavailable)", CaptureDestinations.checkoutSummary(unknown, { it }) { if (it == "mac") false else null })
        assertEquals("2 boards · 2 checkouts · Offline", CaptureDestinations.projectInfo(project, 2, offline = true))
        assertEquals("1 board", CaptureDestinations.projectInfo(Project(id = "q"), 1, offline = false))
    }
}
