package com.getdieter.mobile.platform

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.getdieter.core.composition.Attachments
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
internal actual fun rememberFolderFileOpener(
    onError: (String) -> Unit
): (file: FolderFileRef, share: Boolean) -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val failure by rememberUpdatedState(onError)
    return { file, share ->
        scope.launch {
            try {
                val uri =
                    withContext(Dispatchers.IO) {
                        AndroidFolderLocations.uriFor(context, file.location, file.path)
                    } ?: throw IllegalStateException("This file is not on this device.")
                val type =
                    Attachments.mediaType(
                        runCatching { context.contentResolver.getType(uri) }.getOrNull(),
                        file.name,
                    )
                val intent =
                    if (share)
                        Intent.createChooser(
                            Intent(Intent.ACTION_SEND)
                                .setType(type)
                                .putExtra(Intent.EXTRA_STREAM, uri)
                                .apply { clipData = ClipData.newRawUri(file.name, uri) }
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                            file.name,
                        )
                    else
                        Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, type)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                context.startActivity(intent)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (missing: ActivityNotFoundException) {
                failure("No app on this device opens ${file.name}.")
            } catch (error: Throwable) {
                failure(error.message ?: "Could not open ${file.name}.")
            }
        }
    }
}

@Composable
internal actual fun rememberFolderLocationPicker(
    onPicked: (location: String, label: String) -> Unit,
    onError: (String) -> Unit,
): (() -> Unit)? {
    val context = LocalContext.current
    val picked by rememberUpdatedState(onPicked)
    val failure by rememberUpdatedState(onError)
    val launcher =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { tree ->
            if (tree == null) return@rememberLauncherForActivityResult
            try {
                // The permission outlives this process, so background syncs can use the tree.
                context.contentResolver.takePersistableUriPermission(
                    tree,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                picked(tree.toString(), AndroidFolderLocations.treeLabel(context, tree))
            } catch (error: SecurityException) {
                failure("Dieter cannot keep access to that folder. Choose another one.")
            }
        }
    return { launcher.launch(null) }
}

@Composable
internal actual fun rememberNotificationPermission(): () -> Unit {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    return {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) != PackageManager.PERMISSION_GRANTED
        )
            launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
