package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.api.v1.StartExecutionRequest
import com.dbpprt.dieter.core.executions.ProcessTarget
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** SCHED, processes, and QUOTA scenarios against a real daemon and gateway. */
class DomainsEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun schedulesAreCreatedPreviewedToggledRunAndDeletedOnTheirOwner() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        runtime.onCore { runtime.schedules.bind(fixture.projectId) }
        runtime.onCore { runtime.schedules.load() }
        assertTrue(runtime.schedules.view.value.loaded)

        runtime.onCore { runtime.schedules.preview("0 9 * * 1-5", "Europe/Berlin") }
        runtime.schedules.view.await(describe = { "preview: ${runtime.schedules.view.value}" }) { it.preview.size == 5 }

        val draft = ScheduleDraft(
            board_id = fixture.boardId, name = "Nightly", cron = "0 9 * * 1-5", timezone = "UTC", enabled = true, action = "draft",
            title_template = "Nightly · {{date}}", prompt_template = "Summarize {{project}}", provider = "mock", model = "mock", effort = "low",
            open_card_policy = "skip_if_open", workspace_mode = "project",
        )
        val saved = runtime.onCore { runtime.schedules.save(draft) }
        assertEquals(fixture.daemonId, saved.owner_daemon_id.ifEmpty { fixture.daemonId })
        assertEquals(listOf("Nightly"), runtime.schedules.view.value.schedules.map { it.name })
        assertEquals(saved.id, runtime.schedules.view.value.selectedId)

        val paused = runtime.onCore { runtime.schedules.setEnabled(saved.id, false) }
        assertFalse(paused.enabled)
        runtime.onCore { runtime.schedules.runNow(saved.id) }
        runtime.schedules.view.await(30.seconds, describe = { "runs: ${runtime.schedules.view.value.runs}" }) { it.runs.any { run -> run.manual } }
        val full = runtime.onCore { runtime.schedules.details(saved.id) }
        assertEquals("Summarize {{project}}", full.prompt_template)

        runtime.onCore { runtime.schedules.delete(saved.id) }
        assertTrue(runtime.schedules.view.value.schedules.isEmpty())
        assertEquals(null, runtime.schedules.view.value.selectedId)
    }

    @Test
    fun aConversationsBackgroundProcessStreamsItsOutputAndStops() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val local = runtime.createConversation(
            CreateConversationRequest(project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "Server", prompt = "x", defer_start = true, workspace_mode = "project"),
            chat = false,
        )
        val cardId = runtime.outbox.view.await { local.id in it.resolutions }.resolve(local.id)
        val started = runtime.onMachine(fixture.daemonId) {
            it.StartExecution().execute(StartExecutionRequest(project_id = fixture.projectId, card_id = cardId, name = "dev server", argv = listOf("/bin/sh", "-c", "echo ready; echo warn 1>&2; sleep 30")))
        }
        runtime.onCore { runtime.processes.bind(ProcessTarget(fixture.daemonId, fixture.projectId, cardId), active = true) }
        val view = runtime.processes.view.await(20.seconds, describe = { "output: ${runtime.processes.view.value}" }) {
            it.stdout.utf8().contains("ready") && it.stderr.utf8().contains("warn")
        }
        assertEquals(started.id, view.selectedId)
        assertEquals(1, view.running)
        runtime.onCore { runtime.processes.stopSelected() }
        runtime.processes.view.await(20.seconds, describe = { "stopped: ${runtime.processes.view.value}" }) { it.running == 0 }
        runtime.onCore { runtime.processes.bind(null, active = false) }
    }

    @Test
    fun quotasAreWatchedFromTheGateway() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.quotas.view.await(20.seconds, describe = { "watching: ${runtime.quotas.view.value}" }) { it.live && it.error == null }
        runtime.onCore { runtime.quotas.load(refresh = true) }
        assertEquals(null, runtime.quotas.view.value.error)
    }
}
