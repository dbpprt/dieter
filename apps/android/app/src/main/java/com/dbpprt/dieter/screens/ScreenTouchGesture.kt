package com.dbpprt.dieter.screens

import kotlin.math.hypot
import kotlin.math.max

/** Touch ownership lasts until every finger lifts, including after control is lost. */
internal class ScreenTouchGesture(
    private val slop: Float,
    private val doubleTapSlop: Float,
    private val doubleTapTimeout: Long,
    private val move: (Float, Float) -> Unit,
    private val transform: (Float, Float, Float, Float, Float) -> Unit,
    private val button: (Boolean, Int) -> Unit,
    private val scroll: (Float, Float, Int) -> Unit,
    private val clicked: () -> Unit,
) {
    data class Finger(val id: Int, val x: Float, val y: Float)
    private var previous = emptyList<Finger>()
    private var origin = Finger(0, 0f, 0f)
    private var maxFingers = 0
    private var moved = false
    private var dragging = false
    private var scrolling = false
    private var controlling = false
    private var lastTapTime: Long? = null
    private var lastTap = origin
    val holdingCursor get() = controlling && previous.isNotEmpty()
    val canLongPress get() = controlling && maxFingers == 1 && previous.size == 1 && !moved

    fun begin(finger: Finger, canControl: Boolean) {
        cancel(clearTap = false)
        previous = listOf(finger); origin = finger; maxFingers = 1
        controlling = canControl
    }

    fun fingers(values: List<Finger>) {
        if (previous.isEmpty()) return
        if (dragging) { dragging = false; button(false, 1) }
        if (scrolling) { scrolling = false; scroll(0f, 0f, 4) }
        maxFingers = max(maxFingers, values.size)
        moved = true; lastTapTime = null
        if (values.size == 3 && maxFingers == 3 && controlling) {
            scroll(0f, 0f, 1); scrolling = true
        }
        previous = values
    }

    fun move(values: List<Finger>) {
        if (previous.isEmpty() || values.isEmpty()) return
        // Pointer indices can change when a finger is lifted or replaced.
        if (previous.map { it.id }.toSet() != values.map { it.id }.toSet()) {
            fingers(values); return
        }
        fun x(points: List<Finger>) = points.sumOf { it.x.toDouble() }.toFloat() / points.size
        fun y(points: List<Finger>) = points.sumOf { it.y.toDouble() }.toFloat() / points.size
        val px = x(previous); val py = y(previous)
        val cx = x(values); val cy = y(values)
        when {
            values.size == 1 && maxFingers == 1 && controlling -> {
                if (!moved && hypot(cx - origin.x, cy - origin.y) > slop) {
                    moved = true; lastTapTime = null
                    move(cx - origin.x, cy - origin.y)
                } else if (moved) move(cx - px, cy - py)
            }
            values.size == 2 && maxFingers == 2 -> {
                // Nearly coincident contacts otherwise produce enormous scale jumps.
                fun span(points: List<Finger>) = max(2 * slop, hypot(points[1].x - points[0].x, points[1].y - points[0].y))
                transform(span(values) / span(previous), px, py, cx, cy)
            }
            values.size == 3 && maxFingers == 3 && scrolling -> scroll(cx - px, cy - py, 2)
        }
        previous = values
    }

    fun longPress(): Boolean {
        if (!canLongPress) return false
        dragging = true; moved = true; lastTapTime = null
        button(true, 1)
        return true
    }

    fun end(finger: Finger, time: Long) {
        // ACTION_UP can carry a final position without a preceding MOVE.
        move(listOf(finger))
        if (controlling && maxFingers == 1 && !moved && !dragging) {
            val count = if (lastTapTime?.let { time - it in 0..doubleTapTimeout } == true &&
                hypot(finger.x - lastTap.x, finger.y - lastTap.y) <= doubleTapSlop) 2 else 1
            button(true, count); button(false, count); clicked()
            lastTapTime = if (count == 2) null else time; lastTap = finger
        }
        cancel(clearTap = false)
    }

    fun cancel(clearTap: Boolean = true) {
        val releaseButton = dragging; val endScroll = scrolling
        previous = emptyList(); maxFingers = 0; moved = false
        dragging = false; scrolling = false; controlling = false
        if (clearTap) lastTapTime = null
        // A failed send can synchronously reset the session and call cancel again.
        if (releaseButton) button(false, 1)
        if (endScroll) scroll(0f, 0f, 4)
    }
}

/** Android delivers overlapping DOWN/UP and BUTTON_PRESS/RELEASE events. */
internal class ScreenMouseButtons(
    private val doubleClickTimeout: Long = 300,
    private val doubleClickSlop: Float = 8f,
    private val send: (Int, Boolean, Int) -> Unit,
) {
    private var held = 0
    private var observed = 0
    private val counts = IntArray(5) { 1 }
    private var lastPressTime: Long? = null
    private var lastButton = 0
    private var lastX = 0f
    private var lastY = 0f
    fun update(buttons: Int, canPress: Boolean, newGesture: Boolean = false, time: Long = 0, x: Float = 0f, y: Float = 0f) {
        if (newGesture) { if (held != 0) release(); observed = 0 }
        if (hypot(x - lastX, y - lastY) > doubleClickSlop) lastPressTime = null
        for (index in counts.indices) {
            val mask = 1 shl index
            val wasDown = held and mask != 0
            val isDown = buttons and mask != 0 && (wasDown || (canPress && observed and mask == 0))
            if (buttons and mask != 0 && observed and mask == 0 && !canPress) lastPressTime = null
            if (isDown != wasDown) {
                if (isDown) {
                    held = held or mask
                    counts[index] = if (lastButton == mask && lastPressTime?.let { time - it in 0..doubleClickTimeout } == true) 2 else 1
                    lastPressTime = if (counts[index] == 2) null else time
                    lastButton = mask; lastX = x; lastY = y
                } else held = held and mask.inv()
                send(mask, isDown, counts[index])
            }
        }
        observed = buttons
    }
    val isDragging get() = held != 0
    fun release() {
        val released = held
        held = 0; lastPressTime = null
        for (index in counts.indices) {
            val mask = 1 shl index
            if (released and mask != 0) send(mask, false, counts[index])
        }
    }
}
