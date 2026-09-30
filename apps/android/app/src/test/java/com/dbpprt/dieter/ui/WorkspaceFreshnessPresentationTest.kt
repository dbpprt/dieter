package com.dbpprt.dieter.ui

import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.machines.MachineLink
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.outbox.MachineOutboxSummary
import com.dbpprt.dieter.api.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The UI state applies the core's presence rules to its machines and project hosts. */
class WorkspaceFreshnessPresentationTest {
    @Test
    fun cachedMachinePresenceIsNotPresentedAsLiveDuringReconnect() {
        val project = Project(id = "project-one")
        val state = DieterUiState(
            connectionPhase = ConnectionPhase.RECONNECTING,
            projects = listOf(project),
            projectReplicas = mapOf(
                project.id to ProjectReplica("machine-one", "daemon-one", "Studio Mac", online = true),
            ),
            endpointConnections = listOf(
                MachineRow(
                    id = "machine-one",
                    label = "Studio Mac",
                    address = "https://example.test",
                    phase = MachineLink.CONNECTED,
                    detail = "Gateway · 12 ms",
                    latencyMs = 12,
                    online = true,
                    daemonId = "daemon-one",
                ),
            ),
        )

        assertFalse(state.presentedProjectReplicas.getValue(project.id).online)
        assertFalse(state.presentedEndpointConnections.single().online)
        assertEquals(MachineLink.PENDING, state.presentedEndpointConnections.single().phase)
        assertFalse(state.projectSurfacesEnabled)

        val live = state.copy(connectionPhase = ConnectionPhase.CONNECTED)
        assertTrue(live.presentedProjectReplicas.getValue(project.id).online)
        assertEquals(MachineLink.CONNECTED, live.presentedEndpointConnections.single().phase)
        assertTrue(live.projectSurfacesEnabled)
    }

    @Test
    fun queuedMachineRemainsVisibleWhenGatewayDiscoveryIsUnavailable() {
        val state = DieterUiState(
            connectionPhase = ConnectionPhase.RECONNECTING,
            endpointConnections = listOf(MachineRow("gateway", "Gateway", "https://example.test")),
            projectReplicas = mapOf(
                "project-one" to ProjectReplica("gateway#machine-one", "machine-one", "Studio Mac", online = false),
            ),
            machineOutboxSummaries = mapOf(
                "gateway#machine-one" to MachineOutboxSummary(1, 0, retrying = false, failed = false),
            ),
        )

        val machine = state.presentedEndpointConnections.single { it.id == "gateway#machine-one" }
        assertEquals("Studio Mac", machine.label)
        assertFalse(machine.online)
        assertEquals(MachineLink.PENDING, machine.phase)
    }
}
