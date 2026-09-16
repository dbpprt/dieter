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
    val fit get() = min(viewportWidth / remoteWidth, viewportHeight / remoteHeight)
    val scale get() = fit * zoom
    val left get() = (viewportWidth - remoteWidth * scale) / 2 + panX
    val top get() = (viewportHeight - remoteHeight * scale) / 2 + panY

    fun resize(width: Int, height: Int, remoteWidth: Int, remoteHeight: Int) {
        viewportWidth = width.coerceAtLeast(1).toFloat(); viewportHeight = height.coerceAtLeast(1).toFloat()
        this.remoteWidth = remoteWidth.coerceAtLeast(1).toFloat(); this.remoteHeight = remoteHeight.coerceAtLeast(1).toFloat()
        clampPan()
    }
    fun reset() { zoom = 1f; panX = 0f; panY = 0f }
    fun cursor(x: Float, y: Float) { cursorX = x.coerceIn(0f, 1f); cursorY = y.coerceIn(0f, 1f) }
    fun move(dx: Float, dy: Float) {
        cursor(cursorX + dx / (remoteWidth * scale), cursorY + dy / (remoteHeight * scale))
        // Keep the cursor in view while moving across a magnified desktop.
        val margin = 24f.coerceAtMost(min(viewportWidth, viewportHeight) / 4)
        val x = left + cursorX * remoteWidth * scale; val y = top + cursorY * remoteHeight * scale
        panX += x.coerceIn(margin, viewportWidth - margin) - x
        panY += y.coerceIn(margin, viewportHeight - margin) - y
        clampPan()
    }
    fun transform(factor: Float, oldX: Float, oldY: Float, newX: Float, newY: Float) {
        val anchorX = (oldX - left) / scale; val anchorY = (oldY - top) / scale
        zoom = (zoom * factor).coerceIn(1f, 6f)
        panX = newX - anchorX * scale - (viewportWidth - remoteWidth * scale) / 2
        panY = newY - anchorY * scale - (viewportHeight - remoteHeight * scale) / 2
        clampPan()
    }
    private fun clampPan() {
        val x = max(0f, (remoteWidth * scale - viewportWidth) / 2)
        val y = max(0f, (remoteHeight * scale - viewportHeight) / 2)
        panX = panX.coerceIn(-x, x); panY = panY.coerceIn(-y, y)
    }
}
