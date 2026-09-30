package com.dbpprt.dieter.core

import com.dbpprt.dieter.core.terminals.TerminalScope
import com.dbpprt.dieter.core.terminals.TerminalScopeKind
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** TERM scenarios: a real shell on the disposable daemon's machine home and project checkout. */
class TerminalEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun aShellRunsInputAndResumesAfterItsSurfaceReturns() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val checkout = runtime.workspace.state.value.project(fixture.projectId)!!.checkouts.first()
        val terminals = runtime.terminals()
        runtime.onCore {
            terminals.bind(TerminalScope(fixture.daemonId, TerminalScopeKind.PROJECT, fixture.projectId, checkout.id))
            terminals.setActive(true)
            terminals.load()
        }
        val created = runtime.onCore { terminals.create(name = "e2e", shell = "sh", columns = 100, rows = 30) }
        assertEquals("running", created.status)
        runtime.onCore { terminals.input("echo core-$((6*7))\n".encodeToByteArray()) }
        terminals.view.await(20.seconds, describe = { "output: ${terminals.view.value.copy(screens = emptyMap())} screen=${terminals.view.value.screens.mapValues { it.value.size }}" }) {
            it.screen(created.id).accessibilityText().contains("core-42")
        }

        // Hiding the surface stops the stream, not the shell; returning resumes from the cursor.
        runtime.onCore { terminals.setActive(false) }
        runtime.onCore { terminals.setActive(true) }
        runtime.onCore { terminals.input("echo second-$((1+1))\n".encodeToByteArray()) }
        terminals.view.await(20.seconds) { it.screen(created.id).accessibilityText().contains("second-2") }
        assertEquals(1, terminals.view.value.screen(created.id).accessibilityText().split("core-42").size - 1, "resuming never replays delivered output twice")

        runtime.onCore { terminals.gridChanged(90, 25) }
        terminals.view.await(10.seconds, describe = { "resized: ${terminals.view.value.selected}" }) { it.selected?.columns == 90 && it.selected?.rows == 25 }
        runtime.onCore { terminals.rename(created.id, "  renamed  ") }
        assertEquals("renamed", terminals.view.value.selected?.name)

        // A second surface on the machine home lists every terminal on the daemon.
        val home = runtime.terminals()
        runtime.onCore {
            home.bind(TerminalScope(fixture.daemonId, TerminalScopeKind.MACHINE))
            home.load()
        }
        assertTrue(home.view.value.terminals.any { it.id == created.id })

        runtime.onCore { terminals.close(created.id) }
        assertTrue(terminals.view.value.terminals.none { it.id == created.id })
        assertEquals(null, terminals.view.value.selectedId)
    }

    @Test
    fun theOverviewListsEveryMachinesTerminalsAndSwitchesBetweenThem() = e2e {
        val fixture = fixture(secondDaemon = true)
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.connection.machines.await(30.seconds, describe = { "both machines: ${runtime.connection.machines.value}" }) { directory ->
            directory.online.count { it.compatible } >= 2
        }
        val overview = runtime.terminalOverview()
        val first = runtime.onCore { overview.create(fixture.daemonId, name = "first", shell = "sh") }
        val second = runtime.onCore { overview.create(fixture.secondDaemonId, name = "second", shell = "sh") }
        assertEquals(second.id, overview.view.value.selectedId, "a created terminal is selected")
        assertEquals(fixture.secondDaemonId, overview.terminals.view.value.scope?.daemonId)

        runtime.onCore { overview.load(preferredDaemonId = fixture.daemonId) }
        val view = overview.view.value
        assertTrue(view.entries.map { it.id }.containsAll(listOf(first.id, second.id)))
        assertTrue(view.entries.none { it.daemonId == fixture.incompatibleDaemonId }, "incompatible machines are not listed")
        assertEquals(second.id, view.selectedId, "reloading keeps the selection")
        assertEquals(emptyMap(), view.errors)

        runtime.onCore {
            overview.terminals.setActive(true)
            overview.select(first.id)
        }
        assertEquals(fixture.daemonId, overview.terminals.view.value.scope?.daemonId)
        assertEquals(first.terminal.id, overview.terminals.view.value.selectedId)
        runtime.onCore { overview.terminals.input("echo overview-$((5*5))\n".encodeToByteArray()) }
        overview.terminals.view.await(20.seconds) { it.screen(first.terminal.id).accessibilityText().contains("overview-25") }
        runtime.onCore {
            overview.terminals.close(first.terminal.id)
            runtime.onMachine(fixture.secondDaemonId) { it.CloseTerminal().execute(com.dbpprt.dieter.api.v1.TerminalRef(terminal_id = second.terminal.id)) }
        }
    }
}
