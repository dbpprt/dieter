package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.client.v1.ScreenButton
import com.dbpprt.dieter.client.v1.ScreenCommand
import com.dbpprt.dieter.client.v1.ScreenKey
import com.dbpprt.dieter.client.v1.ScreenPointer
import com.dbpprt.dieter.client.v1.ScreenScroll
import com.dbpprt.dieter.client.v1.ScreenText
import com.dbpprt.dieter.client.v1.Step
import kotlin.time.Instant

/**
 * One-shot input a touch toolbar arms: the next click is a right click, and
 * armed [Modifiers] apply to the next key or text and then release. Pointer
 * buttons and scrolls carry the armed modifiers without consuming them.
 */
class ArmedInput {
    var rightClick = false
        private set

    /** Armed [Modifiers] bits. */
    var modifiers = 0
        private set

    fun toggleRightClick() {
        rightClick = !rightClick
    }

    fun toggleModifier(mask: Int) {
        modifiers = modifiers xor mask
    }

    /** The modifiers key [hid] carries with the [held] ones; releasing a key that is not a modifier consumes the armed ones. */
    fun key(hid: Int, down: Boolean, held: Int = 0): Int {
        val combined = modifiers or held
        if (!down && hid !in MODIFIER_KEYS) modifiers = 0
        return combined
    }

    /** The modifiers committed text or a toolbar key press carries; it consumes them. */
    fun consume(): Int = modifiers.also { modifiers = 0 }

    /** The button the next click presses. */
    fun button(): RemoteDesktopPointerButton.Button =
        if (rightClick) RemoteDesktopPointerButton.Button.BUTTON_RIGHT else RemoteDesktopPointerButton.Button.BUTTON_LEFT

    /** A click completed; an armed right click is used up. */
    fun clicked() {
        rightClick = false
    }

    fun reset() {
        rightClick = false
        modifiers = 0
    }

    companion object {
        /** HID usages of Control, Shift, Option, and Command, left and right. */
        val MODIFIER_KEYS = 224..231
    }
}

/**
 * A touch screen's input to a shared screen: fingers drive a [TouchTrackpad]
 * over [canvas], and gestures, hardware pointers, keys, and text become
 * [ScreenCommand]s for [scope] with [armed]'s one-shot right click and
 * modifiers applied. [send] receives the commands in order on the caller's
 * thread. Coordinates are view units.
 *
 * A platform that reports fingers one at a time (iOS) calls [down], [moved],
 * and [up]; one that reports every finger on each event (Android) calls
 * [begin], [fingers], [move], and [end]. [scrollScale] converts view units to
 * the points scrolls are sent in (Android passes 1 / density); [clicked]
 * follows each tap's click, e.g. for accessibility.
 */
