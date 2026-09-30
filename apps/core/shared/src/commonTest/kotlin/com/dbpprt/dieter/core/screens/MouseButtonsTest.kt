package com.dbpprt.dieter.core.screens

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** Overlapping platform mouse button events; touch gestures are covered by the trackpad tests. */
class MouseButtonsTest {
    @Test fun mouseEventsDeduplicateButtonsAndReleaseOutsideTheCanvas() {
        val events = mutableListOf<Pair<Int, Boolean>>()
        val mouse = MouseButtons { mask, down, _ -> events += mask to down }
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
        val mouse = MouseButtons { _, down, count -> events += down to count }
        fun click(time: Long) {
            mouse.update(1, true, newGesture = true, time = time)
            mouse.update(1, true, time = time) // A duplicate press event.
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
}
