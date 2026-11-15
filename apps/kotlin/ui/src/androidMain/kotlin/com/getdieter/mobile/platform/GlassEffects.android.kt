package com.getdieter.mobile.platform

import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.graphics.asComposeRenderEffect

internal actual fun createGlassEffects(): GlassEffects =
    when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> LensGlassEffects()
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> BlurGlassEffects()
        else -> NoGlassEffects
    }

private object NoGlassEffects : GlassEffects {
    override fun effect(blur: Float, saturation: Float, lens: GlassLens?): RenderEffect? = null
}

/** Android 12: blur and a saturation matrix, no shader. */
@RequiresApi(Build.VERSION_CODES.S)
private class BlurGlassEffects : GlassEffects {
    override fun effect(blur: Float, saturation: Float, lens: GlassLens?): RenderEffect {
        val matrix = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(saturation) })
        val saturated = android.graphics.RenderEffect.createColorFilterEffect(matrix)
        if (blur <= 0f) return saturated.asComposeRenderEffect()
        val blurred =
            android.graphics.RenderEffect.createBlurEffect(blur, blur, Shader.TileMode.CLAMP)
        return android.graphics.RenderEffect.createChainEffect(saturated, blurred)
            .asComposeRenderEffect()
    }
}

/** Android 13+: blur, then the AGSL rim lens (which also saturates). */
@RequiresApi(Build.VERSION_CODES.TIRAMISU)
private class LensGlassEffects : GlassEffects {
    private val fallback = BlurGlassEffects()
    // Compiling AGSL costs milliseconds: one shader per surface, its uniforms set per effect.
    private val shader by lazy { RuntimeShader(GLASS_LENS_SHADER) }

    override fun effect(blur: Float, saturation: Float, lens: GlassLens?): RenderEffect {
        if (lens == null) return fallback.effect(blur, saturation, null)
        shader.setFloatUniform("rect", lens.left, lens.top, lens.width, lens.height)
        shader.setFloatUniform("radius", lens.radius)
        shader.setFloatUniform("bezel", lens.bezel)
        shader.setFloatUniform("strength", lens.strength)
        shader.setFloatUniform("dispersion", lens.dispersion)
        shader.setFloatUniform("saturation", saturation)
        shader.setFloatUniform("zoom", lens.zoom)
        val bent = android.graphics.RenderEffect.createRuntimeShaderEffect(shader, "content")
        if (blur <= 0f) return bent.asComposeRenderEffect()
        val blurred =
            android.graphics.RenderEffect.createBlurEffect(blur, blur, Shader.TileMode.CLAMP)
        return android.graphics.RenderEffect.createChainEffect(bent, blurred)
            .asComposeRenderEffect()
    }
}
