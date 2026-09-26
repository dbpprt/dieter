package com.dbpprt.dieter.screens

import org.junit.Assert.*
import org.junit.Test

class ScreenCanvasModelTest {
    @Test fun fittedDesktopDoesNotShiftWhenPointingAtAnyCorner() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1800, 1920, 1080) }
        for ((x, y) in listOf(0f to 0f, 1f to 0f, 1f to 1f, 0f to 1f)) {
            canvas.cursor(x, y); canvas.move(0f, 0f)
            assertTrue(canvas.isFitted)
        }
        assertFalse(canvas.contains(500f, 100f))
        assertTrue(canvas.contains(500f, 900f))
    }
    @Test fun zoomLimitsReverseImmediatelyAndDoNotAccumulateOvershoot() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1800, 1920, 1080) }
        canvas.transform(100f, 500f, 900f, 500f, 900f)
        assertEquals(8f, canvas.zoom, 0f)
        canvas.transform(.99f, 500f, 900f, 500f, 900f)
        assertEquals(7.92f, canvas.zoom, .0001f)
        canvas.transform(.001f, 500f, 900f, 500f, 900f)
        assertEquals(.25f, canvas.zoom, 0f)
        canvas.transform(1.01f, 500f, 900f, 500f, 900f)
        assertEquals(.2525f, canvas.zoom, .0001f)
    }
    @Test fun relativeMotionDoesNotTeleportToFingerLocation() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1000, 2000, 1000) }
        canvas.move(100f, -50f)
        assertEquals(.6f, canvas.cursorX, .0001f)
        assertEquals(.4f, canvas.cursorY, .0001f)
        canvas.move(100000f, -100000f)
        assertEquals(1f, canvas.cursorX, 0f); assertEquals(0f, canvas.cursorY, 0f)
    }
    @Test fun pinchPreservesTheAnchorAndPanKeepsARecoverableEdge() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 600, 2000, 1200) }
        val anchor = (300 - canvas.left) / canvas.scale
        canvas.transform(2f, 300f, 250f, 350f, 280f)
        assertEquals(anchor, (350 - canvas.left) / canvas.scale, .001f)
        canvas.transform(1f, 350f, 280f, 10000f, 10000f)
        assertTrue(canvas.left < 1000); assertTrue(canvas.left + canvas.remoteWidth * canvas.scale > 0)
        assertTrue(canvas.top < 600); assertTrue(canvas.top + canvas.remoteHeight * canvas.scale > 0)
        canvas.reset(); assertEquals(1f, canvas.zoom, 0f); assertEquals(0f, canvas.panX, 0f)
    }
    @Test fun fittedDesktopPansFreelyInBothAxesOnAPortraitPhone() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1800, 1920, 1080) }
        val left = canvas.left; val top = canvas.top
        canvas.transform(1f, 500f, 900f, 670f, 1140f)
        assertEquals(left + 170, canvas.left, .001f)
        assertEquals(top + 240, canvas.top, .001f)
        assertEquals(1f, canvas.zoom, 0f)
    }
    @Test fun zoomOutAndCombinedPanKeepThePointBetweenTheFingersAttached() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1800, 1920, 1080) }
        val u = (380 - canvas.left) / (canvas.remoteWidth * canvas.scale)
        val v = (780 - canvas.top) / (canvas.remoteHeight * canvas.scale)
        canvas.transform(.7f, 380f, 780f, 435f, 865f)
        assertEquals(.7f, canvas.zoom, .0001f)
        assertEquals(435f, canvas.left + u * canvas.remoteWidth * canvas.scale, .001f)
        assertEquals(865f, canvas.top + v * canvas.remoteHeight * canvas.scale, .001f)
        canvas.transform(.5f, 435f, 865f, 435f, 865f)
        assertEquals(.35f, canvas.zoom, .0001f)
    }
    @Test fun smallPinchStepsAreContinuousAndIndependentOfEncodedResolution() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1800, 1920, 1080) }
        repeat(12) {
            val zoom = canvas.zoom
            canvas.transform(1.017f, 380f, 820f, 383f, 824f)
            assertEquals(zoom * 1.017f, canvas.zoom, .00001f)
        }
        val left = canvas.left; val top = canvas.top
        val extent = canvas.remoteWidth * canvas.scale
        canvas.resize(1000, 1800, 960, 540)
        assertEquals(left, canvas.left, .001f); assertEquals(top, canvas.top, .001f)
        assertEquals(extent, canvas.remoteWidth * canvas.scale, .001f)
    }
    @Test fun viewportResizeKeepsTheSameDesktopPointAtItsCenter() {
        val canvas = ScreenCanvasModel().apply {
            resize(1000, 1800, 1920, 1080)
            transform(1.8f, 500f, 900f, 650f, 1100f)
        }
        val u = (500 - canvas.left) / (canvas.remoteWidth * canvas.scale)
        val v = (900 - canvas.top) / (canvas.remoteHeight * canvas.scale)
        canvas.resize(1800, 1000, 1920, 1080)
        assertEquals(u, (900 - canvas.left) / (canvas.remoteWidth * canvas.scale), .0001f)
        assertEquals(v, (500 - canvas.top) / (canvas.remoteHeight * canvas.scale), .0001f)
    }
    @Test fun invalidPinchSamplesCannotCorruptTheCanvas() {
        val canvas = ScreenCanvasModel().apply { resize(1000, 1800, 1920, 1080) }
        for (factor in listOf(Float.NaN, Float.POSITIVE_INFINITY, -1f, 0f)) {
            canvas.transform(factor, 500f, 900f, 520f, 930f)
            assertEquals(1f, canvas.zoom, 0f); assertEquals(0f, canvas.panX, 0f)
        }
        canvas.transform(1f, 500f, 900f, Float.NaN, 930f)
        assertTrue(canvas.left.isFinite() && canvas.top.isFinite())
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
