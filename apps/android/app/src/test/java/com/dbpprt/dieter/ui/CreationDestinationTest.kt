package com.dbpprt.dieter.ui

import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.composition.CatalogState
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.machines.MachineRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The UI state feeds the core's destination rules the checkout, its machine, and the loaded catalog. */
class CreationDestinationTest {
    private fun checkout(id: String, daemon: String = id) = Checkout(id = id, project_id = "project", daemon_id = daemon, name = id)

    private fun state(vararg checkouts: Checkout) = DieterUiState(
        connectionPhase = ConnectionPhase.CONNECTED,
        selectedProjectId = "project",
        projects = listOf(Project(id = "project", checkouts = checkouts.toList())),
        endpointConnections = listOf("mac", "linux").map { MachineRow(id = it, daemonId = it, label = it, address = "") },
        harnessesEndpointId = "mac",
    )

    @Test fun singleCheckoutWorksWithoutAnExplicitMachineChoice() {
        val state = state(checkout("mac"))
        assertEquals("mac", state.creationCheckout?.id)
        assertEquals(CatalogState.LIVE, state.catalogState)
    }

    @Test fun multipleCheckoutsRequireAnExplicitDestinationEvenOnTheSameMachine() {
        val state = state(checkout("one", "mac"), checkout("two", "mac"))
        assertNull(state.creationCheckout)
        assertEquals(CatalogState.NONE, state.catalogState)
        assertEquals(CatalogState.LIVE, state.copy(creationCheckoutId = "two").catalogState)
    }

    @Test fun changingMachineCannotReusePreviousMachinesModels() {
        val state = state(checkout("mac"), checkout("linux")).copy(creationCheckoutId = "linux")
        assertEquals(CatalogState.NONE, state.catalogState)
        assertEquals(CatalogState.LIVE, state.copy(harnessesEndpointId = "linux").catalogState)
    }

    @Test fun offlineDestinationsQueueTasksAgainstTheCachedCatalog() {
        val state = state(checkout("mac"))
        val offline = state.copy(connectionPhase = ConnectionPhase.NO_MACHINE)
        assertEquals(CatalogState.CACHED, offline.catalogState)
        assertEquals(offline.harnesses, offline.creationCatalog(chat = false))
        assertNull(offline.creationCatalog(chat = true))
        assertNull(state(checkout("mac").copy(detached = true)).creationCheckout)
        assertEquals("mac", state.creationMachine?.id)
    }

    @Test fun staleSelectionDoesNotPickAnArbitraryMachine() {
        val state = state(checkout("mac"), checkout("linux")).copy(creationCheckoutId = "removed")
        assertNull(state.creationCheckout)
        assertEquals(CatalogState.NONE, state.catalogState)
    }

    @Test fun projectLocationUsesCheckoutOwnersInsteadOfTheSyncReplica() {
        val state = state(checkout("office"), checkout("laptop")).copy(
            endpointConnections = listOf(
                MachineRow("home", "mini-home", "", daemonId = "home"),
                MachineRow("office", "mini-office", "", daemonId = "office"),
                MachineRow("laptop", "mbp-office", "", daemonId = "laptop", online = false),
            ),
            projectReplicas = mapOf("project" to ProjectReplica("home", "home", "mini-home", true)),
        )
        val project = state.project!!
        assertEquals("mini-office · mbp-office (offline)", state.projectCheckoutLabel(project))
        assertEquals(
            state.projectCheckoutLabel(project),
            state.copy(projectReplicas = mapOf("project" to ProjectReplica("office", "office", "mini-office", true))).projectCheckoutLabel(project),
        )
    }

    @Test fun projectLocationRetainsUnknownAndDisconnectedOwners() {
        val state = state(checkout("unknown"), checkout("mac"))
        assertEquals("mac · unknown (unavailable)", state.projectCheckoutLabel(state.project!!))
        assertEquals("mac (offline) · unknown (unavailable)", state.copy(connectionPhase = ConnectionPhase.NO_MACHINE).projectCheckoutLabel(state.project!!))
        assertEquals("unknown", state.machineLabel("unknown"))
        assertEquals("mac", state.machineLabel("mac"))
    }
}
