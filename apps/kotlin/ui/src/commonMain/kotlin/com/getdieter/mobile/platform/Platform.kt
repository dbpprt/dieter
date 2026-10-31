package com.getdieter.mobile.platform

import androidx.compose.material3.ColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import com.getdieter.mobile.design.*

// System integration each platform supplies to the shared theme, icons and navigation.

/**
 * Debuggable Android builds expose test tags as resource IDs for UI flows. A window of its own,
 * such as a modal sheet, does not inherit that from the activity's content.
 */
@Composable internal expect fun Modifier.exposingTestTags(): Modifier

/** Platform hook for system back (Android predictive back). No-op elsewhere. */
@Composable internal expect fun SystemBackHandler(enabled: Boolean, onBack: () -> Unit)

/** The system's monospaced face: SF Mono on Apple platforms. */
internal expect fun platformMonospace(): FontFamily

/** Device colors on Android 12+, null elsewhere. */
@Composable internal expect fun platformDynamicScheme(dark: Boolean): ColorScheme?

internal expect val platformSupportsDynamicColor: Boolean

/** An SF Symbol painter on iOS. Null where Material vectors are used. */
@Composable
internal expect fun platformSymbolPainter(symbol: String, size: Dp, weight: GlyphWeight): Painter?
