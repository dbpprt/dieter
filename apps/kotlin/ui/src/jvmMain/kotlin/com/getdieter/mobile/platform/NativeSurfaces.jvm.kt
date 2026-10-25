package com.getdieter.mobile.platform

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.getdieter.mobile.store.*

// JVM is the core journey target, not a shipped mobile host.
@Composable internal actual fun NativeTerminal(store: MobileStore, modifier: Modifier) = Unit

@Composable internal actual fun NativeScreenCanvas(store: MobileStore, modifier: Modifier) = Unit

@Composable
internal actual fun rememberAttachmentPicker(
    onPicked: (List<com.getdieter.api.v1.MessagePart>) -> Unit,
    onError: (String) -> Unit,
): () -> Unit = {}

@Composable
internal actual fun rememberAttachmentViewer(
    onError: (String) -> Unit
): (com.getdieter.api.v1.MessagePart) -> Unit = {}

@Composable
internal actual fun rememberTextSharer(): (subject: String, text: String) -> Unit = { _, _ -> }
