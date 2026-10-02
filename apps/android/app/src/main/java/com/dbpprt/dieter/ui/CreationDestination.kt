package com.dbpprt.dieter.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.core.composition.CaptureDestinations
import com.dbpprt.dieter.core.composition.CatalogState
import com.dbpprt.dieter.core.composition.Creation
import com.dbpprt.dieter.core.composition.CreationInput
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.ui.theme.*
import com.dbpprt.dieter.api.v1.Project

internal val DieterUiState.creationCheckout
    get() = project?.let { Creation.checkout(it, creationCheckoutId) }

internal val DieterUiState.creationMachine
    get() = creationCheckout?.let { checkout ->
        presentedEndpointConnections.firstOrNull { it.daemonId == checkout.daemon_id }
    }

/** The destination machine's agent catalog: live, cached while it is offline, or not loaded. */
internal val DieterUiState.catalogState: CatalogState
    get() = Creation.catalogState(creationCheckout, harnessesEndpointId, creationMachine?.online == true)

/** The catalog a new conversation is validated against, or null while it loads (the core's rule). */
internal fun DieterUiState.creationCatalog(chat: Boolean): List<Harness>? = Creation.catalog(chat, catalogState, harnesses)

/** Why [draft] cannot be queued now, or null: the core's creation rules against this state. */
internal fun DieterUiState.creationProblem(draft: CaptureDraft, chat: Boolean): String? {
    val project = project ?: return Creation.NO_PROJECT
    return TaskDrafts.problem(draft, creationInput(draft, project, chat), creationCatalog(chat))
}

internal fun DieterUiState.canSubmitTask(draft: CaptureDraft): Boolean = !working && creationProblem(draft, chat = false) == null

internal fun DieterUiState.creationInput(draft: CaptureDraft, project: Project, chat: Boolean): CreationInput {
    val checkoutId = creationCheckout?.id ?: creationCheckoutId
    return if (chat) TaskDrafts.chatInput(draft, project, checkoutId) else TaskDrafts.input(draft, project, board, checkoutId)
}

internal fun DieterUiState.machineLabel(daemonId: String): String =
    MachineRows.label(presentedEndpointConnections, emptyMap(), daemonId)

internal fun DieterUiState.projectCheckoutLabel(project: Project): String {
    val machines = presentedEndpointConnections.associateBy { it.daemonId }
    return CaptureDestinations.checkoutSummary(project, ::machineLabel) { daemonId -> machines[daemonId]?.online }
}

@Composable
internal fun CreationDestinationPicker(
    state: DieterUiState,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    val checkouts = state.project?.checkouts.orEmpty().filterNot { it.detached }
    val selected = state.creationCheckout
    val machine = state.creationMachine
    val status = Creation.destinationStatus(state.project, selected, machine?.online == true, state.catalogState)
    Box(modifier.fillMaxWidth()) {
        Surface(
            onClick = { expanded = true },
            enabled = !state.working && checkouts.isNotEmpty(),
            shape = RoundedCornerShape(12.dp),
            color = DieterSurfaceHigh,
            border = BorderStroke(1.dp, DieterOutline),
            modifier = Modifier.fillMaxWidth().testTag("creation-destination"),
        ) {
            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Outlined.Computer, null, Modifier.size(20.dp), tint = DieterShell)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Run on", color = DieterMuted, fontSize = 11.sp, lineHeight = 14.sp)
                    Text(selected?.let { state.machineLabel(it.daemon_id) } ?: "Select machine",
                        fontSize = 14.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(status, color = DieterMuted, fontSize = 11.sp, lineHeight = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                Icon(Icons.Outlined.KeyboardArrowDown, "Choose machine and checkout", tint = DieterMuted)
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.widthIn(max = 360.dp)) {
            checkouts.forEach { checkout ->
                val online = state.presentedEndpointConnections.any { it.daemonId == checkout.daemon_id && it.online }
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(state.machineLabel(checkout.daemon_id), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(Creation.checkoutTitle(checkout, online),
                                fontSize = 11.sp, lineHeight = 14.sp, color = DieterMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    },
                    leadingIcon = { Icon(Icons.Outlined.Computer, null, Modifier.size(18.dp)) },
                    trailingIcon = { if (selected?.id == checkout.id) Icon(Icons.Default.Check, "Selected", Modifier.size(18.dp)) },
                    enabled = online,
                    onClick = { expanded = false; onSelect(checkout.id) },
                    modifier = Modifier.testTag("creation-checkout-${checkout.id}"),
                )
            }
        }
    }
}
