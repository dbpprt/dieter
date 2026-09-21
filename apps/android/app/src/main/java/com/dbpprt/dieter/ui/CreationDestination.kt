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
import com.dbpprt.dieter.ui.theme.*

internal val DieterUiState.creationCheckout
    get() = project?.checkoutsList.orEmpty().filterNot { it.detached }.let { checkouts ->
        checkouts.firstOrNull { it.id == creationCheckoutId } ?: checkouts.singleOrNull()
    }

internal val DieterUiState.creationMachine
    get() = creationCheckout?.let { checkout ->
        presentedEndpointConnections.firstOrNull { it.daemonId == checkout.daemonId }
    }

internal val DieterUiState.creationCatalogReady: Boolean
    get() = creationMachine?.let { it.online && it.id == harnessesEndpointId } == true

internal fun DieterUiState.machineLabel(daemonId: String): String =
    presentedEndpointConnections.firstOrNull { it.daemonId == daemonId }?.label?.takeIf { it.isNotBlank() }
        ?: projectReplicas.values.firstOrNull { it.daemonId == daemonId }?.hostname?.takeIf { it.isNotBlank() }
        ?: daemonId.ifBlank { "Unassigned" }

@Composable
internal fun CreationDestinationPicker(
    state: DieterUiState,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    val checkouts = state.project?.checkoutsList.orEmpty().filterNot { it.detached }
    val selected = state.creationCheckout
    val machine = state.creationMachine
    val status = when {
        checkouts.isEmpty() -> "No checkouts available for this project"
        selected == null -> "Choose where this task will run"
        machine?.online != true -> "Machine offline · choose an online destination"
        !state.creationCatalogReady -> "Loading agent models…"
        else -> selected.name.ifBlank { "Project checkout" }
    }
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
                    Text(selected?.let { state.machineLabel(it.daemonId) } ?: "Select machine",
                        fontSize = 14.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(status, color = DieterMuted, fontSize = 11.sp, lineHeight = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                Icon(Icons.Outlined.KeyboardArrowDown, "Choose machine and checkout", tint = DieterMuted)
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.widthIn(max = 360.dp)) {
            checkouts.forEach { checkout ->
                val online = state.presentedEndpointConnections.any { it.daemonId == checkout.daemonId && it.online }
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(state.machineLabel(checkout.daemonId), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(checkout.name.ifBlank { "Project checkout" } + if (online) "" else " · Offline",
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
