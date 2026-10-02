package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.LabelPalette
import com.dbpprt.dieter.core.admin.Labels
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class LabelExportsTest {
    @Test
    fun thePaletteNamesTheTenCoreColors() {
        val palette = LabelPalette.ADAPTER.decode(LabelPalette.ADAPTER.encode(LabelExports.palette()))
        assertEquals(listOf("Ruby", "Coral", "Amber", "Lime", "Emerald", "Teal", "Sky", "Indigo", "Violet", "Rose"), palette.swatches.map { it.name })
        assertEquals(Labels.PALETTE, palette.swatches.map { it.hex })
        assertEquals(palette.swatches.size, palette.swatches.map { it.hex.lowercase() }.toSet().size, "every swatch is distinct")
    }

    @Test
    fun newLabelsStartWithARandomPaletteColor() {
        repeat(30) {
            val color = LabelExports.randomColor("#d95c68")
            assertTrue(color in Labels.PALETTE)
            assertNotEquals("#d95c68", color)
        }
        assertTrue(LabelExports.randomColor("") in Labels.PALETTE)
    }

    @Test
    fun problemsDisableSavingWithTheDaemonsWording() {
        assertEquals("", LabelExports.problem("Urgent", "#7c5cff"), "custom colors outside the palette are valid")
        assertEquals("label name is required", LabelExports.problem("  ", "#7c5cff"))
        assertEquals("label color must be a hex color such as #6558df", LabelExports.problem("Urgent", "#abc"))
        assertEquals("label color must be a hex color such as #6558df", LabelExports.problem("Urgent", "7c5cff"))
        assertEquals("", LabelExports.problem("Urgent", ""), "an empty color takes the daemon's default on create")
    }
}
