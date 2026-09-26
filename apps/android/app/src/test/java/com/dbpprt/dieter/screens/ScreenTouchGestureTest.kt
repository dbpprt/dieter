package com.dbpprt.dieter.screens

import org.junit.Assert.*
import org.junit.Test

class ScreenTouchGestureTest {
    private class Pad {
        val moves = mutableListOf<Pair<Float, Float>>()
        val buttons = mutableListOf<Pair<Boolean, Int>>()
        val scrolls = mutableListOf<Int>()
        val canvas = ScreenCanvasModel().apply { resize(1000, 1800, 1920, 1080) }
        var clicks = 0
        val gesture = ScreenTouchGesture(12f, 60f, 300,
            move = { x, y -> moves += x to y },
            transform = canvas::transform,
            button = { down, count -> buttons += down to count },
            scroll = { _, _, phase -> scrolls += phase },
            clicked = { clicks++ })
        fun finger(x: Float = 200f, y: Float = 300f, id: Int = 0) = ScreenTouchGesture.Finger(id, x, y)
        fun tap(time: Long, x: Float = 200f) {
            gesture.begin(finger(x), true); gesture.end(finger(x), time)
        }
    }

    @Test fun fingerJitterClicksWithoutMovingTheTarget() {
        val p = Pad()
        p.gesture.begin(p.finger(), true)
        p.gesture.move(listOf(p.finger(205f, 304f)))
        p.gesture.move(listOf(p.finger(202f, 299f)))
        p.gesture.end(p.finger(204f, 302f), 1000)
        assertTrue(p.moves.isEmpty())
        assertEquals(listOf(true to 1, false to 1), p.buttons)
        assertEquals(1, p.clicks)
    }

    @Test fun motionPastSlopAndFinalUpPositionNeverClick() {
        val p = Pad()
        p.gesture.begin(p.finger(), true)
        p.gesture.move(listOf(p.finger(206f)))
        p.gesture.move(listOf(p.finger(220f)))
        p.gesture.end(p.finger(225f), 1000)
        assertEquals(listOf(20f to 0f, 5f to 0f), p.moves)
        assertTrue(p.buttons.isEmpty())
        assertFalse(p.gesture.longPress())
        p.gesture.begin(p.finger(), true)
        p.gesture.end(p.finger(230f), 1100)
        assertEquals(30f to 0f, p.moves.last())
        assertTrue(p.buttons.isEmpty())
    }

    @Test fun doubleClickRequiresNearbyTapsWithoutInterveningMovement() {
        val p = Pad()
        p.tap(1000); p.tap(1100, 205f)
        assertEquals(listOf(true to 1, false to 1, true to 2, false to 2), p.buttons)
        p.tap(1200); p.tap(1300, 500f)
        assertEquals(false to 1, p.buttons.last())
        p.gesture.begin(p.finger(500f), true)
        p.gesture.move(listOf(p.finger(550f)))
        p.gesture.end(p.finger(550f), 1400)
        p.tap(1450, 550f)
        assertEquals(false to 1, p.buttons.last())
    }

    @Test fun longPressReleaseAndCancellationAreBalanced() {
        for (cancel in listOf(false, true)) {
            val p = Pad()
            p.gesture.begin(p.finger(), true)
            assertTrue(p.gesture.longPress())
            assertFalse(p.gesture.longPress())
            p.gesture.move(listOf(p.finger(203f)))
            if (cancel) p.gesture.cancel() else p.gesture.end(p.finger(203f), 2000)
            p.gesture.cancel()
            assertEquals(listOf(true to 1, false to 1), p.buttons)
            assertEquals(0, p.clicks)
        }
    }

    @Test fun pinchFingerReplacementRebasesWithoutMovingOrClickingTheCursor() {
        val p = Pad()
        val a = p.finger(300f, 800f); val b = p.finger(500f, 800f, 9)
        p.gesture.begin(a, true); p.gesture.fingers(listOf(a, b))
        p.gesture.move(listOf(a.copy(x = 250f), b.copy(x = 550f)))
        assertEquals(1.5f, p.canvas.zoom, .0001f)
        p.gesture.fingers(listOf(b.copy(x = 550f)))
        p.gesture.move(listOf(b.copy(x = 650f)))
        val left = p.canvas.left; val top = p.canvas.top
        val c = p.finger(350f, 800f, 11)
        p.gesture.fingers(listOf(b.copy(x = 650f), c))
        p.gesture.move(listOf(c.copy(x = 360f, y = 820f), b.copy(x = 660f, y = 820f)))
        assertEquals(left + 10f, p.canvas.left, .001f)
        assertEquals(top + 20f, p.canvas.top, .001f)
        assertEquals(1.5f, p.canvas.zoom, .0001f)
        p.gesture.fingers(listOf(c)); p.gesture.end(c, 1000)
        assertTrue(p.moves.isEmpty()); assertTrue(p.buttons.isEmpty())
    }

