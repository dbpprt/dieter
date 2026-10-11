@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.tools

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

internal fun machineGlyph(platform: String): Glyph =
    when {
        platform.contains("linux", true) -> Glyph.SERVER
        else -> Glyph.MACHINE
    }

@Composable
internal fun MachinesScreen(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    val online = session.machines.count { it.online }
    Screen(
        ScreenChrome(
            "Machines",
            subtitle =
                if (session.machines.isEmpty()) ""
                else "$online of ${session.machines.size} online",
            actions =
                listOf(
                    ChromeAction(
                        "reconnect",
                        "Reconnect",
                        Glyph.REFRESH,
                        onClick = store.session::retry,
                    )
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("machines-list"),
            state = listState,
            contentPadding = padding,
        ) {
            item { ConnectionNotice(store) }
            item { Spacer(Modifier.height(8.dp)) }
            if (session.machines.isEmpty())
                item {
                    EmptyState(
                        Glyph.MACHINE,
                        "No machines",
                        "Enroll a computer with the Dieter daemon to run agents on it.",
                        Modifier.padding(top = 40.dp),
                    )
                }
            itemsIndexed(session.machines, key = { _, machine -> machine.id }) { index, machine ->
                ListRow(
                    machine.display_name,
                    Modifier.testTag("machine-${machine.id}"),
                    position = Position.of(index, session.machines.size),
                    subtitle =
                        listOf(machine.presence, machine.detail)
                            .filter { it.isNotBlank() }
                            .distinct()
                            .joinToString(" · "),
                    glyph = machineGlyph(machine.platform),
                    tile = if (machine.online) Color(0xFF0A84FF) else Color(0xFF8E8E93),
                    accessory = Accessory.CHEVRON,
                    trailing = {
                        Box(
                            Modifier.size(9.dp)
                                .background(
                                    if (machine.online) palette.success else palette.tertiaryLabel,
                                    CircleShape,
                                )
                        )
                    },
                    onClick = { store.push(MobileRoute.Machine(machine.id)) },
                )
            }
        }
    }
}

@Composable
internal fun MachineScreen(store: MobileStore, machineId: String) {
    val session by store.session.slice.collectAsState()
    val telemetry by store.machines.telemetry.collectAsState()
    var operation by remember { mutableStateOf<MachineOperationState?>(null) }
    var rename by remember { mutableStateOf(false) }
    val machine = session.machines.firstOrNull { it.id == machineId }
    val readings = telemetry.machines[machineId]
    val information = readings?.information
    Screen(
        ScreenChrome(
            machine?.display_name ?: "Machine",
            subtitle = machine?.presence.orEmpty(),
            actions =
                listOf(ChromeAction("rename-machine", "Rename", Glyph.RENAME) { rename = true }),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("machine-detail"),
            state = listState,
            contentPadding = padding,
        ) {
            if (machine == null) {
                item { Placeholder("This machine is no longer enrolled.") }
                return@LazyColumn
            }
            item {
                SectionHeader("Connection")
                Group(
                    listOfNotNull(
                        "Status" to
                            machine.presence.ifEmpty {
                                if (machine.online) "Online" else "Offline"
                            },
                        machine.route.takeIf { it.isNotEmpty() }?.let { "Route" to it },
                        "Dieter" to machine.release_version,
                        machine.privacy_label
                            .takeIf { it.isNotEmpty() }
                            ?.let {
                                val state =
                                    when {
                                        machine.privacy_warning -> "Degraded"
                                        machine.privacy_active -> "On"
                                        else -> "Off"
                                    }
                                "Privacy mode" to
                                    if (machine.privacy_stale) "$state (last known)" else state
                            },
                        machine.sync_label.takeIf { it.isNotEmpty() }?.let { "Sync" to it },
                    )
                ) { (title, value), position ->
                    ListRow(title, position = position, value = value)
                }
                // The shared wording explains what an active or degraded privacy mode means.
                if (machine.privacy_active || machine.privacy_warning)
                    SectionFooter(machine.privacy_label)
            }
            if (information != null) {
                item {
                    SectionHeader("System")
                    Group(
                        listOfNotNull(
                            "System" to
                                listOf(information.os_name, information.os_version)
                                    .filter { it.isNotEmpty() }
                                    .joinToString(" "),
                            information.hardware_model
                                .takeIf { it.isNotEmpty() }
                                ?.let { "Model" to it },
                            information.processor
                                .takeIf { it.isNotEmpty() }
                                ?.let { "Processor" to it },
                            "Cores" to "${information.logical_cpu_count}",
                            "Active agents" to "${information.active_agent_count}",
                        )
                    ) { (title, value), position ->
                        ListRow(title, position = position, value = value)
                    }
                }
                item {
                    SectionHeader("Load")
                    Column(
                        Modifier.fillMaxWidth()
                            .padding(horizontal = ScreenMargin)
                            .clip(groupShape(Position.SINGLE))
                            .background(palette.cell)
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Gauge(
                            "CPU",
                            "${information.cpu_usage_percent.toInt()}%",
                            (information.cpu_usage_percent / 100).toFloat(),
                        )
                        if (information.memory_total_bytes > 0)
                            Gauge(
                                "Memory",
                                "${gigabytes(information.memory_used_bytes)} of ${gigabytes(information.memory_total_bytes)} GB",
                                information.memory_used_bytes.toFloat() /
                                    information.memory_total_bytes,
                            )
                        Row {
                            Text(
                                "Free storage",
                                Modifier.weight(1f),
                                style = type.subheadline,
                                color = palette.secondaryLabel,
                            )
                            Text(
                                "${gigabytes(information.disk_free_bytes)} GB",
                                style = type.subheadline,
                                color = palette.label,
                            )
                        }
                        Row {
                            Text(
                                "Network",
                                Modifier.weight(1f),
                                style = type.subheadline,
                                color = palette.secondaryLabel,
                            )
                            Text(
                                "↓ ${formatBytes(information.network_receive_bytes_per_second.toLong())}/s  ↑ ${formatBytes(information.network_send_bytes_per_second.toLong())}/s",
                                style = type.subheadline,
                                color = palette.label,
                            )
                        }
                    }
                }
            }
            readings
                ?.operations
                ?.takeIf { it.isNotEmpty() }
                ?.let { operations ->
                    item {
                        SectionHeader("Actions")
                        Group(operations) { state, position ->
                            val copy =
                                com.getdieter.core.client.rules.MachineExports.operationCopy(
                                    state.action.value
                                )
                            ListRow(
                                copy.menu_title,
                                position = position,
                                subtitle =
                                    state.unavailable_reason.takeIf {
                                        !state.available && it.isNotEmpty()
                                    },
                                destructive = copy.destructive,
                                enabled = state.available && !telemetry.operation_pending,
                                onClick = { operation = state },
                            )
                        }
                        if (telemetry.operation_result.isNotEmpty())
                            SectionFooter(telemetry.operation_result)
                    }
                }
            if (readings?.loading == true && information == null)
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(32.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            readings
                ?.error
                ?.takeIf { it.isNotEmpty() }
                ?.let { failure ->
                    item {
                        Banner(
                            "Telemetry unavailable",
                            failure,
                            Modifier.padding(horizontal = ScreenMargin, vertical = 12.dp),
                            tone = Tone.WARNING,
                            actionLabel = "Retry",
                            onAction = {
                                store.command(
                                    Command(
                                        telemetry =
                                            TelemetryCommand(
                                                select = TelemetrySelect(machineId, true)
                                            )
                                    )
                                )
                            },
                        )
                    }
                }
            val processes = information?.processes.orEmpty().take(30)
            if (processes.isNotEmpty()) {
                item { SectionHeader("Top processes") }
                itemsIndexed(processes, key = { _, process -> process.pid }) { index, process ->
                    ListRow(
                        process.name,
                        position = Position.of(index, processes.size),
                        value = "PID ${process.pid}",
                    )
                }
            }
        }
    }
    operation?.let { state ->
        val copy = com.getdieter.core.client.rules.MachineExports.operationCopy(state.action.value)
        ConfirmDialog(
            copy.title,
            copy.explanation,
            copy.button,
            {
                store.command(
                    Command(
                        telemetry = TelemetryCommand(perform = TelemetryOperation(state.action))
                    )
                )
                operation = null
            },
            { operation = null },
            destructive = copy.destructive,
        )
    }
    if (rename && machine != null)
        PromptDialog(
            "Rename machine",
            machine.display_name,
            "Save",
            {
                store.command(Command(rename_machine = RenameMachine(machineId, it)))
                rename = false
            },
            { rename = false },
            placeholder = "Machine name",
        )
}

private fun gigabytes(bytes: Long) =
    ((bytes / 107_374_182.4).toInt() / 10.0).let {
        if (it >= 100) it.toInt().toString() else it.toString()
    }

@Composable
private fun Gauge(title: String, value: String, fraction: Float) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row {
            Text(
                title,
                Modifier.weight(1f),
                style = type.subheadline,
                color = palette.secondaryLabel,
            )
            Text(
                value,
                style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                color = palette.label,
            )
        }
        ProgressBar(fraction, color = if (fraction > .85f) palette.warning else palette.info)
    }
}
