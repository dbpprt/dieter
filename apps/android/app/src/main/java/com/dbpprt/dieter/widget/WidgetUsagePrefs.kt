package com.dbpprt.dieter.widget

import android.content.Context
import android.util.Base64
import com.dbpprt.dieter.api.gateway.v1.ListProviderQuotasResponse
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup

/**
 * The last fetched provider quota groups, as gateway proto bytes, and the
 * time of that fetch, so the usage widget renders instantly after process
 * death. The gateway keeps no client state, so the client owns this cache.
 */
object WidgetUsagePrefs {
    private const val PREFERENCES = "dieter_usage_widget"
    private const val KEY_GROUPS = "quota_groups"
    private const val KEY_FETCHED_AT = "quota_fetched_at"

    internal fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    /** Whether [key] is part of the cache. */
    internal fun keeps(key: String): Boolean = key == KEY_GROUPS || key == KEY_FETCHED_AT

    /** The cached groups; empty before any fetch or when the cache cannot be decoded. */
    fun cachedGroups(context: Context): List<ProviderQuotaGroup> {
        val encoded = preferences(context).getString(KEY_GROUPS, null) ?: return emptyList()
        return runCatching { ListProviderQuotasResponse.ADAPTER.decode(Base64.decode(encoded, Base64.NO_WRAP)).groups }.getOrDefault(emptyList())
    }

    /** When the cached groups were fetched, in epoch milliseconds; 0 before any fetch. */
    fun fetchedAt(context: Context): Long = preferences(context).getLong(KEY_FETCHED_AT, 0L)

    fun saveCache(context: Context, groups: List<ProviderQuotaGroup>, fetchedAtMs: Long) {
        preferences(context).edit()
            .putString(KEY_GROUPS, Base64.encodeToString(ListProviderQuotasResponse(groups = groups).encode(), Base64.NO_WRAP))
            .putLong(KEY_FETCHED_AT, fetchedAtMs)
            .apply()
    }
}
