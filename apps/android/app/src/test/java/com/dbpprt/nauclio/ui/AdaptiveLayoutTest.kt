package com.dbpprt.nauclio.ui

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

    private fun pixelsToDp(pixels: Int, densityDpi: Int): Float =
        pixels * 160f / densityDpi
}
