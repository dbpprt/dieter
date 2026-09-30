package com.dbpprt.dieter.core

import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** ADMIN scenario: board and label lifecycle, prompts, telemetry, and a widget refresh. */
class AdminEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun boardsLabelsPromptsAndTelemetry() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val admin = runtime.admin

        val board = runtime.onCore { admin.createBoard(fixture.projectId, "Ops", workflow = "direct") }
        runtime.workspace.state.await(describe = { "new board" }) { it.board(board.id)?.name == "Ops" }
        runtime.onCore { admin.renameBoard(board.id, "Operations") }
        runtime.workspace.state.await { it.board(board.id)?.name == "Operations" }
        val policy = runtime.onCore { admin.setArchivePolicy(board.id, "after_7_days") }
        assertEquals("after_7_days", policy.done_archive_policy)

        val labelled = runtime.onCore { admin.createLabel(board.id, " urgent ", "#d95c68", "Handle first") }
        val label = labelled.labels.single { it.name == "urgent" }
        val updated = runtime.onCore { admin.updateLabel(board.id, label.id, "blocker", "#478dc5", "Handle first") }
        assertEquals("blocker", updated.labels.single().name)
        runtime.onCore { admin.deleteLabel(board.id, label.id) }

        // An empty board can be retired and restored with its lifecycle revision.
        val retired = runtime.onCore { admin.setBoardRetired(board.id, true) }
        assertTrue(retired.retired)
        runtime.workspace.state.await(describe = { "retired" }) { it.board(board.id) == null }
        val restored = runtime.onCore { admin.setBoardRetired(board.id, false) }
        assertTrue(!restored.retired)

        val updatedProject = runtime.onCore { admin.updateProject(fixture.projectId, summary = "The isolated test project", hostnames = listOf("Localhost:3000")) }
        assertEquals(listOf("localhost:3000"), updatedProject.hostnames)

        val prompts = runtime.onCore { admin.promptSettings(fixture.daemonId) }
        assertTrue(prompts.prompt_template.contains("{{project.instructions_block}}"))
        val preview = runtime.onCore { admin.previewPrompt(fixture.projectId, fixture.boardId) }
        assertTrue(preview.estimated_tokens > 0)

        runtime.onCore { runtime.telemetry.select(fixture.daemonId, active = true) }
        val telemetry = runtime.telemetry.view.await(20.seconds, describe = { "telemetry: ${runtime.telemetry.view.value.error}" }) { it.information != null }
        assertTrue(telemetry.information!!.hostname.isNotEmpty())
        runtime.telemetry.view.await(20.seconds) { it.cpuHistory.size >= 2 }
        runtime.onCore { runtime.telemetry.select(null, active = false) }
    }

    @Test
    fun aWidgetRefreshConnectsBrieflyWithoutStayingOnline() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, active = false)
        assertTrue(runtime.connection.refreshForWidget(30.seconds))
        runtime.connection.state.await(20.seconds, describe = { "released: ${runtime.connection.state.value}" }) { it.phase == com.dbpprt.dieter.core.connection.ConnectionPhase.DISCONNECTED }
    }
}
