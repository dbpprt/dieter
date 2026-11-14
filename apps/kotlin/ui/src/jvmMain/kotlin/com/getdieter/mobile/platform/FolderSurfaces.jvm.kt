package com.getdieter.mobile.platform

import androidx.compose.runtime.Composable

// The JVM keeps no folders; these are inert so shared screens render in tests.
@Composable
internal actual fun rememberFolderFileOpener(
    onError: (String) -> Unit
): (file: FolderFileRef, share: Boolean) -> Unit = { _, _ -> }

@Composable
internal actual fun rememberFolderLocationPicker(
    onPicked: (location: String, label: String) -> Unit,
    onError: (String) -> Unit,
): (() -> Unit)? = JvmFolderSurfaces.locationPicker?.let { pick -> { pick(onPicked) } }

@Composable internal actual fun rememberNotificationPermission(): () -> Unit = {}

/** Tests install a fake shared-folder picker to drive the add-folder flow. */
internal object JvmFolderSurfaces {
    var locationPicker: (((String, String) -> Unit) -> Unit)? = null
}
