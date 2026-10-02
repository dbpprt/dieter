package com.dbpprt.dieter.widget

import android.content.Context
import android.content.SharedPreferences

/** Per-widget options of the Inbox widget. */
object DieterWidgetPrefs {
    private const val PREFERENCES = "dieter_widget"

    private val keyPrefixes = listOf("style_", "max_items_", "sections_")

    internal fun preferences(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    /** Whether [key] is one of a widget's options. */
    internal fun keeps(key: String): Boolean = keyPrefixes.any(key::startsWith)

    fun config(context: Context, appWidgetId: Int): WidgetConfig {
        val preferences = preferences(context)
        val defaults = WidgetConfig()
        return WidgetConfig(
            style = preferences.getString("style_$appWidgetId", null)
                ?.let { saved -> WidgetStyle.entries.firstOrNull { it.name == saved } }
                ?: defaults.style,
            maxItems = preferences.getInt("max_items_$appWidgetId", defaults.maxItems).coerceIn(1, WidgetConfig.MAX_ITEM_CHOICES.last()),
            showSections = preferences.getBoolean("sections_$appWidgetId", defaults.showSections),
        )
    }

    fun saveConfig(context: Context, appWidgetId: Int, config: WidgetConfig) {
        preferences(context).edit()
            .putString("style_$appWidgetId", config.style.name)
            .putInt("max_items_$appWidgetId", config.maxItems)
            .putBoolean("sections_$appWidgetId", config.showSections)
            .apply()
    }

    fun delete(context: Context, appWidgetIds: IntArray) {
        val editor = preferences(context).edit()
        appWidgetIds.forEach { id ->
            editor.remove("style_$id").remove("max_items_$id").remove("sections_$id")
        }
        editor.apply()
    }
}
