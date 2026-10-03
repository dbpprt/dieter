package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton.Button
import com.dbpprt.dieter.client.v1.ScreenButton
import com.dbpprt.dieter.client.v1.ScreenCommand
import com.dbpprt.dieter.client.v1.ScreenKey
import com.dbpprt.dieter.client.v1.ScreenText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant

/** Touch input as iOS hands it to the core; the geometry and toolbar cases are ported from the iOS screen tests. */
class TouchScreenInputTest {
    private val commands = mutableListOf<ScreenCommand>()
    private val input = TouchScreenInput("screen", slop = 10.0, doubleTapSlop = 40.0, doubleTapTimeoutMs = 300) { commands += it }

    private fun tap(x: Double = 150.0, y: Double = 150.0, atMillis: Long = 1_000) {
        input.down(1, x, y, canControl = true)
        input.up(1, x, y, Instant.fromEpochMilliseconds(atMillis))
    }

    private fun buttons() = commands.mapNotNull { it.button }.map { Triple(it.button, it.down, it.clicks) }

    @Test
    fun coordinatesRespectAspectFitLetterboxing() {
        val canvas = ScreenCanvas().apply { resize(300.0, 300.0, 300.0, 150.0) }
        assertEquals(listOf(0.0, 75.0, 1.0), listOf(canvas.left, canvas.top, canvas.scale))
        assertEquals(Point(0.5, 0.5), canvas.normalized(150.0, 150.0))
        assertNull(canvas.normalized(150.0, 20.0), "the letterbox is off the desktop")
        assertEquals(Point(1.0, 0.0), canvas.normalized(400.0, -20.0, clamp = true))
        assertNull(ScreenCanvas().normalized(10.0, 10.0), "no frame yet")
    }

    @Test
    fun zoomedPointsMapToTheVisibleRemotePoint() {
        val canvas = ScreenCanvas().apply { resize(300.0, 300.0, 300.0, 150.0) }
        canvas.setView(2.0, 150.0, 0.0)
        assertEquals(Point(0.25, 0.5), canvas.normalized(150.0, 150.0))
        canvas.setView(2.0, -150.0, 0.0)
        assertEquals(Point(0.75, 0.5), canvas.normalized(150.0, 150.0))
        assertEquals(Point(150.0, 150.0), canvas.displayed(0.75, 0.5), "the cursor is drawn where the point shows")
    }

    @Test
    fun zoomAndPanStayBounded() {
        val canvas = ScreenCanvas().apply { resize(300.0, 300.0, 300.0, 150.0) }
        canvas.setView(0.1, 0.0, 0.0)
        assertEquals(ScreenCanvas.MIN_ZOOM, canvas.zoom)
        canvas.setView(20.0, 0.0, 0.0)
        assertEquals(ScreenCanvas.MAX_ZOOM, canvas.zoom)
        canvas.setView(2.0, 1_000.0, 0.0)
        assertEquals(402.0, canvas.panX, "the desktop keeps a 48 point edge in view")
        canvas.reset()
        assertTrue(canvas.isFitted)
    }

    @Test
    fun aTapClicksAtTheCursorAndAFingerMovesIt() {
        input.canvas.resize(300.0, 300.0, 300.0, 150.0)
        tap()
        assertEquals(listOf(Triple(Button.BUTTON_LEFT, true, 1), Triple(Button.BUTTON_LEFT, false, 1)), buttons())
        assertEquals(ScreenButton(Button.BUTTON_LEFT, true, 1, 0.5, 0.5, 0), commands.first().button)
        assertTrue(commands.all { it.scope == "screen" })

        commands.clear()
        input.down(1, 100.0, 100.0, canControl = true)
        input.moved(1, 130.0, 100.0)
        input.up(1, 130.0, 100.0, Instant.fromEpochMilliseconds(5_000))
        assertTrue(buttons().isEmpty(), "a moved finger does not click")
        assertEquals(0.6, assertNotNull(commands.last().pointer).x, 1e-9)
    }

    @Test
    fun rightClickIsOneShot() {
        input.canvas.resize(300.0, 300.0, 300.0, 150.0)
        assertFalse(input.armed.rightClick)
        input.armed.toggleRightClick()
        assertTrue(input.armed.rightClick)
        tap()
        assertEquals(listOf(Triple(Button.BUTTON_RIGHT, true, 1), Triple(Button.BUTTON_RIGHT, false, 1)), buttons())
        assertFalse(input.armed.rightClick, "the click used it up")

        commands.clear()
        tap(atMillis = 10_000)
        assertEquals(Button.BUTTON_LEFT, buttons().first().first)
    }

    @Test
    fun rightClickCanBeToggledOffOrCancelled() {
        input.armed.toggleRightClick()
        input.armed.toggleRightClick()
        assertFalse(input.armed.rightClick)
        input.armed.toggleRightClick()
        input.releaseInput()
        assertFalse(input.armed.rightClick)
        assertNotNull(commands.last().release_input)
    }

