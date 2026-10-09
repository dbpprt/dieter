package com.dbpprt.dieter.core.screens

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class VirtualDisplaySizingTest {
    @Test
    fun drawablePixelsAndScaleAreIndependent() {
        assertEquals(2560 to 1440, VirtualDisplaySizing.size(1280.0, 720.0, 2.0, 1))
        assertEquals(2560 to 1440, VirtualDisplaySizing.size(1280.0, 720.0, 2.0, 2))
        assertEquals(3840 to 2160, VirtualDisplaySizing.size(3840.0, 2160.0, 2.0, 2))
        assertEquals(1920 to 1080, VirtualDisplaySizing.size(1280.0, 720.0, 2.0, 2, hevc = true))
        assertEquals(1080 to 2160, VirtualDisplaySizing.size(600.0, 1200.0, 3.0, 2))
        assertEquals(1280 to 720, VirtualDisplaySizing.size(1283.0, 723.0, 1.0, 2))
        assertNull(VirtualDisplaySizing.size(Double.NaN, 720.0, 2.0, 2))
        assertNull(VirtualDisplaySizing.size(1280.0, 720.0, Double.POSITIVE_INFINITY, 2))
        assertNull(VirtualDisplaySizing.size(1.0, 1.0, 1.0, 2))
    }
}
