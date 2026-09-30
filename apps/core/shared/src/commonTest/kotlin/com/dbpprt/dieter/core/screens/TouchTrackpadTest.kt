package com.dbpprt.dieter.core.screens

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant

private fun at(millis: Long) = Instant.fromEpochMilliseconds(0) + millis.milliseconds

/** Touch edge cases carried over from the Android client's gesture suite. */
class TouchTrackpadTest {
    private class Pad {
        val moves = mutableListOf<Point>()
        val buttons = mutableListOf<Pair<Boolean, Int>>()
        val scrolls = mutableListOf<Int>()
        val canvas = ScreenCanvas().apply { resize(1000.0, 1800.0, 1920.0, 1080.0) }
        var clicks = 0
        val gesture = TouchTrackpad(12.0, 60.0, 300, object : TrackpadActions {
            override fun move(delta: Point) { moves += delta }
            override fun button(down: Boolean, clicks: Int) { buttons += down to clicks }
            override fun clicked() { this@Pad.clicks++ }
            override fun scroll(delta: Point, phase: Int) { scrolls += phase }
            override fun transform(factor: Double, oldCenter: Point, newCenter: Point) = canvas.transform(factor, oldCenter, newCenter)
        })

        fun tap(time: Long, x: Double = 200.0) {
            gesture.begin(0, Point(x, 300.0), canControl = true)
            gesture.end(0, Point(x, 300.0), at(time))
        }
    }

    private fun p(x: Double = 200.0, y: Double = 300.0) = Point(x, y)

    @Test
    fun fingerJitterClicksWithoutMovingTheTarget() {
        val pad = Pad()
        pad.gesture.begin(0, p(), canControl = true)
        pad.gesture.move(mapOf(0 to p(205.0, 304.0)))
        pad.gesture.move(mapOf(0 to p(202.0, 299.0)))
        pad.gesture.end(0, p(204.0, 302.0), at(1000))
        assertTrue(pad.moves.isEmpty())
        assertEquals(listOf(true to 1, false to 1), pad.buttons)
        assertEquals(1, pad.clicks)
    }

    @Test
    fun motionPastSlopAndFinalUpPositionNeverClick() {
        val pad = Pad()
        pad.gesture.begin(0, p(), canControl = true)
        pad.gesture.move(mapOf(0 to p(206.0)))
        pad.gesture.move(mapOf(0 to p(220.0)))
        pad.gesture.end(0, p(225.0), at(1000))
        assertEquals(listOf(Point(20.0, 0.0), Point(5.0, 0.0)), pad.moves)
        assertTrue(pad.buttons.isEmpty())
        assertFalse(pad.gesture.longPress())
        pad.gesture.begin(0, p(), canControl = true)
        pad.gesture.end(0, p(230.0), at(1100))
        assertEquals(Point(30.0, 0.0), pad.moves.last())
        assertTrue(pad.buttons.isEmpty())
    }

    @Test
    fun doubleClickRequiresNearbyTapsWithoutInterveningMovement() {
        val pad = Pad()
        pad.tap(1000)
        pad.tap(1100, 205.0)
        assertEquals(listOf(true to 1, false to 1, true to 2, false to 2), pad.buttons)
        pad.tap(1200)
        pad.tap(1300, 500.0)
        assertEquals(false to 1, pad.buttons.last())
        pad.gesture.begin(0, p(500.0), canControl = true)
        pad.gesture.move(mapOf(0 to p(550.0)))
        pad.gesture.end(0, p(550.0), at(1400))
        pad.tap(1450, 550.0)
        assertEquals(false to 1, pad.buttons.last(), "a drag between taps breaks the double click")
    }

    @Test
    fun longPressReleaseAndCancellationAreBalanced() {
        for (cancel in listOf(false, true)) {
            val pad = Pad()
            pad.gesture.begin(0, p(), canControl = true)
            assertTrue(pad.gesture.longPress())
            assertFalse(pad.gesture.longPress())
            pad.gesture.move(mapOf(0 to p(203.0)))
            if (cancel) pad.gesture.cancel() else pad.gesture.end(0, p(203.0), at(2000))
            pad.gesture.cancel()
            assertEquals(listOf(true to 1, false to 1), pad.buttons)
            assertEquals(0, pad.clicks)
        }
    }

