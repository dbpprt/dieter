package com.dbpprt.nauclio.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dbpprt.nauclio.update.AppUpdateManager
import com.dbpprt.nauclio.update.AppUpdateState
import com.dbpprt.nauclio.ui.theme.NauclioMuted

@Composable
fun AppUpdateDialog(manager: AppUpdateManager) {
    val state by manager.state.collectAsStateWithLifecycle()
    val visible by manager.promptVisible.collectAsStateWithLifecycle()
    if (!visible) return

    when (val current = state) {
        is AppUpdateState.Available -> AlertDialog(
            onDismissRequest = manager::dismissPrompt,
            modifier = Modifier.testTag("app-update-available"),
            title = { Text("Update available") },
            text = {
                UpdateDialogText(
                    title = "Nauclio ${current.release.version}",
                    detail = "You're on ${manager.currentVersion}. The APK comes from the official GitHub release and is SHA-256 verified before installation.",
                )
            },
            confirmButton = {
                Button(onClick = manager::downloadUpdate, modifier = Modifier.testTag("download-app-update")) {
                    Text("Download")
                }
            },
            dismissButton = { TextButton(onClick = manager::dismissPrompt) { Text("Later") } },
        )

        is AppUpdateState.Downloading -> {
            val progress = (current.bytesDownloaded.toFloat() / current.release.sizeBytes.toFloat()).coerceIn(0f, 1f)
            AlertDialog(
                onDismissRequest = {},
                modifier = Modifier.testTag("app-update-downloading"),
                title = { Text("Downloading ${current.release.version}") },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
                        Text("${(progress * 100).toInt()}%", color = NauclioMuted)
                    }
                },
                confirmButton = {},
            )
        }

        is AppUpdateState.ReadyToInstall -> AlertDialog(
            onDismissRequest = manager::dismissPrompt,
            modifier = Modifier.testTag("app-update-ready"),
            title = { Text(if (current.installationAllowed) "Ready to install" else "Allow app updates") },
            text = {
                UpdateDialogText(
                    title = "Nauclio ${current.release.version} is verified.",
                    detail = if (current.installationAllowed) {
                        "Android will show the final installation confirmation."
                    } else {
                        "Allow Nauclio to install updates, then return here and tap Install."
                    },
                )
            },
            confirmButton = {
                Button(
                    onClick = if (current.installationAllowed) {
                        manager::installDownloadedUpdate
                    } else {
                        manager::openInstallPermissionSettings
                    },
                    modifier = Modifier.testTag(if (current.installationAllowed) "install-app-update" else "allow-app-updates"),
                ) {
                    Text(if (current.installationAllowed) "Install" else "Open settings")
                }
            },
            dismissButton = { TextButton(onClick = manager::dismissPrompt) { Text("Later") } },
        )

        is AppUpdateState.Failed -> AlertDialog(
            onDismissRequest = manager::dismissPrompt,
            modifier = Modifier.testTag("app-update-failed"),
            title = { Text("Update failed") },
            text = { Text(current.message) },
            confirmButton = { Button(onClick = manager::retry) { Text("Retry") } },
            dismissButton = { TextButton(onClick = manager::dismissPrompt) { Text("Later") } },
        )

        AppUpdateState.Checking,
        AppUpdateState.Idle,
        is AppUpdateState.UpToDate,
        -> Unit
    }
}

@Composable
private fun UpdateDialogText(title: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, fontWeight = FontWeight.SemiBold)
        Text(detail, color = NauclioMuted, style = MaterialTheme.typography.bodyMedium)
    }
}
