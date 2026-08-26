package com.dbpprt.dieter.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DieterPaletteTest {
    @Test
    fun exposesMonochromeFirstAndEveryDesignInPickerOrder() {
        assertEquals(
            listOf(
                "monochrome",
                "electric-blue", "jade-operator", "copper-circuit", "ultraviolet-relay",
                "solar-command", "arctic-console", "coral-signal",
            ),
            DieterPalette.entries.map { it.slug },
        )
        assertEquals(8, DieterPalette.entries.map { it.displayName }.distinct().size)
    }

    @Test
    fun resolvesPersistedValuesMigratesAcidAndUsesMonochromeByDefault() {
        assertEquals(DieterPalette.MONOCHROME, DieterPalette.resolve(null))
        assertEquals(DieterPalette.MONOCHROME, DieterPalette.resolve("unknown"))
        assertEquals(DieterPalette.MONOCHROME, DieterPalette.resolve("acid-terminal"))
        assertEquals(DieterPalette.MONOCHROME, DieterPalette.resolve("ACID_TERMINAL"))
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

    @Test
    fun monochromeTokensAdaptTextAndAccentsToNativeAppearance() {
        val tokens = DieterPalette.MONOCHROME.tokens
        assertEquals(tokens.lightInt, tokens.textForAppearanceInt(darkMode = true))
        assertEquals(tokens.darkBrandInt, tokens.textForAppearanceInt(darkMode = false))
        assertEquals(tokens.eyesInt, tokens.eyesForAppearanceInt(darkMode = true))
        assertEquals(tokens.shellEndInt, tokens.eyesForAppearanceInt(darkMode = false))
    }
}
