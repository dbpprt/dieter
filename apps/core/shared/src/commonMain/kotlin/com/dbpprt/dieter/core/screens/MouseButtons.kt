package com.dbpprt.dieter.core.screens

import kotlin.math.hypot

/**
 * Pointer buttons for the remote desktop. Platforms report overlapping
 * press events (Android's DOWN/UP and BUTTON_PRESS/RELEASE), so a button
 * goes down once per press, only when [update] says it may, and a second
 * press of the same button within [doubleClickTimeout] ms and
 * [doubleClickSlop] px counts as a double click. [send] receives the button
 * mask (1 primary, 2 secondary, 4 tertiary, …), whether it is down, and the
 * click count.
 */
class MouseButtons(
    private val doubleClickTimeout: Long = 300,
    private val doubleClickSlop: Float = 8f,
    private val send: (mask: Int, down: Boolean, count: Int) -> Unit,
) {
    private var held = 0
    private var observed = 0
    private val counts = IntArray(5) { 1 }
    private var lastPressTime: Long? = null
    private var lastButton = 0
    private var lastX = 0f
    private var lastY = 0f

    /** Applies the platform's current [buttons] mask; a button may go down only when [canPress]. */
    fun update(buttons: Int, canPress: Boolean, newGesture: Boolean = false, time: Long = 0, x: Float = 0f, y: Float = 0f) {
        if (newGesture) {
            if (held != 0) release()
            observed = 0
        }
        if (hypot(x - lastX, y - lastY) > doubleClickSlop) lastPressTime = null
        for (index in counts.indices) {
            val mask = 1 shl index
            val wasDown = held and mask != 0
            val isDown = buttons and mask != 0 && (wasDown || (canPress && observed and mask == 0))
            if (buttons and mask != 0 && observed and mask == 0 && !canPress) lastPressTime = null
            if (isDown == wasDown) continue
            if (isDown) {
                held = held or mask
                counts[index] = if (lastButton == mask && lastPressTime?.let { time - it in 0..doubleClickTimeout } == true) 2 else 1
                lastPressTime = if (counts[index] == 2) null else time
                lastButton = mask
                lastX = x
                lastY = y
            } else {
                held = held and mask.inv()
            }
            send(mask, isDown, counts[index])
        }
        observed = buttons
    }

    val isDragging: Boolean get() = held != 0

    /** Releases every held button, e.g. when the gesture is cancelled. */
    fun release() {
        val released = held
        held = 0
        lastPressTime = null
        for (index in counts.indices) {
            val mask = 1 shl index
            if (released and mask != 0) send(mask, false, counts[index])
        }
    }
}
