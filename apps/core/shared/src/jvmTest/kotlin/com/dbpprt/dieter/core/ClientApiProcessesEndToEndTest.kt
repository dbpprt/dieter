package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.StartExecutionRequest
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.ProcessesCommand
import com.dbpprt.dieter.client.v1.ProcessesSlice
import com.dbpprt.dieter.client.v1.ProcessesTarget
import com.dbpprt.dieter.client.v1.SearchCommand
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Step
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/** A conversation's background process streams and stops through a processes surface; tasks are searched in the core. */
class ClientApiProcessesEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun theMacWatchesAProcessAndSearchesTasksThroughTheCore() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)
        val local = runtime.createConversation(
            CreateConversationRequest(
                project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "Searchable server", prompt = "x",
                defer_start = true, workspace_mode = "project",
            ),
            chat = false,
        )
        val cardId = runtime.outbox.view.await { local.id in it.resolutions }.resolve(local.id)

        // Search ranks the title match from the workspace; transcripts are not searched.
        runtime.awaitSynced(cardId)
        val hits = api.dispatch(Command(search = SearchCommand(query = "searchable serv"))).search_results!!.hits
        assertEquals(cardId, hits.firstOrNull()?.card_id, "hits: $hits")

        val started = runtime.onMachine(fixture.daemonId) {
            it.StartExecution().execute(
                StartExecutionRequest(project_id = fixture.projectId, card_id = cardId, name = "dev server", argv = listOf("/bin/sh", "-c", "echo ready; echo warn 1>&2; sleep 30")),
            )
        }
        val processes = MutableStateFlow<ProcessesSlice?>(null)
        val watch = api.observe(Slice.SLICE_PROCESSES, "processes-test") { processes.value = Update.ADAPTER.decode(it.encode()).processes }
        fun command(action: ProcessesCommand) = Command(processes = action.copy(scope = "processes-test"))
        api.dispatch(command(ProcessesCommand(bind = ProcessesTarget(fixture.daemonId, fixture.projectId, cardId, active = true))))
        val shown = processes.await(20.seconds, describe = { "output: ${processes.value}" }) {
            it?.stdout?.utf8()?.contains("ready") == true && it.stderr.utf8().contains("warn")
        }!!
        assertEquals(started.id, shown.selected_id)
        assertEquals(1, shown.running)
        assertTrue(shown.can_stop)
        api.dispatch(command(ProcessesCommand(stop = Step())))
        processes.await(20.seconds, describe = { "stopped: ${processes.value?.processes}" }) { it?.running == 0 }
        watch.close()
    }
}
