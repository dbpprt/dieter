package com.dbpprt.dieter.screens

import kotlin.math.*

/** Platform-independent canvas geometry and relative trackpad coordinates. */
class ScreenCanvasModel {
    var viewportWidth = 1f; private set
    var viewportHeight = 1f; private set
    var remoteWidth = 1f; private set
    var remoteHeight = 1f; private set
    var zoom = 1f; private set
    var panX = 0f; private set
    var panY = 0f; private set
    var cursorX = .5f; private set
    var cursorY = .5f; private set
    val isFitted get() = abs(zoom - 1f) < .001f && abs(panX) < .5f && abs(panY) < .5f
    val fit get() = min(viewportWidth / remoteWidth, viewportHeight / remoteHeight)
    val scale get() = fit * zoom
    val left get() = (viewportWidth - remoteWidth * scale) / 2 + panX
    val top get() = (viewportHeight - remoteHeight * scale) / 2 + panY

    fun resize(width: Int, height: Int, remoteWidth: Int, remoteHeight: Int) {
        // Preserve the desktop point at the viewport center across keyboard,
        // rotation and decoder resolution changes. Encoded pixels are not zoom levels.
        val centerX = (viewportWidth / 2 - left) / (this.remoteWidth * scale)
        val centerY = (viewportHeight / 2 - top) / (this.remoteHeight * scale)
        viewportWidth = width.coerceAtLeast(1).toFloat(); viewportHeight = height.coerceAtLeast(1).toFloat()
        this.remoteWidth = remoteWidth.coerceAtLeast(1).toFloat(); this.remoteHeight = remoteHeight.coerceAtLeast(1).toFloat()
        panX = (.5f - centerX) * this.remoteWidth * scale
        panY = (.5f - centerY) * this.remoteHeight * scale
        clampPan()
    }
    fun reset() { zoom = 1f; panX = 0f; panY = 0f }
    fun setView(zoom: Float, panX: Float, panY: Float) {
        if (!zoom.isFinite() || !panX.isFinite() || !panY.isFinite()) return
        this.zoom = zoom.coerceIn(MIN_ZOOM, MAX_ZOOM); this.panX = panX; this.panY = panY
        clampPan()
    }
    fun cursor(x: Float, y: Float) {
        if (!x.isFinite() || !y.isFinite()) return
        cursorX = x.coerceIn(0f, 1f); cursorY = y.coerceIn(0f, 1f)
    }
    fun contains(x: Float, y: Float) = x.isFinite() && y.isFinite() &&
        x >= left && x <= left + remoteWidth * scale && y >= top && y <= top + remoteHeight * scale
    fun move(dx: Float, dy: Float) {
        if (!dx.isFinite() || !dy.isFinite()) return
        cursor(cursorX + dx / (remoteWidth * scale), cursorY + dy / (remoteHeight * scale))
        // Keep the cursor in view while moving across a magnified desktop.
        val margin = 24f.coerceAtMost(min(viewportWidth, viewportHeight) / 4)
        val x = left + cursorX * remoteWidth * scale; val y = top + cursorY * remoteHeight * scale
        // Do not nudge a fully visible desktop when pointing at a corner.
        if (left < 0 || left + remoteWidth * scale > viewportWidth)
            panX += x.coerceIn(margin, viewportWidth - margin) - x
        if (top < 0 || top + remoteHeight * scale > viewportHeight)
            panY += y.coerceIn(margin, viewportHeight - margin) - y
        clampPan()
    }
    fun transform(factor: Float, oldX: Float, oldY: Float, newX: Float, newY: Float) {
        if (!factor.isFinite() || factor <= 0 || !oldX.isFinite() || !oldY.isFinite() || !newX.isFinite() || !newY.isFinite()) return
        val anchorX = (oldX - left) / scale; val anchorY = (oldY - top) / scale
        zoom = (zoom * factor).coerceIn(MIN_ZOOM, MAX_ZOOM)
        panX = newX - anchorX * scale - (viewportWidth - remoteWidth * scale) / 2
        panY = newY - anchorY * scale - (viewportHeight - remoteHeight * scale) / 2
        clampPan()
    }
    private fun clampPan() {
        // A canvas may move through its letterbox area at any zoom. Only keep
        // a small edge visible so the desktop cannot be lost completely.
        fun limit(viewport: Float, extent: Float): Float =
            (viewport + extent) / 2 - min(48f, min(viewport, extent))
        val x = limit(viewportWidth, remoteWidth * scale)
        val y = limit(viewportHeight, remoteHeight * scale)
        panX = panX.coerceIn(-x, x); panY = panY.coerceIn(-y, y)
    }

    companion object {
        const val MIN_ZOOM = .25f
        const val MAX_ZOOM = 8f
    }
}
