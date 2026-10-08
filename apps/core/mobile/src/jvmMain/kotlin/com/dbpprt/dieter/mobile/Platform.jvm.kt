package com.dbpprt.dieter.mobile

import androidx.compose.material3.ColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.unit.Dp

@Composable internal actual fun platformDynamicScheme(dark: Boolean): ColorScheme? = null

internal actual val platformSupportsDynamicColor: Boolean
    get() = false

@Composable
internal actual fun platformSymbolPainter(symbol: String, size: Dp, weight: GlyphWeight): Painter? =
    null

@Composable internal actual fun SystemBackHandler(enabled: Boolean, onBack: () -> Unit) = Unit

internal actual fun platformMonospace(): androidx.compose.ui.text.font.FontFamily =
    androidx.compose.ui.text.font.FontFamily.Monospace
