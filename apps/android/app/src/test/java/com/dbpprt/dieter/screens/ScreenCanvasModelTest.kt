package com.dbpprt.dieter.screens

import org.junit.Assert.*
import org.junit.Test

class ScreenCanvasModelTest {
    @Test fun relativeMotionDoesNotTeleportToFingerLocation() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1000, 2000, 1000) }
        canvas.move(100f, -50f)
        assertEquals(.6f, canvas.cursorX, .0001f)
        assertEquals(.4f, canvas.cursorY, .0001f)
        canvas.move(100000f, -100000f)
        assertEquals(1f, canvas.cursorX, 0f); assertEquals(0f, canvas.cursorY, 0f)
    }
    @Test fun pinchPreservesTheAnchorAndPanCannotLoseDesktop() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 600, 2000, 1200) }
        val anchor = (300 - canvas.left) / canvas.scale
        canvas.transform(2f, 300f, 250f, 350f, 280f)
        assertEquals(anchor, (350 - canvas.left) / canvas.scale, .001f)
        canvas.transform(1f, 350f, 280f, 10000f, 10000f)
        assertTrue(canvas.left <= 0); assertTrue(canvas.left + canvas.remoteWidth * canvas.scale >= 1000)
        canvas.reset(); assertEquals(1f, canvas.zoom, 0f); assertEquals(0f, canvas.panX, 0f)
    }
    @Test fun rotationPreservesZoomAndBounds() {
        val canvas = ScreenCanvasModel().apply { resize(400, 800, 1600, 900); transform(4f, 200f, 400f, 200f, 400f) }
        canvas.resize(800, 400, 1600, 900)
        assertEquals(4f, canvas.zoom, 0f)
        assertTrue(canvas.left <= 0); assertTrue(canvas.top <= 0)
    }
    @Test fun generationBoundaryHandlesRtpWrapAndRejectsOldFrames() {
        assertTrue(belongsToGeneration(1000_000_000, 90001))
        assertFalse(belongsToGeneration(999_000_000, 90001))
        assertTrue(belongsToGeneration(20_000_000, -1000))
        assertFalse(belongsToGeneration(47_721_000_000_000L, 9000))
    }
}
