package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.dbpprt.dieter.v1.PeerVersion
import org.json.JSONTokener

@Composable
internal fun SharedConflicts(state: DieterUiState, model: DieterViewModel) {
    val record = state.sharedConflicts.firstOrNull() ?: return
    AlertDialog(
        onDismissRequest = model::dismissSharedConflicts,
        title = { Text("Resolve ${record.id.substringAfterLast('.')}") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text("These edits were made independently. Choose the value to keep, then edit it normally if needed.")
                record.versionsList.forEach { version ->
                    Text(sharedVersionText(version))
                    TextButton(onClick = { model.resolveSharedConflict(record, version) }, enabled = !state.working) {
                        Text(if (version.deleted) "Keep deletion" else "Keep this value")
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = model::dismissSharedConflicts) { Text("Close") } },
    )
}
private fun sharedVersionText(version: PeerVersion): String {
    if (version.deleted) return "Deleted"
    val raw = version.valueJson.toStringUtf8()
    return runCatching { JSONTokener(raw).nextValue().toString() }.getOrDefault(raw)
}
