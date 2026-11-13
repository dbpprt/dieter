package com.getdieter.mobile.platform

import androidx.compose.runtime.Composable
import platform.Foundation.NSDocumentDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSURL
import platform.Foundation.NSUserDomainMask
import platform.UIKit.UIActivityViewController
import platform.UIKit.UIApplication
import platform.UIKit.UIViewController
import platform.UIKit.popoverPresentationController

/**
 * A file of a folder kept in the app's Documents container: an absolute path, a file URL, or a
 * location relative to Documents.
 */
private fun folderFileUrl(file: FolderFileRef): NSURL? {
    val base =
        when {
            file.location.startsWith("file:") -> NSURL.URLWithString(file.location)
            file.location.startsWith("/") -> NSURL.fileURLWithPath(file.location)
            else ->
                NSFileManager.defaultManager
                    .URLsForDirectory(NSDocumentDirectory, NSUserDomainMask)
                    .firstOrNull()
                    ?.let { it as? NSURL }
                    ?.URLByAppendingPathComponent(file.location)
        } ?: return null
    return if (file.path.isEmpty()) base else base.URLByAppendingPathComponent(file.path)
}

private fun topViewController(): UIViewController? {
    var top = UIApplication.sharedApplication.keyWindow?.rootViewController
    while (top?.presentedViewController != null) top = top.presentedViewController
    return top
}

/** iOS opens and shares a folder's file through the system share sheet, which also offers Open. */
@Composable
internal actual fun rememberFolderFileOpener(
    onError: (String) -> Unit
): (file: FolderFileRef, share: Boolean) -> Unit = { file, _ ->
    val url = folderFileUrl(file)
    val top = topViewController()
    if (url == null || top == null) onError("This file is not on this iPhone.")
    else {
        val controller = UIActivityViewController(listOf(url), null)
        controller.popoverPresentationController?.sourceView = top.view
        top.presentViewController(controller, true, null)
    }
}

/** A folder's location on iOS is fixed: On My iPhone › Dieter › Name. */
@Composable
internal actual fun rememberFolderLocationPicker(
    onPicked: (location: String, label: String) -> Unit,
    onError: (String) -> Unit,
): (() -> Unit)? = null

/** The iOS app asks for notifications where it posts them. */
@Composable internal actual fun rememberNotificationPermission(): () -> Unit = {}
