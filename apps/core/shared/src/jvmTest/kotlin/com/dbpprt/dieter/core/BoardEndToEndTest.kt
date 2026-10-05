package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateBoardLabelRequest
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.board.CardOperation
import com.dbpprt.dieter.core.board.DropAnchors
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.IsolatedGateway
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

/** Board and card mutations against a real daemon. */
class BoardEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    private suspend fun cards(runtime: CoreRuntime, fixture: IsolatedGateway, vararg titles: String): List<String> = titles.map { title ->
        val local = runtime.createConversation(
            CreateConversationRequest(project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = title, prompt = "Do $title", defer_start = true, workspace_mode = "project"),
            chat = false,
        )
        runtime.outbox.view.await(describe = { "created $title" }) { local.id in it.resolutions }.resolve(local.id)
    }

    @Test
    fun movesReorderLabelRenameAndArchiveCards() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val (first, second, third) = cards(runtime, fixture, "First", "Second", "Third")
        runtime.awaitSynced(first, second, third)

        // Reorder within todo: put Third before First.
        assertTrue(runtime.onBoard { move(third, "todo", DropAnchors(beforeCardId = first)) })
        val todo = runtime.workspace.state.await(describe = { "reordered" }) { view ->
            Lanes.arrange(view.cards[fixture.projectId].orEmpty().filter { it.lane == "todo" }).map { it.id }.let { it.indexOf(third) < it.indexOf(first) }
        }
        assertTrue(Lanes.arrange(todo.cards[fixture.projectId].orEmpty().filter { it.lane == "todo" }).map { it.id }.containsAll(listOf(first, second, third)))

        // Cross-lane move.
        assertTrue(runtime.onBoard { move(second, "review") })
        runtime.workspace.state.await { it.card(second)?.lane == "review" }

        // While a change is in flight, repeating it (a double tap) does nothing and a different change is refused.
        runtime.onBoard {
            coroutineScope {
                val moving = async(start = CoroutineStart.UNDISPATCHED) { move(second, "done") }
                assertFalse(move(second, "done"), "a repeated change is a no-op")
                assertEquals(FailureKind.TRANSIENT, assertFailsWith<CoreException> { rename(second, "Elsewhere") }.kind)
                assertTrue(moving.await())
            }
        }
        runtime.workspace.state.await { it.card(second)?.lane == "done" }
        assertTrue(second !in runtime.board.view.value.errors, "a refused change leaves no card error")

        // Labels.
        val labelled = runtime.onMachine(fixture.daemonId) { it.CreateBoardLabel().execute(CreateBoardLabelRequest(board_id = fixture.boardId, name = "urgent", color = "#6558df")) }
        val label = labelled.labels.first { it.name == "urgent" }.id
        assertTrue(runtime.onBoard { addLabel(first, label) })
        assertFalse(runtime.onBoard { addLabel(first, label) }, "a label is never added twice")
        runtime.workspace.state.await { it.card(first)?.label_ids == listOf(label) }

        // Rename trims and skips no-ops.
        assertTrue(runtime.onBoard { rename(first, "  Renamed  ") })
        assertFalse(runtime.onBoard { rename(first, "Renamed") })
        runtime.workspace.state.await { it.card(first)?.title == "Renamed" }

        // Editing a never-started card changes its title and task.
        assertTrue(runtime.onBoard { edit(third, "Third v2", "New task") })
        runtime.workspace.state.await { it.card(third)?.let { card -> card.initial_prompt == "New task" && card.title == "Third v2" } == true }

        // Archive leaves every live view; the board archive lists it.
        assertTrue(runtime.onBoard { archive(first) })
        runtime.workspace.state.await { it.card(first) == null }
        val archived = runtime.onBoard { archivedCards(fixture.boardId) }.single { it.id == first }
        assertTrue(runtime.onBoard { restore(archived) })
        runtime.workspace.state.await { it.card(first) != null }
        assertTrue(runtime.board.view.value.operations.isEmpty())
    }

    @Test
    fun aRejectedMoveRollsBackAndReportsTheError() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val (card) = cards(runtime, fixture, "Stays")
        runtime.awaitSynced(card)
        assertFailsWith<Exception> { runtime.onBoard { move(card, "no-such-lane") } }
        assertEquals("todo", runtime.workspace.state.value.card(card)?.lane)
        assertNotNull(runtime.board.view.value.errors[card])
        assertFalse(CardOperation.MOVING in runtime.board.view.value.operations.values)
    }

    @Test
    fun startingACardRunsItsFirstTurnOnTheOwner() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val local = runtime.createConversation(
            CreateConversationRequest(
                project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "Go", prompt = "Say hi",
                provider = "mock", model = "mock", effort = "low", defer_start = true, workspace_mode = "project",
            ),
            chat = false,
        )
        val id = runtime.outbox.view.await { local.id in it.resolutions }.resolve(local.id)
        runtime.awaitSynced(id)
        runtime.startCard(id)
        assertTrue(id in runtime.outbox.view.value.startingCardIds, "the board shows a start in the outbox as starting")
        // The overlay shows it running at once; sync then confirms the admitted turn.
        assertEquals("running", runtime.workspace.state.value.card(id)?.lane)
        runtime.workspace.state.await(30.seconds, describe = { "started: ${runtime.workspace.state.value.card(id)}" }) {
            it.card(id)?.initial_prompt_sent_at?.isNotEmpty() == true
        }
        runtime.outbox.view.await { it.entries.isEmpty() }

        // A started card's edit form only renames it; its sent task cannot change.
        runtime.workspace.state.await(30.seconds, describe = { "idle: ${runtime.workspace.state.value.card(id)}" }) { view ->
            view.card(id)?.runtime?.let { it != "running" && it != "starting" } == true && runtime.board.view.value.operations.isEmpty()
        }
        assertTrue(runtime.onBoard { edit(id, "Go again", "Say hi") })
        runtime.workspace.state.await { it.card(id)?.title == "Go again" }
        val refused = assertFailsWith<CoreException> { runtime.onBoard { edit(id, "Go again", "Say something else") } }
        assertEquals(FailureKind.PERMANENT, refused.kind)
        assertEquals("Say hi", runtime.workspace.state.value.card(id)?.initial_prompt)
    }
}
