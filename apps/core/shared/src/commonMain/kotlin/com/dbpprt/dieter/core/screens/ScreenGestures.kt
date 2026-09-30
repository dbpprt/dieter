package com.dbpprt.dieter.core.screens

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.time.Instant

data class Point(val x: Double, val y: Double) {
    operator fun minus(other: Point) = Point(x - other.x, y - other.y)
    operator fun plus(other: Point) = Point(x + other.x, y + other.y)
    fun distance(other: Point) = hypot(x - other.x, y - other.y)
}

/** Actions a touch gesture produces; the session turns them into input or local zoom. */
interface TrackpadActions {
    fun move(delta: Point)
    fun button(down: Boolean, clicks: Int)
    fun clicked()
    fun scroll(delta: Point, phase: Int)
    fun transform(factor: Double, oldCenter: Point, newCenter: Point)
}

/**
 * A relative trackpad over the remote screen: one finger moves the cursor,
 * a tap clicks (a quick second tap double-clicks), a long press drags, two
 * fingers zoom locally, and three fingers scroll. Ported from Android.
 */
class TouchTrackpad(
    private val slop: Double,
    private val doubleTapSlop: Double,
    private val doubleTapTimeoutMs: Long = 300,
    private val actions: TrackpadActions,
) {
    private var previous: Map<Int, Point> = emptyMap()
    private var origin = Point(0.0, 0.0)
    private var maxFingers = 0
    private var moved = false
    private var dragging = false
    private var scrolling = false
    private var controlling = false
    private var lastTap: Point? = null
    private var lastTapTime: Instant? = null

    val holdingCursor: Boolean get() = controlling && previous.isNotEmpty()

    fun begin(id: Int, position: Point, canControl: Boolean) {
        cancel(clearTap = false)
        previous = mapOf(id to position)
        origin = position
        maxFingers = 1
        controlling = canControl
    }

    /** A finger was added or lifted. Ignored once the gesture was cancelled or ended. */
    fun fingers(current: Map<Int, Point>) {
        if (previous.isEmpty()) return
        endDragAndScroll()
        maxFingers = max(maxFingers, current.size)
        moved = true
        lastTap = null
        if (current.size == 3 && maxFingers == 3 && controlling) {
            scrolling = true
            actions.scroll(Point(0.0, 0.0), SCROLL_BEGAN)
        }
        previous = current
    }

    fun move(current: Map<Int, Point>) {
        if (previous.isEmpty() || current.isEmpty()) return
        // Pointer IDs change when a finger is lifted or replaced.
        if (current.keys != previous.keys) return fingers(current)
        val p = centroid(previous.values)
        val c = centroid(current.values)
        when {
            current.size == 1 && maxFingers == 1 && controlling -> {
                if (!moved) {
                    if (c.distance(origin) > slop) {
                        // Movement between taps breaks a double click.
                        moved = true
                        lastTap = null
                        lastTapTime = null
                        actions.move(c - origin)
                    }
                } else if (c != p) {
                    // A release at the last position adds nothing.
                    actions.move(c - p)
                }
            }
            current.size == 2 && maxFingers == 2 -> {
                val span = { points: Collection<Point> -> max(2 * slop, points.first().distance(points.last())) }
                actions.transform(span(current.values) / span(previous.values), p, c)
            }
            current.size == 3 && maxFingers == 3 && scrolling -> actions.scroll(c - p, SCROLL_CHANGED)
        }
        previous = current
    }

    /** Whether a long press would start a drag now. */
    val canLongPress: Boolean get() = controlling && maxFingers == 1 && previous.size == 1 && !moved && !dragging

    /** Starts a drag; true when it did, so the view can give haptic feedback. */
    fun longPress(): Boolean {
        if (!canLongPress) return false
        dragging = true
        moved = true
        lastTap = null
        lastTapTime = null
        actions.button(down = true, clicks = 1)
        return true
    }

    fun end(id: Int, position: Point, time: Instant) {
        move(mapOf(id to position))
        if (controlling && maxFingers == 1 && !moved && !dragging) {
            val previousTap = lastTap
            val previousTime = lastTapTime
            val double = previousTap != null && previousTime != null && (time - previousTime).inWholeMilliseconds in 0..doubleTapTimeoutMs &&
                position.distance(previousTap) <= doubleTapSlop
            val clicks = if (double) 2 else 1
            actions.button(down = true, clicks = clicks)
            actions.button(down = false, clicks = clicks)
            actions.clicked()
            lastTap = if (double) null else position
            lastTapTime = if (double) null else time
        }
        cancel(clearTap = false)
    }

    /** Ends the gesture; later events of the same touch sequence are ignored until the next [begin]. */
    fun cancel(clearTap: Boolean = true) {
        previous = emptyMap()
        maxFingers = 0
        moved = false
        controlling = false
        if (clearTap) {
            lastTap = null
            lastTapTime = null
        }
        endDragAndScroll()
    }

    private fun endDragAndScroll() {
        if (dragging) {
            dragging = false
            actions.button(down = false, clicks = 1)
        }
        if (scrolling) {
            scrolling = false
            actions.scroll(Point(0.0, 0.0), SCROLL_ENDED)
        }
    }

    private fun centroid(points: Collection<Point>): Point =
        Point(points.sumOf { it.x } / points.size, points.sumOf { it.y } / points.size)

    companion object {
        const val SCROLL_BEGAN = 1
        const val SCROLL_CHANGED = 2
        const val SCROLL_ENDED = 4
    }
}

