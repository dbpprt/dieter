package com.dbpprt.dieter.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.data.DIETER_API_VERSION
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
import com.dbpprt.dieter.v1.GPUDevice
import com.dbpprt.dieter.v1.GPUMemoryKind
import com.dbpprt.dieter.v1.GPUVendor
import com.dbpprt.dieter.v1.MachineInformation
import com.dbpprt.dieter.v1.MachineOperationAction
import com.dbpprt.dieter.v1.MachineProcess
import java.util.Locale
import kotlin.math.roundToInt
import kotlin.math.roundToLong

internal object MachineInformationPresentation {
    fun bytes(value: Long): String {
        val safe = value.coerceAtLeast(0).toDouble()
        val units = listOf("B", "KB", "MB", "GB", "TB")
        var amount = safe
        var unit = 0
        while (amount >= 1024 && unit < units.lastIndex) {
            amount /= 1024
            unit++
        }
        val format = if (unit == 0 || amount >= 100) "%.0f %s" else "%.1f %s"
        return String.format(Locale.getDefault(), format, amount, units[unit])
    }

    fun rate(value: Double): String = if (value <= 0) "0 B/s" else "${bytes(value.roundToLong())}/s"

    fun uptime(seconds: Long): String {
        val safe = seconds.coerceAtLeast(0)
        val days = safe / 86_400
        val hours = (safe % 86_400) / 3_600
        val minutes = (safe % 3_600) / 60
        return when {
            days > 0 -> "${days}d ${hours}h"
            hours > 0 -> "${hours}h ${minutes}m"
            else -> "${minutes}m"
        }
    }

    fun percentage(value: Double): String = String.format(Locale.getDefault(), "%.0f%%", value)

    fun shortRevision(value: String): String? = value.takeIf { it.isNotBlank() && it != "unknown" }?.take(10)
}

internal fun machineOperationAvailable(
    information: MachineInformation?,
    action: MachineOperationAction,
): Boolean {
    information ?: return false
    information.operationCapabilitiesList.firstOrNull { it.action == action }?.let {
        return it.supported && it.authorized
    }
    return when (action) {
        MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART -> information.supportsRestart
        MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN -> information.supportsShutdown
        else -> false
    }
}

private enum class MachineAction(
    val wireValue: MachineOperationAction,
    val title: String,
    val button: String,
    val confirmation: String,
    val explanation: String,
) {
    UPDATE(
        MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON,
        "Update Dieter daemon?",
        "Update",
        "UPDATE",
        "The managed service will verify and install the latest Dieter release, restart, and reconnect automatically.",
    ),
    RESTART(
        MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART,
        "Restart machine?",
        "Restart",
        "RESTART",
        "Active Dieter turns will be suspended while the machine restarts. It will reconnect after Dieter starts again.",
    ),
    SHUTDOWN(
        MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN,
        "Shut down machine?",
        "Shut down",
        "SHUT DOWN",
        "Active Dieter turns will be suspended and the machine will remain offline until somebody turns it on again.",
    ),
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
    onOperation: (MachineOperationAction, String) -> Unit,
    onOpenTerminals: (String) -> Unit,
    onDismissOperationMessage: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val machines = remember(state.presentedEndpointConnections) {
        state.presentedEndpointConnections
            .filter { it.daemonId != null }
            .distinctBy(EndpointConnection::id)
            .sortedWith(compareBy<EndpointConnection> { !it.online }.thenBy { it.label.lowercase() })
    }
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
    machines: List<EndpointConnection>,
    state: DieterUiState,
    selectedId: String?,
    onSelect: (String) -> Unit,
    onRefresh: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val online = machines.count { it.online }
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
                            "${machines.size} ${if (machines.size == 1) "machine" else "machines"}",
                            color = DieterMuted,
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                    MachineStatusLabel(online = online, total = machines.size)
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
            items(machines, key = EndpointConnection::id) { machine ->
                MachineRow(
                    machine = machine,
                    information = state.machineInformation[machine.id],
                    selected = selectedId == machine.id,
                    onClick = { onSelect(machine.id) },
                )
            }
            item("fleet") {
                FleetSummary(machines, state.machineInformation)
            }
        }
    }
}

