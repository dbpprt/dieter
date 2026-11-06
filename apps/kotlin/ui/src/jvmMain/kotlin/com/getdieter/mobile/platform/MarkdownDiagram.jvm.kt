package com.getdieter.mobile.platform

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
internal actual fun NativeMarkdownDiagram(
    assets: Map<String, ByteArray>,
    script: String,
    modifier: Modifier,
    onResult: (Double, String?) -> Unit,
) = Unit
