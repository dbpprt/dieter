package com.dbpprt.nauclio.ui

import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LabelColorPaletteTest {
    @Test
    fun matchesTheWebLabelPalette() {
        assertEquals(
            listOf("#d95c68", "#df7650", "#c9952f", "#7d9e45", "#3e9970", "#379799", "#478dc5", "#626fd0", "#8a62c3", "#c65f98"),
            LabelColorPalette.map { it.value },
        )
    }

    @Test
    fun randomDefaultAlwaysUsesPaletteAndExcludesPreviousColor() {
        repeat(100) { seed ->
            val previous = LabelColorPalette[seed % LabelColorPalette.size].value
            val color = randomLabelColor(previous, Random(seed))
            assertTrue(color in LabelColorPalette.map { it.value })
            assertNotEquals(previous, color)
        }
    }
}