@Composable
private fun MachineStatusLabel(online: Int, total: Int) {
    val color = if (online > 0) DieterEyes else DieterMuted
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.semantics { contentDescription = "$online of $total machines online" },
    ) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(color))
        Text("$online online", color = color, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
    }
}

@Composable
private fun MachineRow(
    machine: EndpointConnection,
    information: MachineInformation?,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val status = if (machine.online) machine.detail.ifBlank { "Online" } else machine.detail.ifBlank { "Offline" }
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
            if (information?.activeAgentCount ?: 0 > 0) {
                Surface(color = DieterShellTint, shape = CircleShape) {
                    Text(
                        "${information?.activeAgentCount} ${if (information?.activeAgentCount == 1) "agent" else "agents"}",
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
private fun FleetSummary(machines: List<EndpointConnection>, information: Map<String, MachineInformation>) {
    val measured = machines.mapNotNull { information[it.id] }
    val agents = measured.sumOf { it.activeAgentCount.toLong() }
    val cores = measured.sumOf { it.logicalCpuCount.toLong() }
    val memory = measured.sumOf { it.memoryTotalBytes }
    val gpus = measured.sumOf { it.gpu.devicesCount }
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
                Text("${measured.size}/${machines.size} reporting", color = DieterMuted, fontSize = 10.sp)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                FleetMetric(agents.toString(), "agents")
                FleetMetric(cores.toString(), "cores")
                FleetMetric(MachineInformationPresentation.bytes(memory), "memory")
                FleetMetric(gpus.toString(), "GPUs")
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
    machine: EndpointConnection,
    state: DieterUiState,
    expanded: Boolean,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onOperation: (MachineOperationAction, String) -> Unit,
    onOpenTerminals: () -> Unit,
    onDismissOperationMessage: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val information = state.machineInformation[machine.id]
    val loading = machine.id in state.machineInformationLoading
    val error = state.machineInformationErrors[machine.id]
    var actionsOpen by remember { mutableStateOf(false) }
    var pendingAction by remember { mutableStateOf<MachineAction?>(null) }

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
                                state.machineCpuHistory[machine.id].orEmpty(),
                                Modifier.weight(1f),
                            )
                            MachineMemoryPanel(information, Modifier.weight(1f))
                        }
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            MachineCpuPanel(information, state.machineCpuHistory[machine.id].orEmpty())
                            MachineMemoryPanel(information)
                        }
                    }
                }
                if (information.hasGpu()) {
                    item("gpu-title") { MachineSectionHeader("GPU", "${information.gpu.devicesCount} devices") }
                    if (information.gpu.devicesCount == 0) {
                        item("gpu-unavailable") {
                            MachinePanel {
                                Text(
                                    information.gpu.unavailableReason.ifBlank { "No supported GPU telemetry is available." },
                                    color = DieterMuted,
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    } else {
                        items(information.gpu.devicesList, key = GPUDevice::getId) { gpu ->
                            MachineGpuPanel(gpu, state.machineGpuHistory[machine.id]?.get(gpu.id).orEmpty())
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
                        error ?: if (machine.online) "Machine information is unavailable." else machine.detail,
                        color = DieterMuted,
                        fontSize = 12.sp,
                    )
                    if (machine.online && machine.apiVersion == DIETER_API_VERSION) {
                        Button(onClick = onRefresh) { Text("Try again") }
                    }
                }
            }
        }
    }

    pendingAction?.let { action ->
        AlertDialog(
            onDismissRequest = { pendingAction = null },
            title = { Text(action.title) },
            text = { Text(action.explanation) },
            dismissButton = { TextButton(onClick = { pendingAction = null }) { Text("Cancel") } },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingAction = null
                        onOperation(action.wireValue, action.confirmation)
                    },
                    modifier = Modifier.testTag("machine-operation-confirm"),
                ) { Text(action.button, color = if (action == MachineAction.UPDATE) DieterShell else DieterCoral) }
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
    machine: EndpointConnection,
    information: MachineInformation?,
    loading: Boolean,
    expanded: Boolean,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    actionsOpen: Boolean,
    onActionsOpenChange: (Boolean) -> Unit,
    onAction: (MachineAction) -> Unit,
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
                    MachineAction.entries.forEach { action ->
                        DropdownMenuItem(
                            text = { Text(action.button) },
                            leadingIcon = {
                                Icon(
                                    when (action) {
                                        MachineAction.UPDATE -> Icons.Outlined.SystemUpdateAlt
                                        MachineAction.RESTART -> Icons.Outlined.RestartAlt
                                        MachineAction.SHUTDOWN -> Icons.Outlined.PowerSettingsNew
                                    },
                                    null,
                                )
                            },
                            enabled = machineOperationAvailable(information, action.wireValue),
                            onClick = {
                                onActionsOpenChange(false)
                                onAction(action)
                            },
                            modifier = Modifier.testTag("machine-action-${action.name.lowercase()}")
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
                Text(machineSubtitle(machine, information), color = DieterMuted, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                if (machine.online) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Icon(Icons.Outlined.Lan, null, Modifier.size(14.dp), tint = DieterMuted)
                        Text(machine.detail, color = DieterMuted, fontSize = 11.sp)
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
                if (online) "Online" else "Offline",
                color = color,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }
}

private fun machineSubtitle(machine: EndpointConnection, information: MachineInformation?): String {
    if (information == null) return if (machine.online) "Loading machine information…" else machine.detail
    val hardware = listOf(information.hardwareModel, information.processor).filter(String::isNotBlank).joinToString(" · ")
    val os = listOf(information.osName, information.osVersion).filter(String::isNotBlank).joinToString(" ")
    return listOf(hardware, os, "up ${MachineInformationPresentation.uptime(information.uptimeSeconds)}")
        .filter(String::isNotBlank).joinToString("  ·  ")
}

@Composable
private fun MachineCpuPanel(information: MachineInformation, history: List<Double>, modifier: Modifier = Modifier) {
    MachinePanel(modifier.testTag("machine-cpu")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("CPU", color = DieterMuted, fontWeight = FontWeight.Bold, fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            Text(
                MachineInformationPresentation.percentage(information.cpuUsagePercent),
                color = DieterShell,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                fontSize = 23.sp,
            )
        }
        MachineUsageGraph(
            values = information.cpuCoreUsagePercentList.ifEmpty { history.ifEmpty { listOf(information.cpuUsagePercent) } },
            description = "CPU usage ${MachineInformationPresentation.percentage(information.cpuUsagePercent)}",
        )
        Text(
            "${information.logicalCpuCount} cores · load ${formatOne(information.load1)} / ${formatOne(information.load5)} / ${formatOne(information.load15)}",
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
                MachineInformationPresentation.bytes(information.memoryUsedBytes),
                color = DieterEyes,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                fontSize = 17.sp,
            )
            Text(
                " / ${MachineInformationPresentation.bytes(information.memoryTotalBytes)}",
                color = DieterMuted,
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
            )
        }
        MachineMemoryBar(information)
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            MachineLegend("used", information.memoryUsedBytes, DieterEyes)
            MachineLegend("cache", information.memoryCachedBytes, DieterShell)
            MachineLegend("swap", information.swapUsedBytes, DieterAmber)
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
    val total = information.memoryTotalBytes.coerceAtLeast(1).toFloat()
    val used = (information.memoryUsedBytes / total).coerceIn(0f, 1f)
    val cached = (information.memoryCachedBytes / total).coerceIn(0f, 1f - used)
    Row(
        Modifier.fillMaxWidth().height(10.dp).clip(CircleShape).background(DieterSurfaceHigh)
            .semantics {
                contentDescription = "Memory used ${MachineInformationPresentation.bytes(information.memoryUsedBytes)} of ${MachineInformationPresentation.bytes(information.memoryTotalBytes)}"
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
        Text(MachineInformationPresentation.bytes(value), color = DieterText, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
    }
}

@Composable
private fun MachineGpuPanel(device: GPUDevice, history: List<Double>) {
    MachinePanel {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(device.name.ifBlank { "GPU" }, fontWeight = FontWeight.Bold)
                Text(
                    listOf(gpuVendor(device.vendor), device.id, device.driverVersion.takeIf(String::isNotBlank)?.let { "driver $it" })
                        .filterNotNull().joinToString(" · "),
                    color = DieterMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                if (device.hasUtilizationPercent()) MachineInformationPresentation.percentage(device.utilizationPercent) else "—",
                color = if (device.hasUtilizationPercent()) DieterShell else DieterMuted,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                fontSize = 22.sp,
            )
        }
        if (device.hasUtilizationPercent()) {
            MachineUsageGraph(history.ifEmpty { listOf(device.utilizationPercent) }, "GPU usage ${MachineInformationPresentation.percentage(device.utilizationPercent)}")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            if (device.hasMemoryUsedBytes() || device.hasMemoryTotalBytes()) {
                MachineIconMetric(Icons.Outlined.Memory, gpuMemory(device))
            }
            if (device.hasTemperatureCelsius()) {
                MachineIconMetric(Icons.Outlined.Thermostat, "${device.temperatureCelsius.roundToInt()}°C")
            }
            if (device.hasPowerWatts()) {
                MachineIconMetric(Icons.Outlined.Bolt, "${device.powerWatts.roundToInt()} W")
            }
        }
    }
}

private fun gpuVendor(vendor: GPUVendor): String? = when (vendor) {
    GPUVendor.GPU_VENDOR_APPLE -> "Apple"
    GPUVendor.GPU_VENDOR_NVIDIA -> "NVIDIA"
    GPUVendor.GPU_VENDOR_AMD -> "AMD"
    else -> null
}

private fun gpuMemory(device: GPUDevice): String {
    val label = if (device.memoryKind == GPUMemoryKind.GPU_MEMORY_KIND_UNIFIED) "unified" else "VRAM"
    return when {
        device.hasMemoryUsedBytes() && device.hasMemoryTotalBytes() ->
            "${MachineInformationPresentation.bytes(device.memoryUsedBytes)} / ${MachineInformationPresentation.bytes(device.memoryTotalBytes)} $label"
        device.hasMemoryUsedBytes() -> "${MachineInformationPresentation.bytes(device.memoryUsedBytes)} $label"
        else -> "${MachineInformationPresentation.bytes(device.memoryTotalBytes)} $label"
    }
}

@Composable
private fun MachineSoftwarePanel(machine: EndpointConnection, information: MachineInformation) {
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
                val build = information.daemonBuild
                Text(
                    listOf(
                        build.releaseVersion.ifBlank { "Unknown" },
                        (build.apiVersion.ifBlank { machine.apiVersion }).takeIf(String::isNotBlank)?.let { "API $it" },
                        MachineInformationPresentation.shortRevision(build.sourceRevision),
                    ).filterNotNull().joinToString(" · "),
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
        MachineSectionHeader(
            "DIETER PROCESSES",
            "${information.activeAgentCount} ${if (information.activeAgentCount == 1) "agent" else "agents"} active",
        )
        Surface(
            color = DieterSurface,
            shape = RoundedCornerShape(14.dp),
            border = BorderStroke(1.dp, DieterOutline),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                if (information.processesCount == 0) {
                    Text("No Dieter processes reported.", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.padding(14.dp))
                } else {
                    information.processesList.forEachIndexed { index, process ->
                        MachineProcessRow(process)
                        if (index < information.processesCount - 1) HorizontalDivider(color = DieterDivider)
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
            if (process.kind == "agent") Icons.Outlined.Refresh else Icons.Outlined.Terminal,
            null,
            Modifier.size(18.dp),
            tint = if (process.kind == "agent") DieterShell else DieterMuted,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(process.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "pid ${process.pid} · ${process.detail}",
                color = DieterMuted,
                fontFamily = FontFamily.Monospace,
                fontSize = 9.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(MachineInformationPresentation.percentage(process.cpuUsagePercent), color = DieterMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
        Text(MachineInformationPresentation.bytes(process.memoryBytes), color = DieterEyes, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
    }
}

@Composable
private fun MachineFooter(machine: EndpointConnection, information: MachineInformation, onOpenTerminals: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            MachineIconMetric(Icons.Outlined.Storage, "${MachineInformationPresentation.bytes(information.diskFreeBytes)} free")
            MachineIconMetric(
                Icons.Outlined.Lan,
                "↓ ${MachineInformationPresentation.rate(information.networkReceiveBytesPerSecond)} · ↑ ${MachineInformationPresentation.rate(information.networkSendBytesPerSecond)}",
            )
            if (information.temperatureCelsius > 0) {
                MachineIconMetric(Icons.Outlined.Thermostat, "${information.temperatureCelsius.roundToInt()}°C")
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
private fun MachineIconMetric(icon: androidx.compose.ui.graphics.vector.ImageVector, value: String) {
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

private fun formatOne(value: Double): String = String.format(Locale.getDefault(), "%.1f", value)
