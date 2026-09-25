package com.dbpprt.dieter.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptiveLayoutTest {
    @Test
    fun `phone width keeps the single-pane layout`() {
        assertFalse(usesTabletLayout(411f))
        assertFalse(usesTabletLayout(TABLET_LAYOUT_MIN_WIDTH_DP - 0.01f))
    }

    @Test
    fun `medium and expanded windows use the tablet layout`() {
        assertTrue(usesTabletLayout(TABLET_LAYOUT_MIN_WIDTH_DP.toFloat()))
        assertTrue(usesTabletLayout(840f))
    }

    @Test
    fun `Galaxy Fold 7 unfolded dimensions use the tablet layout in both orientations`() {
        val densityDpi = 420
        val unfoldedShortEdgeDp = pixelsToDp(1968, densityDpi)
        val unfoldedLongEdgeDp = pixelsToDp(2184, densityDpi)

        assertTrue(usesTabletLayout(unfoldedShortEdgeDp))
        assertTrue(usesTabletLayout(unfoldedLongEdgeDp))
    }

    @Test
    fun `tablet workspace starts at the expanded breakpoint`() {
        assertFalse(usesTabletWorkspace(411f))
        assertFalse(usesTabletWorkspace(839.99f))
        assertTrue(usesTabletWorkspace(840f))
        assertTrue(usesTabletWorkspace(1280f))
    }

    @Test
    fun `Fold 7 retains its existing split layout in both orientations`() {
        listOf(1968, 2184).forEach { pixels ->
            val width = pixelsToDp(pixels, 420)
            assertTrue(usesTabletLayout(width))
            assertFalse(usesTabletWorkspace(width))
        }
    }

    private fun pixelsToDp(pixels: Int, densityDpi: Int): Float =
        pixels * 160f / densityDpi
}
