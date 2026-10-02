package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateTerminalRequest
import com.dbpprt.dieter.api.v1.TerminalRef
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.terminals.TerminalInputPumps
import com.dbpprt.dieter.core.terminals.TerminalKey
import com.dbpprt.dieter.core.terminals.TerminalOverview
import com.dbpprt.dieter.core.terminals.TerminalScope
import com.dbpprt.dieter.core.terminals.TerminalScopeKind
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

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
    fun aNewSurfaceSelectsTheTerminalLastSelectedForItsScope() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val scope = TerminalScope(fixture.daemonId, TerminalScopeKind.MACHINE)
        val first = runtime.terminals()
        runtime.onCore {
            first.bind(scope)
            first.load()
        }
        val older = runtime.onCore { first.create(name = "older", shell = "sh") }
        val newer = runtime.onCore { first.create(name = "newer", shell = "sh") }
        runtime.onCore { first.select(older.id) }

        val second = runtime.terminals()
        runtime.onCore {
            second.bind(scope)
            second.load()
        }
        assertEquals(older.id, second.view.value.selectedId, "the remembered terminal, not the first listed")
        runtime.onCore {
            second.close(older.id)
            second.close(newer.id)
        }
    }

    @Test
    fun inputIsBoundedAndAnUnconfirmedWriteIsNeverResent() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val pumps = runtime.terminalPumps
        val failures = MutableStateFlow<List<String>>(emptyList())
        val report: (String) -> Unit = { message -> failures.update { it + message } }

        // Input is admitted whole or not at all within the shared budget.
        runtime.onCore {
            assertFailsWith<CoreException> {
                pumps.send(TerminalKey(fixture.daemonId, "missing"), ByteArray(TerminalInputPumps.MAX_BUDGET_BYTES.toInt() + 1), report)
            }
        }
        // A write the machine rejects may still have been delivered: it is
        // reported once, and the input queued with it is dropped, not resent.
        runtime.onCore {
            pumps.send(TerminalKey(fixture.daemonId, "missing"), "first".encodeToByteArray(), report)
            pumps.send(TerminalKey(fixture.daemonId, "missing"), "second".encodeToByteArray(), report)
        }
        failures.await(20.seconds) { it.isNotEmpty() }
        delay(500)
        assertEquals(1, failures.value.size, "failures: ${failures.value}")
        assertTrue(failures.value.single().endsWith("Unconfirmed input was not resent."), failures.value.single())

        // At most eight terminals receive input at once.
        runtime.onCore {
            repeat(TerminalInputPumps.MAX_PUMPS) { pumps.send(TerminalKey(fixture.daemonId, "pump-$it"), byteArrayOf(1)) {} }
            assertFailsWith<CoreException> { pumps.send(TerminalKey(fixture.daemonId, "pump-extra"), byteArrayOf(1)) {} }
            pumps.cancelAll()
        }
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

    @Test
    fun anOverviewListsAMachineAgainOnceItIsBack() = e2e {
        val fixture = fixture(secondDaemon = true)
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.connection.machines.await(30.seconds, describe = { "both machines: ${runtime.connection.machines.value}" }) { directory ->
            directory.online.count { it.compatible } >= 2
        }
        val returning = runtime.onMachine(fixture.secondDaemonId) {
            it.CreateTerminal().execute(CreateTerminalRequest(name = "returning", shell = "sh", columns = 80, rows = 24, machine_home = true))
        }
        val everyMachine = runtime.connection.machines.value.online.filter { it.compatible }
        // The second machine is still restarting when the overview first lists.
        var online = everyMachine.filter { it.id != fixture.secondDaemonId }
        val overview = TerminalOverview(runtime.sessions, { online }, runtime.terminals())
        runtime.onCore { overview.load(preferredDaemonId = fixture.secondDaemonId) }
        assertTrue(overview.view.value.entries.none { it.daemonId == fixture.secondDaemonId })
        runtime.onCore { overview.relistIfStale() }
        assertTrue(overview.view.value.entries.none { it.daemonId == fixture.secondDaemonId }, "nothing changed, so nothing is listed again")

        online = everyMachine
        runtime.onCore { overview.relistIfStale() }
        val view = overview.view.value
        val id = "${fixture.secondDaemonId}|${returning.id}"
        assertTrue(view.entries.any { it.id == id }, "the returning machine's terminal is listed: ${view.entries.map { it.id }}")
        if (view.entries.size == 1) assertEquals(id, view.selectedId, "the preferred machine's terminal is selected once listed")
        runtime.onMachine(fixture.secondDaemonId) { it.CloseTerminal().execute(TerminalRef(terminal_id = returning.id)) }
    }
}
