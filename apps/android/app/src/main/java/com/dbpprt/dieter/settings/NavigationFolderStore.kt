package com.dbpprt.dieter.settings

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Local persistence boundary for future client-layout sync. Uses Mac's JSON field names. */
class NavigationFolderStore(private val preferences: SharedPreferences) {
    private val _layouts = MutableStateFlow(NavigationFolderScope.entries.associateWith { scope ->
        decode(preferences.getString(scope.storageKey, null))
    })
    val layouts = _layouts.asStateFlow()

    @Synchronized
    fun update(scope: NavigationFolderScope, transform: (NavigationFolderPreferences) -> NavigationFolderPreferences) {
        val current = _layouts.value.getValue(scope)
        val updated = NavigationFolderPreferences.from(transform(current).folders)
        if (current == updated) return
        preferences.edit().putString(scope.storageKey, encode(updated)).apply()
        _layouts.value = _layouts.value + (scope to updated)
    }

    fun create(scope: NavigationFolderScope, name: String, itemID: String? = null) {
        update(scope) { current ->
            val next = current.adding(name)
            if (next == current || itemID == null) next else next.moving(itemID, next.folders.last().id)
        }
    }

    companion object {
        fun encode(value: NavigationFolderPreferences): String = JSONArray().apply {
            value.folders.forEach { folder ->
                put(JSONObject().put("id", folder.id).put("name", folder.name)
                    .put("itemIDs", JSONArray(folder.itemIDs)).put("isExpanded", folder.isExpanded))
            }
        }.toString()

        fun decode(encoded: String?): NavigationFolderPreferences = runCatching {
            val array = JSONArray(encoded ?: "[]")
            NavigationFolderPreferences.from((0 until array.length()).mapNotNull { index ->
                val folder = array.optJSONObject(index) ?: return@mapNotNull null
                val members = folder.optJSONArray("itemIDs") ?: JSONArray()
                NavigationFolder(
                    id = folder.optString("id"),
                    name = folder.optString("name"),
                    itemIDs = (0 until members.length()).mapNotNull { members.opt(it) as? String },
                    isExpanded = folder.optBoolean("isExpanded", true),
                )
            })
        }.getOrDefault(NavigationFolderPreferences())
    }
}
