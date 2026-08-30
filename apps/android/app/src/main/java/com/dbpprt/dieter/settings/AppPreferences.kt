package com.dbpprt.dieter.settings

import android.content.Context
import com.dbpprt.dieter.widget.DieterActivityWidgetProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray

enum class NavigationStyle { CLASSIC, GLASS }

class AppPreferences(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val _navigationStyle = MutableStateFlow(readNavigationStyle())
    val navigationStyle: StateFlow<NavigationStyle> = _navigationStyle.asStateFlow()
    private val _palette = MutableStateFlow(readPalette())
    val palette: StateFlow<DieterPalette> = _palette.asStateFlow()
    private val _showReasoningTraces = MutableStateFlow(
        preferences.getBoolean(KEY_SHOW_REASONING_TRACES, false),
    )
    val showReasoningTraces: StateFlow<Boolean> = _showReasoningTraces.asStateFlow()
    private val _notificationBoardIds = MutableStateFlow(readNotificationBoardIds())
    val notificationBoardIds: StateFlow<Set<String>> = _notificationBoardIds.asStateFlow()
    private val _notificationSettings = MutableStateFlow(readNotificationSettings())
    val notificationSettings: StateFlow<DieterNotificationSettings> = _notificationSettings.asStateFlow()
    private val _projectOrder = MutableStateFlow(readProjectOrder())
    val projectOrder: StateFlow<List<String>> = _projectOrder.asStateFlow()
    private val _pinnedChatOrder = MutableStateFlow(readPinnedChatOrder())
    val pinnedChatOrder: StateFlow<List<String>> = _pinnedChatOrder.asStateFlow()

    init {
        DieterLauncherIcon.apply(appContext, _palette.value)
    }

    fun setNavigationStyle(style: NavigationStyle) {
        preferences.edit().putString(KEY_NAVIGATION_STYLE, style.name).apply()
        _navigationStyle.value = style
    }

    fun setPalette(palette: DieterPalette) {
        preferences.edit().putString(KEY_PALETTE, palette.slug).apply()
        _palette.value = palette
        DieterLauncherIcon.apply(appContext, palette)
        DieterActivityWidgetProvider.updateAll(appContext)
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

    fun setNotificationBoardIds(boardIds: Set<String>) {
        val updated = boardIds.filterTo(mutableSetOf(), String::isNotBlank).toSet()
        preferences.edit().putStringSet(KEY_NOTIFICATION_BOARD_IDS, updated).apply()
        _notificationBoardIds.value = updated
    }

    fun setNotificationSettings(settings: DieterNotificationSettings) {
        preferences.edit()
            .putBoolean(KEY_ACTIVITY_NOTIFICATIONS_ENABLED, settings.activityNotificationsEnabled)
            .putBoolean(KEY_RUNNING_CHATS_ENABLED, settings.runningChatsEnabled)
            .putBoolean(KEY_SUCCESSFUL_CHATS_ENABLED, settings.successfulChatsEnabled)
            .putBoolean(KEY_ATTENTION_CHATS_ENABLED, settings.attentionChatsEnabled)
            .putBoolean(KEY_REVIEW_CARDS_ENABLED, settings.reviewCardsEnabled)
            .putString(KEY_NOTIFICATION_DISPLAY_STYLE, settings.displayStyle.name)
            .putBoolean(KEY_RESULT_PREVIEWS_ENABLED, settings.resultPreviewsEnabled)
            .putBoolean(KEY_LIVE_STATUS_ACTIVITY_ENABLED, settings.liveStatusActivityEnabled)
            .apply()
        _notificationSettings.value = settings
    }

    fun setProjectOrder(projectIds: List<String>) {
        val updated = projectIds.filter(String::isNotBlank).distinct()
        val encoded = JSONArray().apply { updated.forEach { put(it) } }.toString()
        preferences.edit().putString(KEY_PROJECT_ORDER, encoded).apply()
        _projectOrder.value = updated
    }

    fun setPinnedChatOrder(chatIds: List<String>) {
        val updated = chatIds.filter(String::isNotBlank).distinct()
        val encoded = JSONArray().apply { updated.forEach { put(it) } }.toString()
        preferences.edit().putString(KEY_PINNED_CHAT_ORDER, encoded).apply()
        _pinnedChatOrder.value = updated
    }

    private fun readNavigationStyle(): NavigationStyle = runCatching {
        NavigationStyle.valueOf(
            preferences.getString(KEY_NAVIGATION_STYLE, NavigationStyle.CLASSIC.name)
                ?: NavigationStyle.CLASSIC.name,
        )
    }.getOrDefault(NavigationStyle.CLASSIC)

    private fun readPalette(): DieterPalette = selectedPalette(appContext)

    private fun readNotificationBoardIds(): Set<String> =
        preferences.getStringSet(KEY_NOTIFICATION_BOARD_IDS, emptySet()).orEmpty().toSet()

    private fun readNotificationSettings(): DieterNotificationSettings = DieterNotificationSettings(
        activityNotificationsEnabled = preferences.getBoolean(KEY_ACTIVITY_NOTIFICATIONS_ENABLED, true),
        runningChatsEnabled = preferences.getBoolean(KEY_RUNNING_CHATS_ENABLED, true),
        successfulChatsEnabled = preferences.getBoolean(KEY_SUCCESSFUL_CHATS_ENABLED, true),
        attentionChatsEnabled = preferences.getBoolean(KEY_ATTENTION_CHATS_ENABLED, true),
        reviewCardsEnabled = preferences.getBoolean(KEY_REVIEW_CARDS_ENABLED, true),
        displayStyle = runCatching {
            NotificationDisplayStyle.valueOf(
                preferences.getString(KEY_NOTIFICATION_DISPLAY_STYLE, NotificationDisplayStyle.DETAILED.name)
                    ?: NotificationDisplayStyle.DETAILED.name,
            )
        }.getOrDefault(NotificationDisplayStyle.DETAILED),
        resultPreviewsEnabled = preferences.getBoolean(KEY_RESULT_PREVIEWS_ENABLED, true),
        liveStatusActivityEnabled = preferences.getBoolean(KEY_LIVE_STATUS_ACTIVITY_ENABLED, true),
    )

    private fun readProjectOrder(): List<String> = runCatching {
        val encoded = preferences.getString(KEY_PROJECT_ORDER, null) ?: return@runCatching emptyList()
        val array = JSONArray(encoded)
        buildList {
            for (index in 0 until array.length()) {
                array.optString(index).takeIf(String::isNotBlank)?.let(::add)
            }
        }.distinct()
    }.getOrDefault(emptyList())

    private fun readPinnedChatOrder(): List<String> = runCatching {
        val encoded = preferences.getString(KEY_PINNED_CHAT_ORDER, null) ?: return@runCatching emptyList()
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
        private const val KEY_PALETTE = "palette"
        private const val KEY_SHOW_REASONING_TRACES = "show_reasoning_traces"
        private const val KEY_NOTIFICATION_BOARD_IDS = "notification_board_ids"
        private const val KEY_ACTIVITY_NOTIFICATIONS_ENABLED = "activity_notifications_enabled"
        private const val KEY_RUNNING_CHATS_ENABLED = "running_chats_enabled"
        private const val KEY_SUCCESSFUL_CHATS_ENABLED = "successful_chats_enabled"
        private const val KEY_ATTENTION_CHATS_ENABLED = "attention_chats_enabled"
        private const val KEY_REVIEW_CARDS_ENABLED = "review_cards_enabled"
        private const val KEY_NOTIFICATION_DISPLAY_STYLE = "notification_display_style"
        private const val KEY_RESULT_PREVIEWS_ENABLED = "result_previews_enabled"
        private const val KEY_LIVE_STATUS_ACTIVITY_ENABLED = "live_status_activity_enabled"
        private const val KEY_PROJECT_ORDER = "project_order"
        private const val KEY_PINNED_CHAT_ORDER = "pinned_chat_order"

        fun selectedPalette(context: Context): DieterPalette = DieterPalette.resolve(
            context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getString(KEY_PALETTE, DieterPalette.DEFAULT.slug),
        )
    }
}
