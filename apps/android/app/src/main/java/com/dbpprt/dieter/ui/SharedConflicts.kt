package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.dbpprt.dieter.core.admin.ConflictVersions

@Composable
internal fun SharedConflicts(state: DieterUiState, model: DieterViewModel) {
    val record = state.sharedConflicts.firstOrNull() ?: return
    AlertDialog(
        onDismissRequest = model::dismissSharedConflicts,
        title = { Text("Resolve ${record.id.substringAfterLast('.')}") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text("These edits were made independently. Choose the value to keep, then edit it normally if needed.")
                record.versions.forEach { version ->
                    Text(ConflictVersions.versionText(version))
                    TextButton(onClick = { model.resolveSharedConflict(record, version) }, enabled = !state.working) {
                        Text(ConflictVersions.keepLabel(version))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = model::dismissSharedConflicts) { Text("Close") } },
    )
}
