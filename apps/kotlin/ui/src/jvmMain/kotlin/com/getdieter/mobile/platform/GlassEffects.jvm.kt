package com.getdieter.mobile.platform

import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.graphics.asComposeRenderEffect
import org.jetbrains.skia.FilterTileMode
import org.jetbrains.skia.ImageFilter
import org.jetbrains.skia.RuntimeEffect
import org.jetbrains.skia.RuntimeShaderBuilder

/** Skia runs the same lens as SkSL, so offscreen UI tests render the glass as Android 13 does. */
internal actual fun createGlassEffects(): GlassEffects = SkiaGlassEffects

private object SkiaGlassEffects : GlassEffects {
    private val lens by lazy { RuntimeEffect.makeForShader(GLASS_LENS_SHADER) }

    override fun effect(blur: Float, saturation: Float, lens: GlassLens?): RenderEffect {
        val blurred =
            if (blur > 0f) ImageFilter.makeBlur(blur / 2f, blur / 2f, FilterTileMode.CLAMP)
            else null
        val builder = RuntimeShaderBuilder(this.lens)
        val shape = lens ?: GlassLens(0f, 0f, 1f, 1f, 0f, 0f, 0f, 0f)
        builder.uniform("rect", shape.left, shape.top, shape.width, shape.height)
        builder.uniform("radius", shape.radius)
        builder.uniform("bezel", shape.bezel)
        builder.uniform("strength", shape.strength)
        builder.uniform("dispersion", shape.dispersion)
        builder.uniform("saturation", saturation)
        builder.uniform("zoom", shape.zoom)
        return ImageFilter.makeRuntimeShader(builder, "content", blurred).asComposeRenderEffect()
    }
}
