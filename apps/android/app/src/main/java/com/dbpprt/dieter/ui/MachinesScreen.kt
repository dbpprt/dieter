package com.dbpprt.dieter.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.SystemUpdateAlt
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.Thermostat
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.GPUDevice
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.api.v1.MachineProcess
import com.dbpprt.dieter.core.admin.MachineOperations
import com.dbpprt.dieter.core.machines.FleetTotals
import com.dbpprt.dieter.core.machines.MachineFormats
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterCoral
import com.dbpprt.dieter.ui.theme.DieterDivider
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterEyesTint
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterText
import kotlin.time.Clock
import kotlin.time.Instant

/**
 * [machine]'s status line as the core words it, followed by when it was last
 * seen when the core asks for that. The core judges the machine's own row,
 * not the presented one.
 */
internal fun DieterUiState.machineStatusLine(machine: MachineRow, now: Instant): String {
    val own = endpointConnections.firstOrNull { it.id == machine.id } ?: machine
    return MachineRows.status(own, own.id == attachedMachineId, connectionPhase, connectionError, machineSyncWarnings[own.id].orEmpty(), feedLive)
        .line(own.lastSeenAt, now)
}

private val MachineOperationAction.icon: ImageVector
    get() = when (this) {
        MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART -> Icons.Outlined.RestartAlt
        MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN -> Icons.Outlined.PowerSettingsNew
        else -> Icons.Outlined.SystemUpdateAlt
    }

private val MachineOperationAction.tag: String
    get() = when (this) {
        MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART -> "restart"
        MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN -> "shutdown"
        else -> "update"
    }

@Composable
fun MachinesScreen(
    state: DieterUiState,
    model: DieterViewModel,
    expanded: Boolean,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    MachinesContent(
        state = state,
        expanded = expanded,
        contentPadding = contentPadding,
        onSelect = model::selectMachine,
        onClose = model::closeMachine,
        onRefreshMachines = model::refreshMachines,
        onRefreshSelected = model::refreshSelectedMachineInformation,
        onOperation = model::performMachineOperation,
        onOpenTerminals = model::openMachineTerminals,
        onDismissOperationMessage = model::dismissMachineOperationMessage,
        modifier = modifier,
    )
}

@Composable
internal fun MachinesContent(
    state: DieterUiState,
    expanded: Boolean,
    contentPadding: PaddingValues,
    onSelect: (String) -> Unit,
    onClose: () -> Unit,
    onRefreshMachines: () -> Unit,
    onRefreshSelected: () -> Unit,
    onOperation: (MachineOperationAction) -> Unit,
    onOpenTerminals: (String) -> Unit,
    onDismissOperationMessage: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val machines = remember(state.presentedEndpointConnections) { MachineRows.listed(state.presentedEndpointConnections) }
    val selected = machines.firstOrNull { it.id == state.selectedMachineId }

    BackHandler(!expanded && selected != null, onClose)
    Surface(
        color = MaterialTheme.colorScheme.background,
        contentColor = DieterText,
        modifier = modifier.fillMaxSize(),
    ) {
        if (expanded) {
            ResizableHorizontalSplitPane(
                dividerTag = "machines-pane-divider",
                modifier = Modifier.fillMaxSize(),
                minimumLeadingWidth = 300.dp,
                leading = { paneModifier ->
                    MachineList(
                        machines = machines,
                        state = state,
                        selectedId = selected?.id,
                        onSelect = onSelect,
                        onRefresh = onRefreshMachines,
                        contentPadding = contentPadding,
                        modifier = paneModifier,
                    )
                },
            ) { paneModifier ->
                if (selected == null) {
                    MachineSelectionPrompt(paneModifier.padding(contentPadding))
                } else {
                    MachineDetail(
                        machine = selected,
                        state = state,
                        expanded = true,
                        onBack = onClose,
                        onRefresh = onRefreshSelected,
                        onOperation = onOperation,
                        onOpenTerminals = { onOpenTerminals(selected.id) },
                        onDismissOperationMessage = onDismissOperationMessage,
                        contentPadding = contentPadding,
                        modifier = paneModifier,
                    )
                }
            }
        } else if (selected == null) {
            MachineList(
                machines = machines,
                state = state,
                selectedId = null,
                onSelect = onSelect,
                onRefresh = onRefreshMachines,
                contentPadding = contentPadding,
            )
        } else {
            MachineDetail(
                machine = selected,
                state = state,
                expanded = false,
                onBack = onClose,
                onRefresh = onRefreshSelected,
                onOperation = onOperation,
                onOpenTerminals = { onOpenTerminals(selected.id) },
                onDismissOperationMessage = onDismissOperationMessage,
                contentPadding = contentPadding,
            )
        }
    }
}

