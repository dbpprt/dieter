package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.BuildInformation
import com.dbpprt.dieter.v1.GPUDevice
import com.dbpprt.dieter.v1.GPUMemoryKind
import com.dbpprt.dieter.v1.GPUTelemetry
import com.dbpprt.dieter.v1.GPUTelemetryState
import com.dbpprt.dieter.v1.GPUVendor
import com.dbpprt.dieter.v1.MachineInformation
import com.dbpprt.dieter.v1.MachineOperationAction
import com.dbpprt.dieter.v1.MachineOperationCapability
import com.dbpprt.dieter.v1.MachineProcess
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class MachinesScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun fleetOpensTelemetryAndConfirmsOnlyAdvertisedActions() {
        val machine = EndpointConnection(
            id = "gateway#fixture",
            label = "Fixture workstation",
            address = "https://gateway.example",
            detail = "Gateway relay · 12 ms",
            latencyMs = 12,
            online = true,
            daemonId = "fixture",
            apiVersion = "1",
        )
        val information = fixtureInformation()
        var operation: Pair<MachineOperationAction, String>? = null
        var terminalMachine: String? = null
        compose.setContent {
            var state by remember {
                mutableStateOf(
                    DieterUiState(
                        connectionPhase = ConnectionPhase.CONNECTED,
                        endpointConnections = listOf(machine),
                        machineInformation = mapOf(machine.id to information),
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
                    onOperation = { action, confirmation -> operation = action to confirmation },
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
        compose.onNodeWithTag("machine-operation-confirm").performClick()
        compose.runOnIdle {
            assertEquals(MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON to "UPDATE", operation)
        }
        compose.onNodeWithTag("machine-detail").performScrollToNode(hasTestTag("machine-open-terminals"))
        compose.onNodeWithTag("machine-open-terminals").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(machine.id, terminalMachine) }
    }

    private fun fixtureInformation(): MachineInformation = MachineInformation.newBuilder()
        .setHostname("fixture")
        .setOsName("Linux")
        .setOsVersion("6.10")
        .setArchitecture("arm64")
        .setHardwareModel("Test host")
        .setProcessor("Fixture CPU")
        .setUptimeSeconds(7_200)
        .setCpuUsagePercent(37.6)
        .setLogicalCpuCount(8)
        .addAllCpuCoreUsagePercent(listOf(11.0, 27.0, 39.0, 74.0))
        .setLoad1(0.4)
        .setLoad5(0.6)
        .setLoad15(0.7)
        .setMemoryTotalBytes(16L * 1_073_741_824L)
        .setMemoryUsedBytes(5L * 1_073_741_824L)
        .setMemoryCachedBytes(3L * 1_073_741_824L)
        .setDiskFreeBytes(120L * 1_073_741_824L)
        .setNetworkReceiveBytesPerSecond(1_250_000.0)
        .setNetworkSendBytesPerSecond(420_000.0)
        .setTemperatureCelsius(44.0)
        .setActiveAgentCount(1)
        .setDaemonBuild(
            BuildInformation.newBuilder()
                .setReleaseVersion("v1.2.3")
                .setApiVersion("1")
                .setSourceRevision("0123456789abcdef"),
        )
        .setGpu(
            GPUTelemetry.newBuilder()
                .setState(GPUTelemetryState.GPU_TELEMETRY_STATE_AVAILABLE)
                .addDevices(
                    GPUDevice.newBuilder()
                        .setId("gpu-0")
                        .setVendor(GPUVendor.GPU_VENDOR_AMD)
                        .setName("Fixture GPU")
                        .setMemoryKind(GPUMemoryKind.GPU_MEMORY_KIND_DEDICATED)
                        .setUtilizationPercent(21.0)
                        .setMemoryUsedBytes(512L * 1_048_576L)
                        .setMemoryTotalBytes(4L * 1_073_741_824L),
                ),
        )
        .addProcesses(
            MachineProcess.newBuilder()
                .setPid(42)
                .setKind("daemon")
                .setName("Dieter daemon")
                .setDetail("machine data plane")
                .setCpuUsagePercent(2.0)
                .setMemoryBytes(128L * 1_048_576L),
        )
        .addOperationCapabilities(
            MachineOperationCapability.newBuilder()
                .setAction(MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON)
                .setSupported(true)
                .setAuthorized(true),
        )
        .build()
}