    @Test
    fun pinchFingerReplacementRebasesWithoutMovingOrClickingTheCursor() {
        val pad = Pad()
        pad.gesture.begin(0, p(300.0, 800.0), canControl = true)
        pad.gesture.fingers(mapOf(0 to p(300.0, 800.0), 9 to p(500.0, 800.0)))
        pad.gesture.move(mapOf(0 to p(250.0, 800.0), 9 to p(550.0, 800.0)))
        assertEquals(1.5, pad.canvas.zoom, 0.0001)
        pad.gesture.fingers(mapOf(9 to p(550.0, 800.0)))
        pad.gesture.move(mapOf(9 to p(650.0, 800.0)))
        val left = pad.canvas.left
        val top = pad.canvas.top
        pad.gesture.fingers(mapOf(9 to p(650.0, 800.0), 11 to p(350.0, 800.0)))
        pad.gesture.move(mapOf(11 to p(360.0, 820.0), 9 to p(660.0, 820.0)))
        assertEquals(left + 10, pad.canvas.left, 0.001)
        assertEquals(top + 20, pad.canvas.top, 0.001)
        assertEquals(1.5, pad.canvas.zoom, 0.0001)
        pad.gesture.fingers(mapOf(11 to p(360.0, 820.0)))
        pad.gesture.end(11, p(360.0, 820.0), at(1000))
        assertTrue(pad.moves.isEmpty())
        assertTrue(pad.buttons.isEmpty())
    }

    @Test
    fun coincidentContactsCannotExplodeTheZoom() {
        val pad = Pad()
        pad.gesture.begin(0, p(), canControl = false)
        pad.gesture.fingers(mapOf(0 to p(), 1 to p()))
        pad.gesture.move(mapOf(0 to p(198.0), 1 to p(202.0)))
        assertEquals(1.0, pad.canvas.zoom)
        pad.gesture.move(mapOf(0 to p(180.0), 1 to p(220.0)))
        assertEquals(40.0 / 24.0, pad.canvas.zoom, 0.0001)
        assertTrue(pad.buttons.isEmpty())
    }

    @Test
    fun threeFingerScrollAndControlLossCannotLeaveHeldInput() {
        val pad = Pad()
        val fingers = (0..2).associateWith { p(200.0 + it * 100) }
        pad.gesture.begin(0, fingers.getValue(0), canControl = true)
        pad.gesture.longPress()
        pad.gesture.fingers(fingers.filterKeys { it < 2 })
        pad.gesture.fingers(fingers)
        pad.gesture.move(fingers.mapValues { it.value.copy(y = 350.0) })
        pad.gesture.cancel()
        pad.gesture.move(fingers)
        pad.gesture.end(0, fingers.getValue(0), at(1000))
        assertEquals(listOf(true to 1, false to 1), pad.buttons)
        assertEquals(listOf(TouchTrackpad.SCROLL_BEGAN, TouchTrackpad.SCROLL_CHANGED, TouchTrackpad.SCROLL_ENDED), pad.scrolls)
        assertEquals(0, pad.clicks)
        pad.gesture.begin(0, fingers.getValue(0), canControl = false)
        assertFalse(pad.gesture.longPress())
        pad.gesture.end(0, fingers.getValue(0), at(1100))
        assertEquals(0, pad.clicks)
    }

    @Test
    fun releaseCanReenterCancellationWithoutRecursing() {
        val buttons = mutableListOf<Boolean>()
        lateinit var gesture: TouchTrackpad
        gesture = TouchTrackpad(12.0, 60.0, 300, object : TrackpadActions {
            override fun move(delta: Point) = Unit
            override fun button(down: Boolean, clicks: Int) {
                buttons += down
                if (!down) gesture.cancel()
            }
            override fun clicked() = Unit
            override fun scroll(delta: Point, phase: Int) = Unit
            override fun transform(factor: Double, oldCenter: Point, newCenter: Point) = Unit
        })
        gesture.begin(0, p(100.0, 100.0), canControl = true)
        gesture.longPress()
        gesture.cancel()
        assertEquals(listOf(true, false), buttons)
    }
}