@Composable
private fun MachineList(
    machines: List<MachineRow>,
    state: DieterUiState,
    selectedId: String?,
    onSelect: (String) -> Unit,
    onRefresh: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val now = Clock.System.now()
    LazyColumn(
        modifier = modifier.fillMaxSize().testTag("machines-list"),
        contentPadding = PaddingValues(
            start = 14.dp,
            top = contentPadding.calculateTopPadding() + 10.dp,
            end = 14.dp,
            bottom = contentPadding.calculateBottomPadding() + 18.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item("header") {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Machines", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                        Text(
                            MachineFormats.count(machines.size, "machine"),
                            color = DieterMuted,
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                    MachineStatusLabel(
                        label = MachineRows.onlineLabel(machines),
                        description = MachineRows.onlineSummary(machines),
                        anyOnline = machines.any { it.online },
                    )
                    IconButton(onClick = onRefresh, modifier = Modifier.testTag("machines-refresh")) {
                        Icon(Icons.Outlined.Refresh, "Refresh machines")
                    }
                }
                Text(
                    "Fleet availability and live host telemetry",
                    color = DieterMuted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        if (machines.isEmpty()) {
            item("empty") {
                Surface(
                    color = DieterSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, DieterOutline),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.padding(28.dp),
                    ) {
                        Icon(Icons.Outlined.Computer, null, Modifier.size(30.dp), tint = DieterMuted)
                        Text("No enrolled machines", fontWeight = FontWeight.SemiBold)
                        Text(
                            "Connect to a gateway with an enrolled Dieter daemon.",
                            color = DieterMuted,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        } else {
            items(machines, key = MachineRow::id) { machine ->
                MachineListItem(
                    machine = machine,
                    status = state.machineStatusLine(machine, now),
                    information = state.machineSnapshots[machine.id]?.information,
                    selected = selectedId == machine.id,
                    onClick = { onSelect(machine.id) },
                )
            }
            item("fleet") {
                FleetSummary(MachineRows.fleet(machines) { state.machineSnapshots[it]?.information })
            }
        }
    }
}

@Composable
private fun MachineStatusLabel(label: String, description: String, anyOnline: Boolean) {
    val color = if (anyOnline) DieterEyes else DieterMuted
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.semantics { contentDescription = description },
    ) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(color))
        Text(label, color = color, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
    }
}

@Composable
private fun MachineListItem(
    machine: MachineRow,
    status: String,
    information: MachineInformation?,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val agents = information?.active_agent_count ?: 0
    Surface(
        onClick = onClick,
        color = if (selected) DieterShellTint else DieterSurface,
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, if (selected) DieterShell.copy(alpha = 0.45f) else DieterOutline),
        modifier = Modifier.fillMaxWidth().testTag("machine-row-${machine.id}")
            .semantics {
                contentDescription = "Machine ${machine.label}, ${if (machine.online) "online" else "offline"}, $status"
            },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(14.dp),
        ) {
            Box(contentAlignment = Alignment.BottomEnd) {
                Surface(
                    color = DieterSurfaceHigh,
                    shape = RoundedCornerShape(13.dp),
                    modifier = Modifier.size(46.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Outlined.Computer, null, Modifier.size(23.dp), tint = DieterShell)
                    }
                }
                Box(
                    Modifier.size(12.dp).clip(CircleShape)
                        .background(if (machine.online) DieterEyes else DieterMuted),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(machine.label, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(status, color = DieterMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (agents > 0) {
                Surface(color = DieterShellTint, shape = CircleShape) {
                    Text(
                        MachineFormats.count(agents, "agent"),
                        color = DieterShell,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 10.sp,
                        modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp),
                    )
                }
            }
            Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted)
        }
    }
}

@Composable
private fun FleetSummary(fleet: FleetTotals) {
    Surface(
        color = DieterSurface.copy(alpha = 0.68f),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, DieterOutline),
        modifier = Modifier.fillMaxWidth().testTag("machines-summary"),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("FLEET", color = DieterMuted, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.4.sp)
                Spacer(Modifier.weight(1f))
                Text(fleet.reportingLabel, color = DieterMuted, fontSize = 10.sp)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                FleetMetric(fleet.agents.toString(), "agents")
                FleetMetric(fleet.cores.toString(), "cores")
                FleetMetric(MachineFormats.bytes(fleet.memoryBytes), "memory")
                FleetMetric(fleet.gpus.toString(), "GPUs")
            }
        }
    }
}