    @Test fun coincidentContactsCannotExplodeTheZoom() {
        val p = Pad()
        val a = p.finger(); val b = p.finger(id = 1)
        p.gesture.begin(a, false); p.gesture.fingers(listOf(a, b))
        p.gesture.move(listOf(a.copy(x = 198f), b.copy(x = 202f)))
        assertEquals(1f, p.canvas.zoom, 0f)
        p.gesture.move(listOf(a.copy(x = 180f), b.copy(x = 220f)))
        assertEquals(40f / 24f, p.canvas.zoom, .0001f)
        assertTrue(p.buttons.isEmpty())
    }

    @Test fun threeFingerScrollAndControlLossCannotLeaveHeldInput() {
        val p = Pad()
        val fingers = (0..2).map { p.finger(200f + it * 100, id = it) }
        p.gesture.begin(fingers[0], true); p.gesture.longPress()
        p.gesture.fingers(fingers.take(2)); p.gesture.fingers(fingers)
        p.gesture.move(fingers.map { it.copy(y = 350f) })
        p.gesture.cancel()
        p.gesture.move(fingers); p.gesture.end(fingers[0], 1000)
        assertEquals(listOf(true to 1, false to 1), p.buttons)
        assertEquals(listOf(1, 2, 4), p.scrolls)
        assertEquals(0, p.clicks)
        p.gesture.begin(fingers[0], false)
        assertFalse(p.gesture.longPress())
        p.gesture.end(fingers[0], 1100)
        assertEquals(0, p.clicks)
    }

    @Test fun mouseEventsDeduplicateButtonsAndReleaseOutsideTheCanvas() {
        val events = mutableListOf<Pair<Int, Boolean>>()
        val mouse = ScreenMouseButtons { mask, down, _ -> events += mask to down }
        mouse.update(1, true); mouse.update(1, true)
        mouse.update(3, true); mouse.update(2, false)
        mouse.update(0, false); mouse.update(0, false)
        assertEquals(listOf(1 to true, 2 to true, 1 to false, 2 to false), events)
        mouse.update(1, false) // A letterbox click never presses on the remote edge.
        mouse.update(1, true) // Entering the desktop with it held must not start a drag.
        assertFalse(mouse.isDragging)
        mouse.update(0, true)
        mouse.update(4 or 8 or 16, true)
        mouse.release(); mouse.release()
        assertEquals(10, events.size)
        assertFalse(mouse.isDragging)
        mouse.update(4 or 8 or 16, true) // Focus return cannot re-press held buttons.
        assertEquals(10, events.size)
        mouse.update(1, true, newGesture = true)
        mouse.update(0, true)
        assertEquals(listOf(1 to true, 1 to false), events.takeLast(2))
    }

    @Test fun physicalMouseDoubleClickUsesMatchingCountsAndDraggingBreaksTheSequence() {
        val events = mutableListOf<Pair<Boolean, Int>>()
        val mouse = ScreenMouseButtons { _, down, count -> events += down to count }
        fun click(time: Long) {
            mouse.update(1, true, newGesture = true, time = time)
            mouse.update(1, true, time = time) // Android's duplicate BUTTON_PRESS.
            mouse.update(0, true, time = time + 30)
        }
        click(1000); click(1100)
        assertEquals(listOf(true to 1, false to 1, true to 2, false to 2), events)
        mouse.update(1, true, newGesture = true, time = 1200)
        mouse.update(1, true, time = 1220, x = 50f)
        mouse.update(0, true, time = 1250, x = 50f)
        click(1300)
        assertEquals(listOf(true to 1, false to 1), events.takeLast(2))
        mouse.release(); click(1400)
        assertEquals(listOf(true to 1, false to 1), events.takeLast(2))
    }

    @Test fun releaseCanReenterCancellationWithoutRecursing() {
        lateinit var gesture: ScreenTouchGesture
        val buttons = mutableListOf<Boolean>()
        gesture = ScreenTouchGesture(12f, 60f, 300, { _, _ -> }, { _, _, _, _, _ -> },
            { down, _ -> buttons += down; if (!down) gesture.cancel() }, { _, _, _ -> }, {})
        gesture.begin(ScreenTouchGesture.Finger(0, 100f, 100f), true)
        gesture.longPress(); gesture.cancel()
        assertEquals(listOf(true, false), buttons)
    }
}
