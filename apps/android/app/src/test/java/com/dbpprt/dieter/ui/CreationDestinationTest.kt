package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.v1.Checkout
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.*
import org.junit.Test

class CreationDestinationTest {
    private fun checkout(id: String, daemon: String = id) = Checkout.newBuilder()
        .setId(id).setProjectId("project").setDaemonId(daemon).setName(id).build()

    private fun state(vararg checkouts: Checkout) = DieterUiState(
        connectionPhase = ConnectionPhase.CONNECTED,
        selectedProjectId = "project",
        projects = listOf(Project.newBuilder().setId("project").addAllCheckouts(checkouts.toList()).build()),
        endpointConnections = listOf("mac", "linux").map {
            EndpointConnection(id = "endpoint-$it", daemonId = it, label = it, address = "")
        },
        harnessesEndpointId = "endpoint-mac",
    )

    @Test fun singleCheckoutWorksWithoutAnExplicitMachineChoice() {
        val state = state(checkout("mac"))
        assertEquals("mac", state.creationCheckout?.id)
        assertTrue(state.creationCatalogReady)
    }

    @Test fun multipleCheckoutsRequireAnExplicitDestinationEvenOnTheSameMachine() {
        val state = state(checkout("one", "mac"), checkout("two", "mac"))
        assertNull(state.creationCheckout)
        assertFalse(state.creationCatalogReady)
        assertTrue(state.copy(creationCheckoutId = "two").creationCatalogReady)
    }

    @Test fun changingMachineCannotReusePreviousMachinesModels() {
        val state = state(checkout("mac"), checkout("linux")).copy(creationCheckoutId = "linux")
        assertFalse(state.creationCatalogReady)
        assertTrue(state.copy(harnessesEndpointId = "endpoint-linux").creationCatalogReady)
    }

    @Test fun offlineOrDetachedDestinationsCannotCreateTasks() {
        val state = state(checkout("mac"))
        assertFalse(state.copy(connectionPhase = ConnectionPhase.UNAVAILABLE).creationCatalogReady)
        assertFalse(state.copy(endpointConnections = emptyList()).creationCatalogReady)
        assertNull(state(checkout("mac").toBuilder().setDetached(true).build()).creationCheckout)
    }

    @Test fun staleSelectionDoesNotPickAnArbitraryMachine() {
        val state = state(checkout("mac"), checkout("linux")).copy(creationCheckoutId = "removed")
        assertNull(state.creationCheckout)
        assertFalse(state.creationCatalogReady)
    }
}
