package com.getdieter.mobile.platform

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.getdieter.mobile.store.*

// Renderers, pickers and media stay native; navigation and commands remain shared.
@Composable internal expect fun NativeTerminal(store: MobileStore, modifier: Modifier)

@Composable internal expect fun NativeScreenCanvas(store: MobileStore, modifier: Modifier)

@Composable
internal expect fun rememberAttachmentPicker(
    onPicked: (List<com.getdieter.api.v1.MessagePart>) -> Unit,
    onError: (String) -> Unit,
): () -> Unit

@Composable
internal expect fun rememberAttachmentViewer(
    onError: (String) -> Unit
): (com.getdieter.api.v1.MessagePart) -> Unit

/** Hands [text] to the system share sheet, titled [subject]; e.g. a mail message's Markdown. */
@Composable internal expect fun rememberTextSharer(): (subject: String, text: String) -> Unit

/** A file of a synced folder's copy on this device: where the folder lives and its path there. */
internal class FolderFileRef(val location: String, val path: String, val name: String)

/**
 * Opens [FolderFileRef] in another app, or hands it to the share sheet when `share` is true (an
 * Android content URI, an iOS file URL).
 */
@Composable
internal expect fun rememberFolderFileOpener(
    onError: (String) -> Unit
): (file: FolderFileRef, share: Boolean) -> Unit

/**
 * Picks a shared folder for a synced folder (Android's document tree picker, whose permission
 * persists) and reports its location and label; null where a folder's location is fixed (iOS).
 */
@Composable
internal expect fun rememberFolderLocationPicker(
    onPicked: (location: String, label: String) -> Unit,
    onError: (String) -> Unit,
): (() -> Unit)?

/** Asks for permission to post notifications where the platform needs one (Android 13+). */
@Composable internal expect fun rememberNotificationPermission(): () -> Unit
