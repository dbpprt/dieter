package com.dbpprt.dieter.shared

import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.client.v1.ScreenCommand
import com.dbpprt.dieter.core.screens.Point
import com.dbpprt.dieter.core.screens.ScreenCanvas
import com.dbpprt.dieter.core.screens.TouchScreenInput
import kotlin.time.Instant
import platform.Foundation.NSData

/** Receives each encoded `dieter.client.v1.ScreenCommand` touch input produces, in order and on the caller's thread; dispatch it. */
interface SharedTouchScreenSink {
    fun send(command: NSData)
}

/**
 * Touch input for one shared screen view: the core's trackpad gestures (one
 * finger moves the cursor, a tap clicks, a long press drags, two fingers
 * zoom and pan locally, three fingers scroll) over its canvas geometry
 * (aspect fit, letterbox, zoom, and pan), with the toolbar's one-shot right
 * click and armed modifiers. Commands carry [scope], the screen surface's
 * key. Confine an instance to the main thread. Coordinates are view points;
 * modifiers are bits (Shift 1, Control 2, Option 4, Command 8).
 */
class SharedTouchScreen(scope: String, slop: Double, doubleTapSlop: Double, doubleTapTimeoutMillis: Long, sink: SharedTouchScreenSink) {
    private val input = TouchScreenInput(scope, slop, doubleTapSlop, doubleTapTimeoutMillis) { sink.send(ScreenCommand.ADAPTER.encode(it).toNSData()) }
    private val canvas get() = input.canvas

    // --- Fingers ---------------------------------------------------------------------

    /** [id] identifies the finger until it lifts; [canControl] whether input may reach the host. */
    fun touchDown(id: Int, x: Double, y: Double, canControl: Boolean) = input.down(id, x, y, canControl)

    fun touchMoved(id: Int, x: Double, y: Double) = input.moved(id, x, y)

    /** [atMillis] is the touch's time on any millisecond clock; it tells a double tap. */
    fun touchUp(id: Int, x: Double, y: Double, atMillis: Long) = input.up(id, x, y, Instant.fromEpochMilliseconds(atMillis))

    /** The system took the touches; held input is released. */
    fun touchesCancelled() = input.cancel()

    /** Whether a long press would start a drag now; poll from the long-press timer. */
    val canLongPress: Boolean get() = input.canLongPress

    /** Starts a drag; true when it did, for haptic feedback. */
    fun longPress(): Boolean = input.longPress()

    val holdingCursor: Boolean get() = input.holdingCursor

    // --- Hardware pointer, keys, and text ----------------------------------------------

    /** Moves the cursor under a hardware pointer; false off the desktop unless [clamp]. */
    fun pointAt(x: Double, y: Double, clamp: Boolean): Boolean = input.point(x, y, clamp)

    /** [button] is a `dieter.v1.RemoteDesktopPointerButton.Button` value, pressed at the cursor. */
    fun pointerButton(button: Int, down: Boolean, clicks: Int) =
        input.button(RemoteDesktopPointerButton.Button.fromValue(button) ?: RemoteDesktopPointerButton.Button.BUTTON_LEFT, down, clicks)

    fun scroll(dx: Double, dy: Double, phase: Int, momentum: Int) = input.scroll(dx, dy, phase, momentum)

    /** A hardware key by USB HID usage with the [modifiers] it holds. */
    fun key(hid: Int, down: Boolean, repeat: Boolean, modifiers: Int) = input.key(hid, down, repeat, modifiers)

    /** A toolbar key, pressed and released with the armed modifiers. */
    fun press(hid: Int) = input.press(hid)

    /** Text the keyboard committed, with the armed modifiers. */
    fun text(text: String) = input.text(text)

    /** Releases every held key and button on the host and disarms the toolbar. */
    fun releaseInput() = input.releaseInput()

    // --- Toolbar -----------------------------------------------------------------------

    val rightClickArmed: Boolean get() = input.armed.rightClick

    fun toggleRightClick() = input.armed.toggleRightClick()

    val armedModifiers: Int get() = input.armed.modifiers

    fun toggleModifier(mask: Int) = input.armed.toggleModifier(mask)

    // --- Canvas ------------------------------------------------------------------------

    /** The view's size and the remote frame's, keeping the desktop point at the view's center. */
    fun resize(viewWidth: Double, viewHeight: Double, remoteWidth: Double, remoteHeight: Double) =
        canvas.resize(viewWidth, viewHeight, remoteWidth, remoteHeight)

    /** The host's cursor, normalized, as the screen slice reports it. */
    fun setCursor(x: Double, y: Double) = canvas.setCursor(x, y)

    /** Zooms by [factor] around view point ([centerX], [centerY]), e.g. for zoom buttons. */
    fun zoomBy(factor: Double, centerX: Double, centerY: Double) {
        val center = Point(centerX, centerY)
        canvas.transform(factor, center, center)
    }

    /** Sets zoom and pan directly, for animating between two views. */
    fun setView(zoom: Double, panX: Double, panY: Double) = canvas.setView(zoom, panX, panY)

    /** Fits the desktop to the view again; the cursor stays. */
    fun fit() {
        val cursor = canvas.cursor
        canvas.reset()
        canvas.setCursor(cursor.x, cursor.y)
    }

    val zoom: Double get() = canvas.zoom
    val panX: Double get() = canvas.panX
    val panY: Double get() = canvas.panY
    val isFitted: Boolean get() = canvas.isFitted

    /** The desktop's frame in the view, letterboxed, zoomed, and panned. */
    val contentX: Double get() = canvas.left
    val contentY: Double get() = canvas.top
    val contentWidth: Double get() = canvas.remoteWidth * canvas.scale
    val contentHeight: Double get() = canvas.remoteHeight * canvas.scale

    /** The cursor, normalized. */
    val cursorX: Double get() = canvas.cursor.x
    val cursorY: Double get() = canvas.cursor.y

    /** Where the cursor is drawn in the view. */
    val cursorViewX: Double get() = canvas.displayed(canvas.cursor.x, canvas.cursor.y).x
    val cursorViewY: Double get() = canvas.displayed(canvas.cursor.x, canvas.cursor.y).y

    val minimumZoom: Double get() = ScreenCanvas.MIN_ZOOM
    val maximumZoom: Double get() = ScreenCanvas.MAX_ZOOM
}
