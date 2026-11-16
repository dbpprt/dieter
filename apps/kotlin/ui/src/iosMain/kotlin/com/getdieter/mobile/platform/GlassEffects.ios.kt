package com.getdieter.mobile.platform

import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.RenderEffect

/** iOS draws its bars natively (UIKit Liquid Glass); shared glass surfaces only blur here. */
internal actual fun createGlassEffects(): GlassEffects =
    object : GlassEffects {
        override fun effect(blur: Float, saturation: Float, lens: GlassLens?): RenderEffect? =
            if (blur > 0f) BlurEffect(blur, blur) else null
    }
