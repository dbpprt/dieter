package com.dbpprt.dieter.settings

/** The eight Dieter designs shared by app surfaces, widgets, notifications, and icons. */
enum class DieterPalette(
    val slug: String,
    val displayName: String,
    val tokens: DieterPaletteTokens,
) {
    MONOCHROME(
        "monochrome", "Monochrome",
        DieterPaletteTokens(0xFF1C1C1E, 0xFF2C2C2E, 0xFFE5E5EA, 0xFF636366, 0xFFF2F2F7, 0xFF8E8E93, 0xFFD1D1D6, 0xFFF5F5F7, 0xFF0B0B0C, 0xFF1C1C1E),
    ),
    ELECTRIC_BLUE(
        "electric-blue", "Electric Blue",
        DieterPaletteTokens(0xFF071426, 0xFF102746, 0xFF22D3EE, 0xFF2563EB, 0xFF73F4E4, 0xFF2588F5, 0xFF5EEAD4, 0xFFFAF9F6, 0xFF040C18, 0xFF0B1C33),
    ),
    JADE_OPERATOR(
        "jade-operator", "Jade Operator",
        DieterPaletteTokens(0xFF06211D, 0xFF123C32, 0xFF34D399, 0xFF087F5B, 0xFFA7F3D0, 0xFF14B8A6, 0xFFD1FAE5, 0xFFF4FBF8, 0xFF041412, 0xFF0B2C26),
    ),
    COPPER_CIRCUIT(
        "copper-circuit", "Copper Circuit",
        DieterPaletteTokens(0xFF1A1210, 0xFF3A241A, 0xFFF59E6C, 0xFFB84C2F, 0xFFFFD08A, 0xFFE97850, 0xFFFFE0B2, 0xFFFFF8F1, 0xFF100B0A, 0xFF271A14),
    ),
    ULTRAVIOLET_RELAY(
        "ultraviolet-relay", "Ultraviolet Relay",
        DieterPaletteTokens(0xFF130C2B, 0xFF2B1850, 0xFFC084FC, 0xFF6D5EF8, 0xFFE9D5FF, 0xFFA855F7, 0xFFDDD6FE, 0xFFFCFAFF, 0xFF0C071B, 0xFF1D113B),
    ),
    SOLAR_COMMAND(
        "solar-command", "Solar Command",
        DieterPaletteTokens(0xFF151A22, 0xFF34321C, 0xFFFDE047, 0xFFF59E0B, 0xFFFEF3C7, 0xFFFB923C, 0xFFFDE68A, 0xFFFFFBEA, 0xFF0D1015, 0xFF22241F),
    ),
    ARCTIC_CONSOLE(
        "arctic-console", "Arctic Console",
        DieterPaletteTokens(0xFF0D1B24, 0xFF193A49, 0xFF8DD8E8, 0xFF3D6E85, 0xFFD7F2F5, 0xFF62B6CB, 0xFFBCEAF1, 0xFFF5FBFD, 0xFF081116, 0xFF122834),
    ),
    CORAL_SIGNAL(
        "coral-signal", "Coral Signal",
        DieterPaletteTokens(0xFF28101F, 0xFF4A1D33, 0xFFFF8A7A, 0xFFE44568, 0xFFFFD0C7, 0xFFFF6B8A, 0xFFFFD6CC, 0xFFFFF5F3, 0xFF190A13, 0xFF361527),
    );

    companion object {
        val DEFAULT = MONOCHROME

        fun resolve(value: String?): DieterPalette {
            if (value == "acid-terminal" || value == "ACID_TERMINAL") return MONOCHROME
            return entries.firstOrNull { it.slug == value || it.name == value } ?: DEFAULT
        }
    }
}

data class DieterPaletteTokens(
    val darkBrand: Long,
    val darkRaised: Long,
    val shellStart: Long,
    val shellEnd: Long,
    val paneStart: Long,
    val paneEnd: Long,
    val eyes: Long,
    val light: Long,
    val darkBackground: Long,
    val darkSurface: Long,
) {
    val darkBrandInt: Int get() = darkBrand.toInt()
    val darkRaisedInt: Int get() = darkRaised.toInt()
    val shellStartInt: Int get() = shellStart.toInt()
    val shellEndInt: Int get() = shellEnd.toInt()
    val paneStartInt: Int get() = paneStart.toInt()
    val paneEndInt: Int get() = paneEnd.toInt()
    val eyesInt: Int get() = eyes.toInt()
    val lightInt: Int get() = light.toInt()
    val darkBackgroundInt: Int get() = darkBackground.toInt()
    val darkSurfaceInt: Int get() = darkSurface.toInt()
    val mutedInt: Int get() = blendArgb(lightInt, darkBrandInt, 0.30f)
    val tertiaryInt: Int get() = blendArgb(lightInt, darkBrandInt, 0.48f)
    val outlineInt: Int get() = blendArgb(darkRaisedInt, lightInt, 0.12f)
    val shellTintDeepInt: Int get() = blendArgb(darkBackgroundInt, shellEndInt, 0.18f)
    val eyesTintInt: Int get() = blendArgb(darkBackgroundInt, eyesInt, 0.16f)

    fun textForAppearanceInt(darkMode: Boolean): Int = if (darkMode) lightInt else darkBrandInt
    fun mutedForAppearanceInt(darkMode: Boolean): Int = if (darkMode) {
        mutedInt
    } else {
        blendArgb(darkBrandInt, lightInt, 0.34f)
    }
    fun tertiaryForAppearanceInt(darkMode: Boolean): Int = if (darkMode) {
        tertiaryInt
    } else {
        blendArgb(darkBrandInt, lightInt, 0.48f)
    }
    fun eyesForAppearanceInt(darkMode: Boolean): Int = if (darkMode) eyesInt else shellEndInt
    fun liveForAppearanceInt(darkMode: Boolean): Int = if (darkMode) paneEndInt else shellEndInt
}

fun blendArgb(first: Int, second: Int, amount: Float): Int {
    val ratio = amount.coerceIn(0f, 1f)
    fun channel(shift: Int): Int {
        val start = first ushr shift and 0xff
        val end = second ushr shift and 0xff
        return (start + ((end - start) * ratio)).toInt().coerceIn(0, 255)
    }
    return (channel(24) shl 24) or (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
}
