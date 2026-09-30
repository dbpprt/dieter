package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.workspace.ChangeSection
import com.dbpprt.dieter.core.workspace.DiffLineKind
import com.dbpprt.dieter.core.workspace.MergeStrategy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import java.io.File

/** GIT scenario: an agent's worktree change is reviewed, merged locally, cleaned up, and its card moved to Done. */
class WorkspaceEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun anAgentChangeIsReviewedMergedAndCleanedUp() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val local = runtime.createConversation(
            CreateConversationRequest(
                project_id = fixture.projectId, board_id = fixture.boardId, lane = "running", title = "Write a file", prompt = "mock-concurrent-workspace-write",
                provider = "mock", model = "mock", effort = "low", workspace_mode = "worktree",
            ),
            chat = false,
        )
        val cardId = runtime.outbox.view.await(45.seconds) { local.id in it.resolutions }.resolve(local.id)
        runtime.workspace.state.await(60.seconds, describe = { "turn finished: ${runtime.workspace.state.value.card(cardId)}" }) { view ->
            view.card(cardId)?.let { it.initial_prompt_sent_at.isNotEmpty() && it.runtime != "running" && it.runtime != "starting" } == true
        }

        val review = runtime.workspaceReview()
        runtime.onCore { review.bind(cardId, fixture.daemonId) }
        runtime.onCore { review.refresh() }
        val loaded = review.view.await(30.seconds, describe = { "changes: ${review.view.value.copy(diff = null)}" }) { it.changeset?.files?.isNotEmpty() == true && it.diff != null }
        val file = loaded.changeset!!.files.single()
        assertTrue(file.path.startsWith(".dieter-mock-"), file.path)
        assertTrue(loaded.diffLines.any { it.kind == DiffLineKind.ADDITION })
        val card = runtime.workspace.state.value.card(cardId)!!
        assertTrue(review.availability(card).allowsMergeFlow)

        val merged = runtime.onCore { review.mergeFlow(MergeStrategy.SQUASH, subject = "Add mock file") }
        assertTrue(merged, "merge flow failed: op=${review.view.value.operation?.let { it.kind + " " + it.status + " " + it.error }} error=${review.view.value.error} logs=${review.view.value.logs.takeLast(5).map { it.message }}")
        assertEquals("Merged ${loaded.workspace!!.branch} into main · card moved to Done", review.view.value.toast)
        assertTrue(review.view.value.surfaceRemoved)
        runtime.workspace.state.await(20.seconds) { it.card(cardId)?.lane == "done" || it.card(cardId) == null }
    }

    @Test
    fun projectChangesStageADiffAndCloseIt() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val checkout = runtime.workspace.state.value.project(fixture.projectId)!!.checkouts.first { it.daemon_id == fixture.daemonId }
        File(checkout.path, "notes.txt").writeText("hello\n")
        val changes = runtime.projectChanges()
        runtime.onCore {
            changes.bind(fixture.projectId, checkout.id, fixture.daemonId)
            changes.refresh()
        }
        changes.view.await(30.seconds, describe = { "changes: ${changes.view.value.changes}" }) { view -> view.changes?.files?.any { it.path == "notes.txt" && it.unstaged } == true }

        runtime.onCore { changes.select("notes.txt", ChangeSection.UNSTAGED) }
        changes.view.await(30.seconds) { view -> view.diffLines.any { it.kind == DiffLineKind.ADDITION && it.text.contains("hello") } }
        runtime.onCore { changes.deselect() }
        val closed = changes.view.value
        assertEquals(null, closed.selection)
        assertEquals(null, closed.diff)
        assertTrue(closed.diffLines.isEmpty())

        assertTrue(runtime.onCore { changes.run("stage", mapOf("path" to "notes.txt")) }, "stage failed: ${changes.view.value.operationError}")
        val staged = changes.view.value
        assertTrue(staged.changes!!.files.single { it.path == "notes.txt" }.staged)
        assertEquals("Changes staged", staged.notice)
        runtime.onCore { changes.dismissMessages() }
        assertEquals(null, changes.view.value.notice)
    }
}
