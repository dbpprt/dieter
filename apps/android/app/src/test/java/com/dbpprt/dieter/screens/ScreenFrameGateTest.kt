package com.dbpprt.dieter.screens

import org.junit.Assert.*
import org.junit.Test

class ScreenFrameGateTest {
    private data class Frame(val ns: Long, var references: Int = 0)
    @Test fun frameCanArriveBeforeDisplayMetadata() {
        val shown = mutableListOf<Frame>()
        val gate = ScreenFrameGate<Frame>({ it.ns }, { it.references++ }, { it.references-- }) { frame, _ -> shown.add(frame) }
        gate.update(1, 0, 0, 0)
        val frame = Frame(2_000_000)
        gate.offer(frame, 1)
        gate.update(1, 1, 0, 0)
        assertEquals(1, frame.references)
        gate.update(1, 1, 1, 180)
        assertEquals(listOf(frame), shown)
        assertEquals(0, frame.references)
    }
    @Test fun firstIdleFrameWaitsForMetadataAndLateEpochsCannotShow() {
        val shown = mutableListOf<Frame>()
        val gate = ScreenFrameGate<Frame>({ it.ns }, { it.references++ }, { it.references-- }) { frame, _ -> shown.add(frame) }
        gate.update(1, 1, 0, 0)
        val old = Frame(1_000_000); val first = Frame(2_000_000)
        gate.offer(old, 1); gate.offer(first, 1)
        assertEquals(0, old.references); assertEquals(1, first.references)
        assertTrue(shown.isEmpty())
        gate.update(1, 1, 1, 180)
        assertEquals(listOf(first), shown); assertEquals(0, first.references)
        gate.update(1, 2, 1, 180)
        gate.offer(old, 1)
        gate.update(1, 2, 2, 270)
        assertEquals(listOf(first), shown); assertEquals(0, old.references)
        gate.update(2, 1, 0, 0)
        gate.offer(first, 1)
        assertEquals(0, first.references)
        gate.offer(first, 2); gate.clear(); gate.clear()
        assertEquals(0, first.references)
    }
}
