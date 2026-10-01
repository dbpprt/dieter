package com.dbpprt.dieter.widget

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Per-widget options plus a shared JSON cache of the last fetched provider
 * usage so the widget renders instantly after process death. The gateway
 * keeps no client state, so the client owns this cache.
 */
object WidgetUsagePrefs {
    private const val PREFERENCES = "dieter_usage_widget"
    private const val KEY_CACHE = "quota_cache"
    private const val KEY_FETCHED_AT = "quota_fetched_at"

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun cachedSnapshots(context: Context): Pair<List<UsageAccountSnapshot>, Long> {
        val preferences = preferences(context)
        val fetchedAt = preferences.getLong(KEY_FETCHED_AT, 0L)
        val encoded = preferences.getString(KEY_CACHE, null) ?: return emptyList<UsageAccountSnapshot>() to 0L
        return runCatching { decodeCache(encoded) }.getOrDefault(emptyList()) to fetchedAt
    }

    fun saveCache(context: Context, snapshots: List<UsageAccountSnapshot>, fetchedAtMs: Long) {
        preferences(context).edit()
            .putString(KEY_CACHE, encodeCache(snapshots))
            .putLong(KEY_FETCHED_AT, fetchedAtMs)
            .apply()
    }

    private fun encodeCache(snapshots: List<UsageAccountSnapshot>): String {
        val array = JSONArray()
        snapshots.forEach { account ->
            val windows = JSONArray()
            account.windows.forEach { window ->
                windows.put(JSONObject()
                    .put("label", window.label)
                    .put("remaining", window.remainingPercent ?: -1)
                    .put("resetsAt", window.resetsAt))
            }
            array.put(JSONObject()
                .put("provider", account.providerName)
                .put("title", account.title)
                .put("available", account.available)
                .put("availability", account.availabilityText)
                .put("freshUntil", account.freshUntilMs)
                .put("windows", windows))
        }
        return array.toString()
    }

    private fun decodeCache(encoded: String): List<UsageAccountSnapshot> {
        val array = JSONArray(encoded)
        val snapshots = (0 until array.length()).map { index ->
            val account = array.getJSONObject(index)
            val windows = account.getJSONArray("windows")
            UsageAccountSnapshot(
                providerName = account.getString("provider"),
                title = account.getString("title"),
                available = account.getBoolean("available"),
                availabilityText = account.getString("availability"),
                freshUntilMs = account.getLong("freshUntil"),
                windows = (0 until windows.length()).map { windowIndex ->
                    val window = windows.getJSONObject(windowIndex)
                    val remaining = window.getInt("remaining")
                    UsageWindowSnapshot(
                        label = window.getString("label"),
                        remainingPercent = remaining.takeIf { it >= 0 },
                        resetsAt = window.getString("resetsAt"),
                    )
                },
            )
        }
        return snapshots
    }
}
