package com.dbpprt.dieter.mobile

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

// JVM is the core journey target, not a shipped mobile host.
@Composable internal actual fun NativeTerminal(store: MobileStore, modifier: Modifier) = Unit

@Composable internal actual fun NativeScreenCanvas(store: MobileStore, modifier: Modifier) = Unit

@Composable
internal actual fun rememberAttachmentPicker(
    onPicked: (List<com.dbpprt.dieter.api.v1.MessagePart>) -> Unit,
    onError: (String) -> Unit,
): () -> Unit = {}

@Composable
internal actual fun rememberAttachmentViewer(
    onError: (String) -> Unit
): (com.dbpprt.dieter.api.v1.MessagePart) -> Unit = {}