    @Test
    fun armedModifiersApplyToTheNextKeyOrText() {
        input.armed.toggleModifier(Modifiers.CONTROL)
        input.text("d")
        assertEquals(ScreenText("d", Modifiers.CONTROL), commands.last().text)
        assertEquals(0, input.armed.modifiers, "text consumes the armed modifiers")

        // The core sends armed text as the physical chord, keeping a typed character's Shift.
        assertEquals(7 to false, ScreenInputEncoder.stroke("d"))
        assertEquals(7 to true, ScreenInputEncoder.stroke("D"))
        assertEquals(56 to true, ScreenInputEncoder.stroke("?"))
        assertNull(ScreenInputEncoder.stroke("é"))

        input.armed.toggleModifier(Modifiers.COMMAND)
        input.key(7, down = true, repeat = false, held = Modifiers.SHIFT)
        assertEquals(ScreenKey(7, true, false, Modifiers.COMMAND or Modifiers.SHIFT), commands.last().key)
        assertEquals(Modifiers.COMMAND, input.armed.modifiers, "a key going down keeps them")
        input.key(224, down = false, repeat = false, held = 0)
        assertEquals(Modifiers.COMMAND, input.armed.modifiers, "a released modifier key keeps them")
        input.key(7, down = false, repeat = false, held = 0)
        assertEquals(0, input.armed.modifiers, "a completed key consumes them")

        input.armed.toggleModifier(Modifiers.OPTION)
        input.press(ScreenKeyboard.ENTER)
        assertEquals(listOf(ScreenKey(40, true, false, Modifiers.OPTION), ScreenKey(40, false, false, Modifiers.OPTION)), commands.takeLast(2).map { it.key })
        assertEquals(0, input.armed.modifiers)
    }

    @Test
    fun cancelledTouchesReleaseHeldInput() {
        input.canvas.resize(300.0, 300.0, 300.0, 150.0)
        input.down(1, 150.0, 150.0, canControl = true)
        assertTrue(input.longPress())
        assertTrue(input.holdingCursor)
        input.cancel()
        assertEquals(listOf(Triple(Button.BUTTON_LEFT, true, 1), Triple(Button.BUTTON_LEFT, false, 1)), buttons())
        assertNotNull(commands.last().release_input)
        assertFalse(input.holdingCursor)
    }

    @Test
    fun everyFingerPerEventDrivesTheSameTrackpad() {
        val canvas = ScreenCanvas().apply { resize(300.0, 300.0, 300.0, 150.0) }
        var clicks = 0
        val sent = mutableListOf<ScreenCommand>()
        val android = TouchScreenInput("", slop = 10.0, doubleTapSlop = 40.0, doubleTapTimeoutMs = 300, canvas = canvas, scrollScale = 0.5, clicked = { clicks++ }) { sent += it }
        assertTrue(android.canvas === canvas, "the host's canvas is the one fingers move over")

        android.begin(7, 150.0, 150.0, canControl = true)
        android.end(7, 150.0, 150.0, Instant.fromEpochMilliseconds(1_000))
        assertEquals(listOf(true, false), sent.mapNotNull { it.button }.map { it.down })
        assertEquals(1, clicks, "a tap's click follows it")

        sent.clear()
        android.begin(1, 100.0, 100.0, canControl = true)
        android.fingers(mapOf(1 to Point(100.0, 100.0), 2 to Point(110.0, 100.0)))
        android.fingers(mapOf(1 to Point(100.0, 100.0), 2 to Point(110.0, 100.0), 3 to Point(120.0, 100.0)))
        android.move(mapOf(1 to Point(100.0, 120.0), 2 to Point(110.0, 120.0), 3 to Point(120.0, 120.0)))
        val scrolls = sent.mapNotNull { it.scroll }
        assertEquals(listOf(TouchTrackpad.SCROLL_BEGAN, TouchTrackpad.SCROLL_CHANGED), scrolls.map { it.phase })
        assertEquals(10.0, scrolls.last().dy, 1e-9, "one move of every finger scrolls once, in scaled units")
        android.cancelGesture()
        assertEquals(TouchTrackpad.SCROLL_ENDED, sent.last().scroll?.phase)
        assertTrue(sent.none { it.release_input != null }, "ending a gesture keeps other held input")
    }

    @Test
    fun heldModifiersJoinClicksButNotKeysOrScrolls() {
        input.canvas.resize(300.0, 300.0, 300.0, 150.0)
        input.heldModifiers = Modifiers.SHIFT
        tap()
        assertEquals(listOf(Modifiers.SHIFT, Modifiers.SHIFT), commands.mapNotNull { it.button }.map { it.modifiers })
        input.button(Button.BUTTON_RIGHT, down = true, clicks = 1)
        assertEquals(ScreenButton(Button.BUTTON_RIGHT, true, 1, 0.5, 0.5, Modifiers.SHIFT), commands.last().button)
        input.scroll(0.0, 4.0, 0, 0)
        assertEquals(0, commands.last().scroll?.modifiers)
        input.releaseInput()
        assertEquals(Modifiers.SHIFT, input.heldModifiers, "the sticky toolbar releases its own modifiers")
    }
}
