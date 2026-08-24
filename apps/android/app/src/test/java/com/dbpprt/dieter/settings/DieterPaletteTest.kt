package com.dbpprt.dieter.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DieterPaletteTest {
    @Test
    fun exposesEveryOfficialPaletteInPackOrder() {
        assertEquals(
            listOf(
                "electric-blue", "jade-operator", "copper-circuit", "ultraviolet-relay",
                "solar-command", "arctic-console", "coral-signal", "acid-terminal",
            ),
            DieterPalette.entries.map { it.slug },
        )
        assertEquals(8, DieterPalette.entries.map { it.displayName }.distinct().size)
    }

    @Test
    fun resolvesPersistedValuesAndUsesArcticAsTheMigrationDefault() {
        assertEquals(DieterPalette.ARCTIC_CONSOLE, DieterPalette.resolve(null))
        assertEquals(DieterPalette.ARCTIC_CONSOLE, DieterPalette.resolve("unknown"))
        DieterPalette.entries.forEach { palette ->
            assertEquals(palette, DieterPalette.resolve(palette.slug))
            assertEquals(palette, DieterPalette.resolve(palette.name))
        }
    }

    @Test
    fun everyPaletteHasDistinctBrandAndSurfaceTokens() {
        assertEquals(8, DieterPalette.entries.map { it.tokens.shellStart }.distinct().size)
        assertEquals(8, DieterPalette.entries.map { it.tokens.darkBackground }.distinct().size)
        DieterPalette.entries.forEach { palette ->
            assertNotEquals(palette.tokens.darkBackground, palette.tokens.darkSurface)
            assertNotEquals(palette.tokens.shellStart, palette.tokens.shellEnd)
            assertTrue(palette.tokens.lightInt ushr 24 == 0xff)
        }
    }
}
