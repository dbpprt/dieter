package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import com.dbpprt.dieter.core.admin.MachineOperations
import com.dbpprt.dieter.core.admin.MachineSnapshot
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.api.v1.BuildInformation
import com.dbpprt.dieter.api.v1.GPUDevice
import com.dbpprt.dieter.api.v1.GPUMemoryKind
import com.dbpprt.dieter.api.v1.GPUTelemetry
import com.dbpprt.dieter.api.v1.GPUTelemetryState
import com.dbpprt.dieter.api.v1.GPUVendor
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.api.v1.MachineOperationCapability
import com.dbpprt.dieter.api.v1.MachineProcess
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class MachinesScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun expandedFleetUsesSharedResizablePane() {
        val machine = fixtureMachine()
        compose.setContent {
            DieterTheme {
                MachinesContent(
                    state = DieterUiState(
                        connectionPhase = ConnectionPhase.CONNECTED,
                        endpointConnections = listOf(machine),
                        selectedMachineId = machine.id,
                        machineSnapshots = mapOf(machine.id to MachineSnapshot(information = fixtureInformation())),
                    ),
                    expanded = true,
                    contentPadding = PaddingValues(),
                    onSelect = {},
                    onClose = {},
                    onRefreshMachines = {},
                    onRefreshSelected = {},
                    onOperation = {},
                    onOpenTerminals = {},
                    onDismissOperationMessage = {},
                )
            }
        }

        compose.onNodeWithTag("machines-pane-divider")
            .assertIsDisplayed()
            .assertContentDescriptionEquals("Resize list and detail panes")
        compose.onNodeWithTag("machines-list").assertIsDisplayed()
        compose.onNodeWithTag("machine-detail").assertIsDisplayed()
    }

    @Test fun fleetOpensTelemetryAndConfirmsOnlyAdvertisedActions() {
        val machine = fixtureMachine()
        val information = fixtureInformation()
        var operation: Pair<MachineOperationAction, String>? = null
        var terminalMachine: String? = null
        compose.setContent {
            var state by remember {
                mutableStateOf(
                    DieterUiState(
                        connectionPhase = ConnectionPhase.CONNECTED,
                        endpointConnections = listOf(machine),
                        machineSnapshots = mapOf(machine.id to MachineSnapshot(information = information)),
                    ),
                )
            }
            DieterTheme {
                MachinesContent(
                    state = state,
                    expanded = false,
                    contentPadding = PaddingValues(),
                    onSelect = { state = state.copy(selectedMachineId = it) },
                    onClose = { state = state.copy(selectedMachineId = null) },
                    onRefreshMachines = {},
                    onRefreshSelected = {},
                    onOperation = { action -> operation = action to MachineOperations.confirmation(action) },
                    onOpenTerminals = { terminalMachine = it },
                    onDismissOperationMessage = {},
                )
            }
        }

        compose.onNodeWithTag("machines-list").assertIsDisplayed()
        compose.onNodeWithTag("machines-summary").assertIsDisplayed()
        compose.onNodeWithText("Fixture workstation").performClick()
        compose.onNodeWithTag("machine-detail").assertIsDisplayed()
        compose.onNodeWithTag("machine-cpu").assertIsDisplayed()
        compose.onNodeWithTag("machine-memory").assertIsDisplayed()
        compose.onNodeWithTag("machine-actions").assertIsEnabled().performClick()
        compose.onNodeWithTag("machine-action-restart").assertIsNotEnabled()
        compose.onNodeWithTag("machine-action-shutdown").assertIsNotEnabled()
        compose.onNodeWithTag("machine-action-update").assertIsEnabled().performClick()
        compose.onNodeWithText("Update Dieter daemon").assertIsDisplayed()
        compose.onNodeWithTag("machine-operation-confirm").performClick()
        compose.runOnIdle {
            assertEquals(MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON to "UPDATE", operation)
        }
        compose.onNodeWithTag("machine-detail").performScrollToNode(hasTestTag("machine-open-terminals"))
        compose.onNodeWithTag("machine-open-terminals").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(machine.id, terminalMachine) }
    }

    private fun fixtureMachine() = MachineRow(
        id = "gateway#fixture",
        label = "Fixture workstation",
        address = "https://gateway.example",
        detail = "Gateway relay · 12 ms",
        latencyMs = 12,
        online = true,
        daemonId = "fixture",
        compatibility = CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE,
    )

    private fun fixtureInformation(): MachineInformation = MachineInformation(hostname = "fixture", os_name = "Linux", os_version = "6.10", architecture = "arm64", hardware_model = "Test host", processor = "Fixture CPU", uptime_seconds = 7_200, cpu_usage_percent = 37.6, logical_cpu_count = 8, cpu_core_usage_percent = listOf(11.0, 27.0, 39.0, 74.0).toList(), load_1 = 0.4, load_5 = 0.6, load_15 = 0.7, memory_total_bytes = 16L * 1_073_741_824L, memory_used_bytes = 5L * 1_073_741_824L, memory_cached_bytes = 3L * 1_073_741_824L, disk_free_bytes = 120L * 1_073_741_824L, network_receive_bytes_per_second = 1_250_000.0, network_send_bytes_per_second = 420_000.0, temperature_celsius = 44.0, active_agent_count = 1, daemon_build = BuildInformation(release_version = "v1.2.3", source_revision = "0123456789abcdef"), gpu = GPUTelemetry(state = GPUTelemetryState.GPU_TELEMETRY_STATE_AVAILABLE, devices = listOf(GPUDevice(id = "gpu-0", vendor = GPUVendor.GPU_VENDOR_AMD, name = "Fixture GPU", memory_kind = GPUMemoryKind.GPU_MEMORY_KIND_DEDICATED, utilization_percent = 21.0, memory_used_bytes = 512L * 1_048_576L, memory_total_bytes = 4L * 1_073_741_824L),)), processes = listOf(MachineProcess(pid = 42, kind = "daemon", name = "Dieter daemon", detail = "machine data plane", cpu_usage_percent = 2.0, memory_bytes = 128L * 1_048_576L),), operation_capabilities = listOf(MachineOperationCapability(action = MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON, supported = true, authorized = true),))
}
