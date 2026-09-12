package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ResizablePaneTest {
    @Test
    fun `split preserves an in-range requested width`() {
        assertEquals(
            430f,
            clampedPaneLeadingWidth(
                requestedWidth = 430f,
                totalWidth = 1_000f,
                dividerWidth = 16f,
                minimumLeadingWidth = 220f,
                minimumTrailingWidth = 320f,
            ),
        )
    }

    @Test
    fun `split clamps both panes to their minimum widths`() {
        assertEquals(
            220f,
            clampedPaneLeadingWidth(100f, 1_000f, 16f, 220f, 320f),
        )
        assertEquals(
            664f,
            clampedPaneLeadingWidth(900f, 1_000f, 16f, 220f, 320f),
        )
    }

    @Test
    fun `compact split preserves the requested minimum proportions`() {
        assertEquals(
            220f,
            clampedPaneLeadingWidth(400f, 556f, 16f, 220f, 320f),
        )
    }
}
