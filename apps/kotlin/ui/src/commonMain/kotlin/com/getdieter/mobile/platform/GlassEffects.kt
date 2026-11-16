package com.getdieter.mobile.platform

import androidx.compose.ui.graphics.RenderEffect

/**
 * A liquid glass surface's lens, in pixels of the surface's padded backdrop recording: the
 * surface's rectangle and corner radius, how wide its bent rim is ([bezel]), how far the rim pulls
 * the picture ([strength]) and how much it splits colors at the edge ([dispersion]).
 */
internal class GlassLens(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
    val radius: Float,
    val bezel: Float,
    val strength: Float,
    val dispersion: Float,
    /** Magnification of the whole surface, 1 for none: a lens rather than a pane. */
    val zoom: Float = 1f,
)

/** Builds the backdrop effect of one glass surface; implementations cache compiled shaders. */
internal interface GlassEffects {
    /**
     * Blur and saturate the backdrop, and bend it at the rim when [lens] is given and the platform
     * runs shaders. Null where the platform cannot filter a layer at all.
     */
    fun effect(blur: Float, saturation: Float, lens: GlassLens?): RenderEffect?
}

/** Android 12+ blurs, Android 13+ and Skia also refract; older Android draws a solid tint. */
internal expect fun createGlassEffects(): GlassEffects

/**
 * The rim lens, shared by Android (AGSL) and Skia (SkSL): inside a rounded rectangle's bezel the
 * backdrop is sampled closer to the centre along the edge's normal, following a circular profile,
 * so the rim magnifies and bends what passes under it the way a thick drop of glass does. Red and
 * blue sample slightly apart at the rim. Saturation lifts the whole surface, and zoom above 1
 * magnifies everything beneath it, as the lifted selection lens does.
 */
internal const val GLASS_LENS_SHADER =
    """
uniform shader content;
uniform float4 rect;
uniform float radius;
uniform float bezel;
uniform float strength;
uniform float dispersion;
uniform float saturation;
uniform float zoom;

float roundRect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + float2(r, r);
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0, 0.0))) - r;
}

half4 vivid(half4 c) {
    half l = dot(c.rgb, half3(0.2126, 0.7152, 0.0722));
    return half4(mix(half3(l, l, l), c.rgb, half(saturation)), c.a);
}

half4 main(float2 coord) {
    float2 halfSize = rect.zw * 0.5;
    float2 center = rect.xy + halfSize;
    float2 p = coord - center;
    float r = min(radius, min(halfSize.x, halfSize.y));
    float d = roundRect(p, halfSize, r);
    if (d > 0.0) {
        return vivid(content.eval(coord));
    }
    float2 base = center + p / max(zoom, 0.01);
    float edge = bezel > 0.0 ? 1.0 - clamp(-d / bezel, 0.0, 1.0) : 0.0;
    if (edge <= 0.0) {
        return vivid(content.eval(base));
    }
    float e = 0.75;
    float2 g = float2(
        roundRect(p + float2(e, 0.0), halfSize, r) - roundRect(p - float2(e, 0.0), halfSize, r),
        roundRect(p + float2(0.0, e), halfSize, r) - roundRect(p - float2(0.0, e), halfSize, r));
    float len = length(g);
    float2 n = len > 0.0001 ? g / len : float2(0.0, 0.0);
    float bend = 1.0 - sqrt(max(1.0 - edge * edge, 0.0));
    float2 offset = -n * bend * strength;
    half4 c = content.eval(base + offset);
    if (dispersion > 0.0) {
        half red = content.eval(base + offset * (1.0 + dispersion)).r;
        half blue = content.eval(base + offset * (1.0 - dispersion)).b;
        c = half4(red, c.g, blue, c.a);
    }
    return vivid(c);
}
"""
