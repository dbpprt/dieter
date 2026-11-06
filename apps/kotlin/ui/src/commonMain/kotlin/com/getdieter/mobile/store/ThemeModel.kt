package com.getdieter.mobile.store

import com.getdieter.mobile.settings.DieterPalette
import kotlinx.coroutines.flow.MutableStateFlow

/** Appearance choices, kept in the platform's preferences. */
class ThemeModel internal constructor(private val preferences: MobilePreferences) {
    val palette = MutableStateFlow(DieterPalette.resolve(preferences.read("palette")))
    val appearance = MutableStateFlow(preferences.read("appearance") ?: "system")
    val dynamicColor = MutableStateFlow(preferences.read("dynamic-color") == "true")

    fun setPalette(value: DieterPalette) {
        palette.value = value
        preferences.write("palette", value.slug)
    }

    fun setAppearance(value: String) {
        appearance.value = value
        preferences.write("appearance", value)
    }

    fun setDynamicColor(value: Boolean) {
        dynamicColor.value = value
        preferences.write("dynamic-color", value.toString())
    }
}