@Composable
private fun FleetMetric(value: String, label: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(value, color = DieterShell, fontWeight = FontWeight.Bold, fontSize = 16.sp, fontFamily = FontFamily.Monospace)
        Text(label, color = DieterMuted, fontSize = 9.sp)
    }
}

@Composable
private fun MachineSelectionPrompt(modifier: Modifier = Modifier) {
    Column(
        modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Computer, null, Modifier.size(42.dp), tint = DieterMuted)
        Spacer(Modifier.height(12.dp))
        Text("Select a machine", fontWeight = FontWeight.SemiBold)
        Text("View live telemetry and available host actions.", color = DieterMuted, fontSize = 12.sp)
    }
}

@Composable
private fun MachineDetail(
    machine: MachineRow,
    state: DieterUiState,
    expanded: Boolean,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onOperation: (MachineOperationAction) -> Unit,
    onOpenTerminals: () -> Unit,
    onDismissOperationMessage: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val snapshot = state.machineSnapshots[machine.id]
    val information = snapshot?.information
    val loading = snapshot?.loading == true
    val error = snapshot?.error
    var actionsOpen by remember { mutableStateOf(false) }
    var pendingAction by remember { mutableStateOf<MachineOperationAction?>(null) }

    LazyColumn(
        modifier = modifier.fillMaxSize().testTag("machine-detail"),
        contentPadding = PaddingValues(
            start = if (expanded) 22.dp else 14.dp,
            top = contentPadding.calculateTopPadding() + 10.dp,
            end = if (expanded) 22.dp else 14.dp,
            bottom = contentPadding.calculateBottomPadding() + 22.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item("identity") {
            MachineIdentity(
                machine = machine,
                status = state.machineStatusLine(machine, Clock.System.now()),
                information = information,
                loading = loading,
                expanded = expanded,
                onBack = onBack,
                onRefresh = onRefresh,
                actionsOpen = actionsOpen,
                onActionsOpenChange = { actionsOpen = it },
                onAction = { pendingAction = it },
                operationInFlight = state.machineOperationInFlight,
            )
        }
        when {
            information != null -> {
                item("cpu-memory") {
                    if (expanded) {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            MachineCpuPanel(
                                information,
                                snapshot.cpuHistory,
                                Modifier.weight(1f),
                            )
                            MachineMemoryPanel(information, Modifier.weight(1f))
                        }
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            MachineCpuPanel(information, snapshot.cpuHistory)
                            MachineMemoryPanel(information)
                        }
                    }
                }
                information.gpu?.let { gpuTelemetry ->
                    item("gpu-title") { MachineSectionHeader("GPU", MachineFormats.count(gpuTelemetry.devices.size, "device")) }
                    if (gpuTelemetry.devices.isEmpty()) {
                        item("gpu-unavailable") {
                            MachinePanel {
                                Text(
                                    MachineFormats.gpuUnavailable(gpuTelemetry),
                                    color = DieterMuted,
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    } else {
                        items(gpuTelemetry.devices, key = GPUDevice::id) { gpu ->
                            MachineGpuPanel(gpu, snapshot.gpuHistory[gpu.id].orEmpty())
                        }
                    }
                }
                item("software") { MachineSoftwarePanel(machine, information) }
                item("processes") { MachineProcessesPanel(information) }
                item("footer") {
                    MachineFooter(machine, information, onOpenTerminals)
                }
            }
            loading -> item("loading") {
                MachineCenteredState {
                    CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                    Text("Reading machine information…", color = DieterMuted, fontSize = 12.sp)
                }
            }
            else -> item("unavailable") {
                MachineCenteredState {
                    Icon(Icons.Outlined.Computer, null, Modifier.size(30.dp), tint = if (machine.online) DieterAmber else DieterMuted)
                    Text(
                        MachineFormats.informationUnavailable(machine, error),
                        color = DieterMuted,
                        fontSize = 12.sp,
                    )
                    if (machine.unavailableMessage == null) {
                        Button(onClick = onRefresh) { Text("Try again") }
                    }
                }
            }
        }
    }

    pendingAction?.let { action ->
        val copy = MachineOperations.copy(action)
        AlertDialog(
            onDismissRequest = { pendingAction = null },
            title = { Text(copy.title) },
            text = { Text(copy.explanation) },
            dismissButton = { TextButton(onClick = { pendingAction = null }) { Text("Cancel") } },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingAction = null
                        onOperation(action)
                    },
                    modifier = Modifier.testTag("machine-operation-confirm"),
                ) { Text(copy.button, color = if (copy.destructive) DieterCoral else DieterShell) }
            },
        )
    }
    state.machineOperationMessage?.let { message ->
        AlertDialog(
            onDismissRequest = onDismissOperationMessage,
            title = { Text("Machine operation") },
            text = { Text(message) },
            confirmButton = {
                TextButton(
                    onClick = onDismissOperationMessage,
                    modifier = Modifier.testTag("machine-operation-result"),
                ) { Text("OK") }
            },
        )
    }
}

