package com.dbpprt.dieter.widget

import android.content.Context
import android.content.SharedPreferences

/** Per-widget options plus the shared "last sync frame" clock the header renders. */
object DieterWidgetPrefs {
    private const val PREFERENCES = "dieter_widget"
    private const val KEY_LAST_SYNC_AT = "last_sync_at"
    private const val SYNC_WRITE_THROTTLE_MS = 20_000L
    private const val SYNC_PUSH_THROTTLE_MS = 60_000L

    @Volatile
    private var lastSyncWriteMs = 0L

    @Volatile
    private var lastSyncPushMs = 0L

    private fun preferences(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun config(context: Context, appWidgetId: Int): WidgetConfig {
        val preferences = preferences(context)
        val defaults = WidgetConfig()
        return WidgetConfig(
            style = preferences.getString("style_$appWidgetId", null)
                ?.let { saved -> WidgetStyle.entries.firstOrNull { it.name == saved } }
                ?: defaults.style,
            maxItems = preferences.getInt("max_items_$appWidgetId", defaults.maxItems),
            showSections = preferences.getBoolean("sections_$appWidgetId", defaults.showSections),
            includeChats = preferences.getBoolean("chats_$appWidgetId", defaults.includeChats),
        )
    }

    fun saveConfig(context: Context, appWidgetId: Int, config: WidgetConfig) {
        preferences(context).edit()
            .putString("style_$appWidgetId", config.style.name)
            .putInt("max_items_$appWidgetId", config.maxItems)
            .putBoolean("sections_$appWidgetId", config.showSections)
            .putBoolean("chats_$appWidgetId", config.includeChats)
            .apply()
    }

    fun delete(context: Context, appWidgetIds: IntArray) {
        val editor = preferences(context).edit()
        appWidgetIds.forEach { id ->
            editor.remove("style_$id").remove("max_items_$id").remove("sections_$id").remove("chats_$id")
        }
        editor.apply()
    }

    fun lastSyncAtMs(context: Context): Long = preferences(context).getLong(KEY_LAST_SYNC_AT, 0L)

    /**
     * Called on every sync frame (heartbeats included, every ~15 s). Throttles
     * the disk write and refreshes widget headers about once a minute so the
     * "polled Nm ago" label stays honest without hammering the widget host.
     */
    fun recordSyncFrame(context: Context, nowMs: Long = System.currentTimeMillis()) {
        if (nowMs - lastSyncWriteMs >= SYNC_WRITE_THROTTLE_MS) {
            lastSyncWriteMs = nowMs
            preferences(context).edit().putLong(KEY_LAST_SYNC_AT, nowMs).apply()
        }
        if (nowMs - lastSyncPushMs >= SYNC_PUSH_THROTTLE_MS) {
            lastSyncPushMs = nowMs
            DieterActivityWidgetProvider.updateAll(context)
        }
    }
}