/**
 * Where the remote desktop sits in the local view: fit, zoom (0.25x to 8x),
 * and pan, plus the remote cursor in normalized coordinates.
 */
class ScreenCanvas {
    var viewWidth = 0.0
        private set
    var viewHeight = 0.0
        private set
    var remoteWidth = 0.0
        private set
    var remoteHeight = 0.0
        private set
    var zoom = 1.0
        private set
    var panX = 0.0
        private set
    var panY = 0.0
        private set
    var cursor = Point(0.5, 0.5)
        private set

    private val fit: Double get() = if (remoteWidth > 0 && remoteHeight > 0) min(viewWidth / remoteWidth, viewHeight / remoteHeight) else 1.0
    val scale: Double get() = fit * zoom
    val left: Double get() = (viewWidth - remoteWidth * scale) / 2 + panX
    val top: Double get() = (viewHeight - remoteHeight * scale) / 2 + panY
    val isFitted: Boolean get() = abs(zoom - 1) < 0.001 && abs(panX) < 0.5 && abs(panY) < 0.5

    /** Resizes the view or remote frame, keeping the desktop point at the view's center. */
    fun resize(viewWidth: Double, viewHeight: Double, remoteWidth: Double, remoteHeight: Double) {
        val center = if (this.remoteWidth > 0 && scale > 0) Point((this.viewWidth / 2 - left) / (this.remoteWidth * scale), (this.viewHeight / 2 - top) / (this.remoteHeight * scale)) else Point(0.5, 0.5)
        this.viewWidth = viewWidth
        this.viewHeight = viewHeight
        this.remoteWidth = remoteWidth
        this.remoteHeight = remoteHeight
        panX = (0.5 - center.x) * remoteWidth * scale
        panY = (0.5 - center.y) * remoteHeight * scale
        clampPan()
    }

    /** Moves the cursor by a view delta and keeps it in view when the desktop overflows. */
    fun move(dx: Double, dy: Double) {
        if (remoteWidth <= 0 || remoteHeight <= 0 || scale <= 0) return
        cursor = Point((cursor.x + dx / (remoteWidth * scale)).coerceIn(0.0, 1.0), (cursor.y + dy / (remoteHeight * scale)).coerceIn(0.0, 1.0))
        val margin = min(24.0, min(viewWidth, viewHeight) / 4)
        if (remoteWidth * scale > viewWidth) {
            val x = left + cursor.x * remoteWidth * scale
            if (x < margin) panX += margin - x else if (x > viewWidth - margin) panX -= x - (viewWidth - margin)
        }
        if (remoteHeight * scale > viewHeight) {
            val y = top + cursor.y * remoteHeight * scale
            if (y < margin) panY += margin - y else if (y > viewHeight - margin) panY -= y - (viewHeight - margin)
        }
        clampPan()
    }

    /** Whether a view point lies on the desktop. */
    fun contains(x: Double, y: Double): Boolean =
        x.isFinite() && y.isFinite() && x >= left && x <= left + remoteWidth * scale && y >= top && y <= top + remoteHeight * scale

    /** Sets zoom and pan directly, for animating between two views. */
    fun setView(zoom: Double, panX: Double, panY: Double) {
        if (!zoom.isFinite() || !panX.isFinite() || !panY.isFinite()) return
        this.zoom = zoom.coerceIn(MIN_ZOOM, MAX_ZOOM)
        this.panX = panX
        this.panY = panY
        clampPan()
    }

    fun setCursor(x: Double, y: Double) {
        cursor = Point(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0))
    }

    /** Pinch zoom around the gesture's center. */
    fun transform(factor: Double, oldCenter: Point, newCenter: Point) {
        if (!factor.isFinite() || factor <= 0 || !oldCenter.x.isFinite() || !newCenter.x.isFinite()) return
        val anchor = Point((oldCenter.x - left) / scale, (oldCenter.y - top) / scale)
        zoom = (zoom * factor).coerceIn(MIN_ZOOM, MAX_ZOOM)
        panX = newCenter.x - anchor.x * scale - (viewWidth - remoteWidth * scale) / 2
        panY = newCenter.y - anchor.y * scale - (viewHeight - remoteHeight * scale) / 2
        clampPan()
    }

    fun reset() {
        zoom = 1.0
        panX = 0.0
        panY = 0.0
        cursor = Point(0.5, 0.5)
    }

    private fun clampPan() {
        fun limit(view: Double, extent: Double) = (view + extent) / 2 - min(48.0, min(view, extent))
        val limitX = max(0.0, limit(viewWidth, remoteWidth * scale))
        val limitY = max(0.0, limit(viewHeight, remoteHeight * scale))
        panX = panX.coerceIn(-limitX, limitX)
        panY = panY.coerceIn(-limitY, limitY)
    }

    companion object {
        const val MIN_ZOOM = 0.25
        const val MAX_ZOOM = 8.0
    }
}
