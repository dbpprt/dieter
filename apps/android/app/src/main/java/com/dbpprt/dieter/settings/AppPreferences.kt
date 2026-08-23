package com.dbpprt.dieter.settings

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray

enum class NavigationStyle { CLASSIC, GLASS }

class AppPreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val _navigationStyle = MutableStateFlow(readNavigationStyle())
    val navigationStyle: StateFlow<NavigationStyle> = _navigationStyle.asStateFlow()
    private val _showReasoningTraces = MutableStateFlow(
        preferences.getBoolean(KEY_SHOW_REASONING_TRACES, false),
    )
    val showReasoningTraces: StateFlow<Boolean> = _showReasoningTraces.asStateFlow()
    private val _notificationBoardIds = MutableStateFlow(readNotificationBoardIds())
    val notificationBoardIds: StateFlow<Set<String>> = _notificationBoardIds.asStateFlow()
    private val _projectOrder = MutableStateFlow(readProjectOrder())
    val projectOrder: StateFlow<List<String>> = _projectOrder.asStateFlow()

    fun setNavigationStyle(style: NavigationStyle) {
        preferences.edit().putString(KEY_NAVIGATION_STYLE, style.name).apply()
        _navigationStyle.value = style
    }

    fun setShowReasoningTraces(show: Boolean) {
        preferences.edit().putBoolean(KEY_SHOW_REASONING_TRACES, show).apply()
        _showReasoningTraces.value = show
    }

    fun setBoardNotificationsEnabled(boardId: String, enabled: Boolean) {
        if (boardId.isBlank()) return
        val updated = _notificationBoardIds.value.toMutableSet().apply {
            if (enabled) add(boardId) else remove(boardId)
        }.toSet()
        preferences.edit().putStringSet(KEY_NOTIFICATION_BOARD_IDS, updated).apply()
        _notificationBoardIds.value = updated
    }

    fun setProjectOrder(projectIds: List<String>) {
        val updated = projectIds.filter(String::isNotBlank).distinct()
        val encoded = JSONArray().apply { updated.forEach { put(it) } }.toString()
        preferences.edit().putString(KEY_PROJECT_ORDER, encoded).apply()
        _projectOrder.value = updated
    }

    private fun readNavigationStyle(): NavigationStyle = runCatching {
        NavigationStyle.valueOf(
            preferences.getString(KEY_NAVIGATION_STYLE, NavigationStyle.CLASSIC.name)
                ?: NavigationStyle.CLASSIC.name,
        )
    }.getOrDefault(NavigationStyle.CLASSIC)

    private fun readNotificationBoardIds(): Set<String> =
        preferences.getStringSet(KEY_NOTIFICATION_BOARD_IDS, emptySet()).orEmpty().toSet()

    private fun readProjectOrder(): List<String> = runCatching {
        val encoded = preferences.getString(KEY_PROJECT_ORDER, null) ?: return@runCatching emptyList()
        val array = JSONArray(encoded)
        buildList {
            for (index in 0 until array.length()) {
                array.optString(index).takeIf(String::isNotBlank)?.let(::add)
            }
        }.distinct()
    }.getOrDefault(emptyList())

    companion object {
        private const val PREFERENCES = "dieter_app_settings"
        private const val KEY_NAVIGATION_STYLE = "navigation_style"
        private const val KEY_SHOW_REASONING_TRACES = "show_reasoning_traces"
        private const val KEY_NOTIFICATION_BOARD_IDS = "notification_board_ids"
        private const val KEY_PROJECT_ORDER = "project_order"
    }
}
