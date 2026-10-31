package com.getdieter.mobile.platform

import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.Dp
import com.getdieter.mobile.design.*

@Composable
internal actual fun platformDynamicScheme(dark: Boolean): ColorScheme? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
    val context = LocalContext.current
    return if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
}

internal actual val platformSupportsDynamicColor: Boolean
    get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

@Composable
internal actual fun platformSymbolPainter(symbol: String, size: Dp, weight: GlyphWeight): Painter? =
    null

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
internal actual fun Modifier.exposingTestTags(): Modifier {
    val debuggable =
        LocalContext.current.applicationInfo.flags and
            android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
    return semantics { testTagsAsResourceId = debuggable }
}

@Composable
internal actual fun SystemBackHandler(enabled: Boolean, onBack: () -> Unit) =
    BackHandler(enabled, onBack)

internal actual fun platformMonospace(): androidx.compose.ui.text.font.FontFamily =
    androidx.compose.ui.text.font.FontFamily.Monospace