@Composable
private fun MachineIdentity(
    machine: MachineRow,
    status: String,
    information: MachineInformation?,
    loading: Boolean,
    expanded: Boolean,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    actionsOpen: Boolean,
    onActionsOpenChange: (Boolean) -> Unit,
    onAction: (MachineOperationAction) -> Unit,
    operationInFlight: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, if (expanded) "Clear machine selection" else "Back to machines")
            }
            Text("Machines", color = DieterMuted, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            IconButton(
                onClick = onRefresh,
                enabled = machine.online && !loading,
                modifier = Modifier.testTag("machine-refresh"),
            ) { Icon(Icons.Outlined.Refresh, "Refresh machine information") }
            Box {
                IconButton(
                    onClick = { onActionsOpenChange(true) },
                    enabled = machine.online && information != null && !operationInFlight,
                    modifier = Modifier.testTag("machine-actions"),
                ) { Icon(Icons.Outlined.MoreVert, "Machine actions") }
                DropdownMenu(actionsOpen, { onActionsOpenChange(false) }) {
                    MachineOperations.availability(information).forEach { option ->
                        DropdownMenuItem(
                            text = { Text(MachineOperations.copy(option.action).menuTitle) },
                            leadingIcon = { Icon(option.action.icon, null) },
                            enabled = option.available,
                            onClick = {
                                onActionsOpenChange(false)
                                onAction(option.action)
                            },
                            modifier = Modifier.testTag("machine-action-${option.action.tag}")
                        )
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(13.dp), verticalAlignment = Alignment.Top) {
            Surface(color = DieterShellTint, shape = RoundedCornerShape(15.dp), modifier = Modifier.size(56.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Computer, null, Modifier.size(28.dp), tint = DieterShell)
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        machine.label,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    OnlineBadge(machine.online)
                }
                Text(MachineFormats.subtitle(machine, information), color = DieterMuted, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                if (machine.online) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Icon(Icons.Outlined.Lan, null, Modifier.size(14.dp), tint = DieterMuted)
                        Text(status, color = DieterMuted, fontSize = 11.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun OnlineBadge(online: Boolean) {
    val color = if (online) DieterEyes else DieterMuted
    Surface(color = if (online) DieterEyesTint else DieterSurfaceHigh, shape = CircleShape) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
        ) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(color))
            Text(
                MachineRows.presence(online),
                color = color,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun MachineCpuPanel(information: MachineInformation, history: List<Double>, modifier: Modifier = Modifier) {
    MachinePanel(modifier.testTag("machine-cpu")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("CPU", color = DieterMuted, fontWeight = FontWeight.Bold, fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            Text(
                MachineFormats.percentage(information.cpu_usage_percent),
                color = DieterShell,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                fontSize = 23.sp,
            )
        }
        MachineUsageGraph(
            values = information.cpu_core_usage_percent.ifEmpty { history.ifEmpty { listOf(information.cpu_usage_percent) } },
            description = "CPU usage ${MachineFormats.percentage(information.cpu_usage_percent)}",
        )
        Text(
            MachineFormats.load(information),
            color = DieterMuted,
            fontFamily = FontFamily.Monospace,
            fontSize = 10.sp,
        )
    }
}

@Composable
private fun MachineMemoryPanel(information: MachineInformation, modifier: Modifier = Modifier) {
    MachinePanel(modifier.testTag("machine-memory")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("MEMORY", color = DieterMuted, fontWeight = FontWeight.Bold, fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            Text(
                MachineFormats.bytes(information.memory_used_bytes),
                color = DieterEyes,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                fontSize = 17.sp,
            )
            Text(
                " / ${MachineFormats.bytes(information.memory_total_bytes)}",
                color = DieterMuted,
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
            )
        }
        MachineMemoryBar(information)
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            MachineLegend("used", information.memory_used_bytes, DieterEyes)
            MachineLegend("cache", information.memory_cached_bytes, DieterShell)
            MachineLegend("swap", information.swap_used_bytes, DieterAmber)
        }
    }
}

@Composable
private fun MachineUsageGraph(values: List<Double>, description: String) {
    val barColor = DieterShell
    val track = DieterSurfaceHigh
    Canvas(
        Modifier.fillMaxWidth().height(46.dp).semantics { contentDescription = description },
    ) {
        val count = values.size.coerceAtLeast(1)
        val gap = 4.dp.toPx()
        val barWidth = ((size.width - gap * (count - 1)) / count).coerceAtLeast(3.dp.toPx())
        values.forEachIndexed { index, value ->
            val x = index * (barWidth + gap)
            drawLine(track, androidx.compose.ui.geometry.Offset(x, size.height), androidx.compose.ui.geometry.Offset(x + barWidth, size.height), strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
            val height = (size.height * (value.coerceIn(0.0, 100.0) / 100.0)).toFloat().coerceAtLeast(4.dp.toPx())
            drawRoundRect(
                color = barColor.copy(alpha = if (index == values.lastIndex) 1f else 0.52f),
                topLeft = androidx.compose.ui.geometry.Offset(x, size.height - height),
                size = androidx.compose.ui.geometry.Size(barWidth, height),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()),
            )
        }
    }
}

@Composable
private fun MachineMemoryBar(information: MachineInformation) {
    val total = information.memory_total_bytes.coerceAtLeast(1).toFloat()
    val used = (information.memory_used_bytes / total).coerceIn(0f, 1f)
    val cached = (information.memory_cached_bytes / total).coerceIn(0f, 1f - used)
    Row(
        Modifier.fillMaxWidth().height(10.dp).clip(CircleShape).background(DieterSurfaceHigh)
            .semantics {
                contentDescription = "Memory used ${MachineFormats.bytes(information.memory_used_bytes)} of ${MachineFormats.bytes(information.memory_total_bytes)}"
            },
    ) {
        if (used > 0f) Box(Modifier.weight(used).fillMaxHeight().background(DieterEyes))
        if (cached > 0f) Box(Modifier.weight(cached).fillMaxHeight().background(DieterShell.copy(alpha = 0.72f)))
        val remaining = (1f - used - cached).coerceAtLeast(0.001f)
        Spacer(Modifier.weight(remaining))
    }
}

@Composable
private fun MachineLegend(label: String, value: Long, color: Color) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(color))
            Text(label, color = DieterMuted, fontSize = 9.sp)
        }
        Text(MachineFormats.bytes(value), color = DieterText, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
    }
}

@Composable
private fun MachineGpuPanel(device: GPUDevice, history: List<Double>) {
    MachinePanel {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(MachineFormats.gpuName(device), fontWeight = FontWeight.Bold)
                Text(
                    MachineFormats.gpuDetail(device),
                    color = DieterMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                MachineFormats.gpuUtilization(device),
                color = if (device.utilization_percent != null) DieterShell else DieterMuted,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                fontSize = 22.sp,
            )
        }
        device.utilization_percent?.let { utilization ->
            MachineUsageGraph(history.ifEmpty { listOf(utilization) }, "GPU usage ${MachineFormats.percentage(utilization)}")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            if (device.memory_used_bytes != null || device.memory_total_bytes != null) {
                MachineIconMetric(Icons.Outlined.Memory, MachineFormats.gpuMemory(device))
            }
            device.temperature_celsius?.let { MachineIconMetric(Icons.Outlined.Thermostat, MachineFormats.temperature(it)) }
            device.power_watts?.let { MachineIconMetric(Icons.Outlined.Bolt, MachineFormats.power(it)) }
        }
    }
}

@Composable
private fun MachineSoftwarePanel(machine: MachineRow, information: MachineInformation) {
    Column(
        Modifier.fillMaxWidth().testTag("machine-software"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        MachineSectionHeader("SOFTWARE")
        Surface(
            color = DieterSurface,
            shape = RoundedCornerShape(14.dp),
            border = BorderStroke(1.dp, DieterOutline),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(11.dp),
                modifier = Modifier.padding(13.dp),
            ) {
                Icon(Icons.Outlined.Dns, null, Modifier.size(19.dp), tint = DieterMuted)
                Text("Dieter daemon", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                val build = information.daemon_build
                Text(
                    MachineFormats.daemonVersion(build?.release_version.orEmpty(), machine.releaseVersion, build?.source_revision.orEmpty()),
                    color = DieterMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                )
            }
        }
    }
}

@Composable
private fun MachineProcessesPanel(information: MachineInformation) {
    Column(
        Modifier.fillMaxWidth().testTag("machine-processes"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        MachineSectionHeader("DIETER PROCESSES", MachineFormats.activeAgents(information.active_agent_count))
        Surface(
            color = DieterSurface,
            shape = RoundedCornerShape(14.dp),
            border = BorderStroke(1.dp, DieterOutline),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                if (information.processes.size == 0) {
                    Text("No Dieter processes reported.", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.padding(14.dp))
                } else {
                    information.processes.forEachIndexed { index, process ->
                        MachineProcessRow(process)
                        if (index < information.processes.size - 1) HorizontalDivider(color = DieterDivider)
                    }
                }
            }
        }
    }
}

@Composable
private fun MachineProcessRow(process: MachineProcess) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.padding(horizontal = 13.dp, vertical = 11.dp),
    ) {
        Icon(
            if (MachineFormats.isAgentProcess(process.kind)) Icons.Outlined.Refresh else Icons.Outlined.Terminal,
            null,
            Modifier.size(18.dp),
            tint = if (MachineFormats.isAgentProcess(process.kind)) DieterShell else DieterMuted,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(process.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                MachineFormats.processDetail(process.pid, process.detail),
                color = DieterMuted,
                fontFamily = FontFamily.Monospace,
                fontSize = 9.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(MachineFormats.percentage(process.cpu_usage_percent), color = DieterMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
        Text(MachineFormats.bytes(process.memory_bytes), color = DieterEyes, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
    }
}

@Composable
private fun MachineFooter(machine: MachineRow, information: MachineInformation, onOpenTerminals: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            MachineIconMetric(Icons.Outlined.Storage, MachineFormats.disk(information.disk_free_bytes))
            MachineIconMetric(Icons.Outlined.Lan, MachineFormats.network(information.network_receive_bytes_per_second, information.network_send_bytes_per_second))
            if (information.temperature_celsius > 0) {
                MachineIconMetric(Icons.Outlined.Thermostat, MachineFormats.temperature(information.temperature_celsius))
            }
        }
        Button(
            onClick = onOpenTerminals,
            enabled = machine.online,
            modifier = Modifier.fillMaxWidth().testTag("machine-open-terminals"),
        ) {
            Icon(Icons.Outlined.Terminal, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Open terminals")
        }
    }
}

@Composable
private fun MachineIconMetric(icon: ImageVector, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Icon(icon, null, Modifier.size(14.dp), tint = DieterMuted)
        Text(value, color = DieterMuted, fontFamily = FontFamily.Monospace, fontSize = 9.sp)
    }
}

@Composable
private fun MachineSectionHeader(title: String, trailing: String? = null) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = DieterMuted, fontWeight = FontWeight.Bold, fontSize = 10.sp, letterSpacing = 1.2.sp)
        Spacer(Modifier.weight(1f))
        trailing?.let { Text(it, color = DieterMuted, fontSize = 10.sp, fontFamily = FontFamily.Monospace) }
    }
}

@Composable
private fun MachinePanel(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        color = DieterSurface,
        shape = RoundedCornerShape(15.dp),
        border = BorderStroke(1.dp, DieterOutline),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(11.dp),
            modifier = Modifier.padding(15.dp),
            content = content,
        )
    }
}

@Composable
private fun MachineCenteredState(content: @Composable ColumnScope.() -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 70.dp),
        content = content,
    )
}

