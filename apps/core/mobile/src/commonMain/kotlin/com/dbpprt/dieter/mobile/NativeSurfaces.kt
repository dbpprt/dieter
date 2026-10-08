package com.dbpprt.dieter.mobile

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

// Renderers, pickers and media stay native; navigation and commands remain shared.
@Composable internal expect fun NativeTerminal(store: MobileStore, modifier: Modifier)

@Composable internal expect fun NativeScreenCanvas(store: MobileStore, modifier: Modifier)

@Composable
internal expect fun rememberAttachmentPicker(
    onPicked: (List<com.dbpprt.dieter.api.v1.MessagePart>) -> Unit,
    onError: (String) -> Unit,
): () -> Unit

@Composable
internal expect fun rememberAttachmentViewer(
    onError: (String) -> Unit
): (com.dbpprt.dieter.api.v1.MessagePart) -> Unit
