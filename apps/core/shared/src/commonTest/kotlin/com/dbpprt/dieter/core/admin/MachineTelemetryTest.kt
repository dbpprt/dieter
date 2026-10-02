package com.dbpprt.dieter.core.admin

import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.api.v1.MachineOperationCapability
import com.dbpprt.dieter.api.v1.MachineOperationResponse
import com.dbpprt.dieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

class MachineTelemetryTest {
    private val telemetry = MachineTelemetry(offlineSessions(), CoroutineScope(Dispatchers.Unconfined))

    @Test
    fun theLeastRecentlyReadMachinesGoButNeverTheShownOne() {
        telemetry.select("shown", active = false)
        telemetry.unavailable("shown", "offline")
        repeat(70) { telemetry.unavailable("m$it", "offline") }
        val machines = telemetry.view.value.machines
        assertEquals(64, machines.size)
        assertTrue("shown" in machines, "the shown machine stays")
        assertTrue("m6" !in machines && "m7" in machines && "m69" in machines, "the oldest reads go: ${machines.keys}")
        // Reading a machine again makes it the most recent: m7, m8, m9, and m11 go before it.
        telemetry.unavailable("m10", "still offline")
        repeat(4) { telemetry.unavailable("new$it", "offline") }
        assertTrue("m10" in telemetry.view.value.machines && "m11" !in telemetry.view.value.machines, "${telemetry.view.value.machines.keys}")
    }

    @Test
    fun anAccountChangeForgetsEveryMachine() {
        telemetry.select("a", active = false)
        telemetry.unavailable("a", "offline")
        telemetry.reset()
        assertEquals(TelemetryView(), telemetry.view.value)
    }

    @Test
    fun theActionsMenuOffersOnlyReportedCapabilitiesInMenuOrder() {
        assertEquals(emptyList(), MachineOperations.availability(null))
        // The restart and shutdown flags never count.
        val info = MachineInformation(
            supports_restart = true, supports_shutdown = true,
            operation_capabilities = listOf(
                MachineOperationCapability(action = MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON, supported = true, authorized = true),
                MachineOperationCapability(action = MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART, supported = true, authorized = false, unavailable_reason = "interactive PolicyKit authorization is required"),
            ),
        )
        assertEquals(
            listOf(
                OperationAvailability(MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON, available = true, unavailableReason = ""),
                OperationAvailability(MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART, available = false, unavailableReason = "interactive PolicyKit authorization is required"),
                OperationAvailability(MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN, available = false, unavailableReason = ""),
            ),
            MachineOperations.availability(info),
        )
    }

    @Test
    fun operationsReadTheSameInTheMenuAndTheConfirmation() {
        val restart = MachineOperations.copy(MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART)
        assertEquals(OperationCopy("Restart machine", "Restart", "Restart…", "Active Dieter turns will be suspended while the machine restarts. It will reconnect after Dieter starts again.", destructive = true), restart)
        val shutdown = MachineOperations.copy(MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN)
        assertEquals("Shut down machine", shutdown.title)
        assertEquals("Shut Down", shutdown.button)
        assertEquals("Shut Down…", shutdown.menuTitle)
        assertTrue(shutdown.destructive)
        val update = MachineOperations.copy(MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON)
        assertEquals("Update Dieter daemon", update.title)
        assertEquals("Update Dieter…", update.menuTitle)
        assertTrue(update.explanation.endsWith("Active turns will be suspended during the restart."))
        assertFalse(update.destructive)
        assertEquals("", MachineOperations.copy(MachineOperationAction.MACHINE_OPERATION_ACTION_UNSPECIFIED).title)
    }

    @Test
    fun operationResultsShowTheDaemonsMessageElseTheAcceptance() {
        assertEquals("Restart scheduled in 1 minute.", MachineOperations.resultMessage(MachineOperationResponse(message = "Restart scheduled in 1 minute.")))
        assertEquals("Machine operation accepted.", MachineOperations.resultMessage(MachineOperationResponse(message = " ")))
        assertEquals("Machine operation accepted.", MachineOperations.resultMessage(null))
    }
}