class TouchScreenInput(
    private val scope: String,
    slop: Double,
    doubleTapSlop: Double,
    doubleTapTimeoutMs: Long,
    /** Where the desktop sits in the view; a host that keeps it across views passes its own. */
    val canvas: ScreenCanvas = ScreenCanvas(),
    private val scrollScale: Double = 1.0,
    private val clicked: () -> Unit = {},
    private val send: (ScreenCommand) -> Unit,
) {
    val armed = ArmedInput()
    private val fingers = LinkedHashMap<Int, Point>()

    /**
     * [Modifiers] a sticky toolbar holds down on the host until they are
     * toggled off (Android); pointer buttons carry them with the armed ones.
     */
    var heldModifiers = 0

    /** The button a gesture pressed, so its release matches even if the toolbar changed meanwhile. */
    private var pressed: RemoteDesktopPointerButton.Button? = null

    private val trackpad = TouchTrackpad(
        slop, doubleTapSlop, doubleTapTimeoutMs,
        object : TrackpadActions {
            override fun move(delta: Point) {
                canvas.move(delta.x, delta.y)
                pointer()
            }

            override fun button(down: Boolean, clicks: Int) = press(down, clicks)
            override fun clicked() = this@TouchScreenInput.clicked()
            override fun scroll(delta: Point, phase: Int) =
                this@TouchScreenInput.scroll(delta.x * scrollScale, delta.y * scrollScale, phase, momentum = 0)
            override fun transform(factor: Double, oldCenter: Point, newCenter: Point) = canvas.transform(factor, oldCenter, newCenter)
        },
    )

    /** The cursor is held by a finger, e.g. for a drag. */
    val holdingCursor: Boolean get() = trackpad.holdingCursor

    /** Whether a long press would start a drag now. */
    val canLongPress: Boolean get() = trackpad.canLongPress

    /** A finger touched down; [canControl] says whether input may reach the host. */
    fun down(id: Int, x: Double, y: Double, canControl: Boolean) {
        val first = fingers.isEmpty()
        fingers[id] = Point(x, y)
        if (first) trackpad.begin(id, Point(x, y), canControl) else trackpad.fingers(fingers.toMap())
    }

    fun moved(id: Int, x: Double, y: Double) {
        if (id !in fingers) return
        fingers[id] = Point(x, y)
        trackpad.move(fingers.toMap())
    }

    /** A finger lifted at [time]; the last one ends the gesture, which may click. */
    fun up(id: Int, x: Double, y: Double, time: Instant) {
        if (id !in fingers) return
        if (fingers.size == 1) {
            fingers.clear()
            trackpad.end(id, Point(x, y), time)
        } else {
            fingers.remove(id)
            trackpad.fingers(fingers.toMap())
        }
    }

    /** The system took the touches: the gesture ends and the host releases what it holds. */
    fun cancel() {
        cancelGesture()
        releaseInput()
    }

    /** Ends the gesture, releasing a drag's button; the host keeps other held input. */
    fun cancelGesture() {
        fingers.clear()
        trackpad.cancel()
    }

    // --- Every finger per event --------------------------------------------------------

    /** The first finger touched down; a gesture still in progress is dropped. */
    fun begin(id: Int, x: Double, y: Double, canControl: Boolean) {
        fingers.clear()
        fingers[id] = Point(x, y)
        trackpad.begin(id, Point(x, y), canControl)
    }

    /** A finger was added or lifted; [current] are those still down. */
    fun fingers(current: Map<Int, Point>) {
        replaceFingers(current)
        trackpad.fingers(current)
    }

    /** The fingers down moved to [current]. */
    fun move(current: Map<Int, Point>) {
        replaceFingers(current)
        trackpad.move(current)
    }

    /** The last finger lifted at [time]; the gesture ends and may click. */
    fun end(id: Int, x: Double, y: Double, time: Instant) {
        fingers.clear()
        trackpad.end(id, Point(x, y), time)
    }

    private fun replaceFingers(current: Map<Int, Point>) {
        fingers.clear()
        fingers.putAll(current)
    }

    /** Starts a drag; true when it did, so the view can give haptic feedback. */
    fun longPress(): Boolean = trackpad.longPress()

    /** Moves the cursor to the desktop point under a hardware pointer; false when the point is off the desktop. */
    fun point(x: Double, y: Double, clamp: Boolean = false): Boolean {
        val target = canvas.normalized(x, y, clamp) ?: return false
        canvas.setCursor(target.x, target.y)
        pointer()
        return true
    }

    /** A hardware pointer's button, or a toolbar's click, at the cursor. */
    fun button(button: RemoteDesktopPointerButton.Button, down: Boolean, clicks: Int) =
        send(ScreenCommand(scope = scope, button = ScreenButton(button, down, clicks, canvas.cursor.x, canvas.cursor.y, buttonModifiers)))

    fun scroll(dx: Double, dy: Double, phase: Int, momentum: Int) =
        send(ScreenCommand(scope = scope, scroll = ScreenScroll(dx, dy, phase, momentum, armed.modifiers, precise = true)))

    /** A hardware key by HID usage with the modifiers it holds; armed modifiers join until a key completes. */
    fun key(hid: Int, down: Boolean, repeat: Boolean, held: Int) =
        send(ScreenCommand(scope = scope, key = ScreenKey(hid, down, repeat, armed.key(hid, down, held))))

    /** A toolbar key: pressed and released with the armed modifiers, which it consumes. */
    fun press(hid: Int) {
        val modifiers = armed.consume()
        send(ScreenCommand(scope = scope, key = ScreenKey(hid, down = true, modifiers = modifiers)))
        send(ScreenCommand(scope = scope, key = ScreenKey(hid, down = false, modifiers = modifiers)))
    }

    /** Committed text with the armed modifiers, which it consumes; the core sends a shortcut as a key stroke. */
    fun text(value: String) {
        if (value.isEmpty()) return
        send(ScreenCommand(scope = scope, text = ScreenText(value, armed.consume())))
    }

    /** Releases every held key and button on the host and disarms the toolbar. */
    fun releaseInput() {
        pressed = null
        armed.reset()
        send(ScreenCommand(scope = scope, release_input = Step()))
    }

    private fun pointer() = send(ScreenCommand(scope = scope, pointer = ScreenPointer(canvas.cursor.x, canvas.cursor.y)))

    private fun press(down: Boolean, clicks: Int) {
        val button = if (down) armed.button().also { pressed = it } else pressed ?: return
        if (!down) {
            pressed = null
            armed.clicked()
        }
        // A right click is single, even from a double tap.
        val count = if (button == RemoteDesktopPointerButton.Button.BUTTON_LEFT) clicks else 1
        send(ScreenCommand(scope = scope, button = ScreenButton(button, down, count, canvas.cursor.x, canvas.cursor.y, buttonModifiers)))
    }

    private val buttonModifiers: Int get() = armed.modifiers or heldModifiers
}
