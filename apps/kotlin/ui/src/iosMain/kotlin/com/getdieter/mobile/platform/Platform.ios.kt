@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package com.getdieter.mobile.platform

import androidx.compose.material3.ColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import com.getdieter.mobile.design.*
import kotlinx.cinterop.*
import platform.CoreGraphics.CGPointMake
import platform.Foundation.NSData
import platform.Foundation.create
import platform.UIKit.*
import platform.posix.memcpy

@Composable internal actual fun platformDynamicScheme(dark: Boolean): ColorScheme? = null

internal actual val platformSupportsDynamicColor: Boolean
    get() = false

@Composable internal actual fun SystemBackHandler(enabled: Boolean, onBack: () -> Unit) = Unit

@Composable
internal actual fun androidx.compose.ui.Modifier.exposingTestTags(): androidx.compose.ui.Modifier =
    this

private val monospace: androidx.compose.ui.text.font.FontFamily by lazy {
    val typeface =
        listOf("SFMono-Regular", ".AppleSystemUIFontMonospaced", "Menlo-Regular")
            .firstNotNullOfOrNull { name ->
                org.jetbrains.skia.FontMgr.default.matchFamilyStyle(
                    name,
                    org.jetbrains.skia.FontStyle.NORMAL,
                )
            }
    if (typeface == null) androidx.compose.ui.text.font.FontFamily.Monospace
    else
        androidx.compose.ui.text.font.FontFamily(
            androidx.compose.ui.text.platform.Typeface(typeface)
        )
}

internal actual fun platformMonospace(): androidx.compose.ui.text.font.FontFamily = monospace

@Composable
internal actual fun platformSymbolPainter(symbol: String, size: Dp, weight: GlyphWeight): Painter? {
    val scale = LocalDensity.current.density
    return remember(symbol, size, weight, scale) {
        SymbolPainters.get(symbol, size.value, weight, scale)
    }
}

/** Renders SF Symbols once per size and weight; Compose tints them like any icon. */
internal object SymbolPainters {
    private val cache = mutableMapOf<String, Painter?>()

    fun get(symbol: String, size: Float, weight: GlyphWeight, scale: Float): Painter? =
        cache.getOrPut("$symbol|$size|$weight|$scale") { render(symbol, size, weight, scale) }

    private fun render(symbol: String, size: Float, weight: GlyphWeight, scale: Float): Painter? {
        val uiWeight =
            when (weight) {
                GlyphWeight.LIGHT -> UIImageSymbolWeightLight
                GlyphWeight.REGULAR -> UIImageSymbolWeightRegular
                GlyphWeight.MEDIUM -> UIImageSymbolWeightMedium
                GlyphWeight.SEMIBOLD -> UIImageSymbolWeightSemibold
                GlyphWeight.BOLD -> UIImageSymbolWeightBold
            }
        val configuration =
            UIImageSymbolConfiguration.configurationWithPointSize((size * .8f).toDouble(), uiWeight)
        val image = UIImage.systemImageNamed(symbol, configuration) ?: return null
        val tinted =
            image.imageWithTintColor(
                UIColor.blackColor,
                UIImageRenderingMode.UIImageRenderingModeAlwaysOriginal,
            )
        val format = UIGraphicsImageRendererFormat.preferredFormat()
        format.scale = scale.toDouble()
        format.opaque = false
        val renderer = UIGraphicsImageRenderer(tinted.size, format)
        val rendered = renderer.imageWithActions { tinted.drawAtPoint(CGPointMake(0.0, 0.0)) }
        val png = UIImagePNGRepresentation(rendered) ?: return null
        val skia = org.jetbrains.skia.Image.makeFromEncoded(png.bytesArray())
        val width = tinted.size.useContents { width }
        if (width <= 0.0) return null
        return BitmapPainter(skia.toComposeImageBitmap())
    }
}

internal fun ByteArray.data(): NSData =
    if (isEmpty()) NSData()
    else usePinned { NSData.create(bytes = it.addressOf(0), length = size.convert()) }

internal fun NSData.bytesArray(): ByteArray =
    ByteArray(length.toInt()).also { result ->
        if (result.isNotEmpty()) result.usePinned { memcpy(it.addressOf(0), bytes, length) }
    }
