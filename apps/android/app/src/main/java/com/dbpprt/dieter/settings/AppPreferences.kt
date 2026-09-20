package com.dbpprt.dieter.settings

import android.content.Context
import com.dbpprt.dieter.widget.DieterActivityWidgetProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import java.util.concurrent.atomic.AtomicLong

const val DEFAULT_PANE_LEADING_FRACTION = 0.43f

data class ConversationCreationPreferences(
    val provider: String = "",
    val model: String = "",
    val effort: String = "",
    val workspaceMode: String = "worktree",
)

class AppPreferences(
    context: Context,
    loadAsync: Boolean = false,
) {
    private val appContext = context.applicationContext
    val sharedNavigation by lazy { SharedKV(appContext.getSharedPreferences("dieter_shared_kv", Context.MODE_PRIVATE)) }
    val navigationFolders by lazy { NavigationFolderStore(sharedNavigation) }
    private val asyncLoading = loadAsync
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutationVersion = AtomicLong()
    private val preferences by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    }
    private val _palette = MutableStateFlow(if (loadAsync) DieterPalette.DEFAULT else readPalette())
    val palette: StateFlow<DieterPalette> = _palette.asStateFlow()
    private val _showReasoningTraces = MutableStateFlow(
        if (loadAsync) false else preferences.getBoolean(KEY_SHOW_REASONING_TRACES, false),
    )
    val showReasoningTraces: StateFlow<Boolean> = _showReasoningTraces.asStateFlow()
    private val _notificationBoardIds = MutableStateFlow(if (loadAsync) emptySet() else readNotificationBoardIds())
    val notificationBoardIds: StateFlow<Set<String>> = _notificationBoardIds.asStateFlow()
    private val _notificationSettings = MutableStateFlow(if (loadAsync) DieterNotificationSettings() else readNotificationSettings())
    val notificationSettings: StateFlow<DieterNotificationSettings> = _notificationSettings.asStateFlow()
    private val _projectOrder = MutableStateFlow<List<String>>(emptyList())
    val projectOrder: StateFlow<List<String>> = _projectOrder.asStateFlow()
    private val _collapsedChatProjectIds = MutableStateFlow<Set<String>>(emptySet())
    val collapsedChatProjectIds: StateFlow<Set<String>> = _collapsedChatProjectIds.asStateFlow()
    private val _expandedChatProjectIds = MutableStateFlow<Set<String>>(emptySet())
    val expandedChatProjectIds: StateFlow<Set<String>> = _expandedChatProjectIds.asStateFlow()
    private val _pinnedChatOrder = MutableStateFlow<List<String>>(emptyList())
    val pinnedChatOrder: StateFlow<List<String>> = _pinnedChatOrder.asStateFlow()
    private val _chatsPaneLeadingFraction = MutableStateFlow(
        if (loadAsync) DEFAULT_PANE_LEADING_FRACTION else readPaneLeadingFraction(KEY_CHATS_PANE_LEADING_FRACTION),
    )
    val chatsPaneLeadingFraction: StateFlow<Float> = _chatsPaneLeadingFraction.asStateFlow()
    private val _boardPaneLeadingFraction = MutableStateFlow(
        if (loadAsync) DEFAULT_PANE_LEADING_FRACTION else readPaneLeadingFraction(KEY_BOARD_PANE_LEADING_FRACTION),
    )
    val boardPaneLeadingFraction: StateFlow<Float> = _boardPaneLeadingFraction.asStateFlow()
    private val _conversationCreation = MutableStateFlow(
        if (loadAsync) ConversationCreationPreferences() else readConversationCreationPreferences(),
    )
    val conversationCreation: StateFlow<ConversationCreationPreferences> = _conversationCreation.asStateFlow()

    init {
        projectSharedNavigation(sharedNavigation.values.value)
        scope.launch(Dispatchers.Main.immediate) {
            sharedNavigation.values.collect { values -> projectSharedNavigation(values) }
        }
        if (loadAsync) {
            scope.launch { hydrate() }
        } else {
            DieterLauncherIcon.apply(appContext, _palette.value)
        }
    }

    private fun hydrate() {
        val expectedVersion = mutationVersion.get()
        val palette = readPalette()
        val showReasoningTraces = preferences.getBoolean(KEY_SHOW_REASONING_TRACES, false)
        val notificationBoardIds = readNotificationBoardIds()
        val notificationSettings = readNotificationSettings()
        val chatsPaneLeadingFraction = readPaneLeadingFraction(KEY_CHATS_PANE_LEADING_FRACTION)
        val boardPaneLeadingFraction = readPaneLeadingFraction(KEY_BOARD_PANE_LEADING_FRACTION)
        val conversationCreation = readConversationCreationPreferences()
        if (mutationVersion.get() != expectedVersion) return
        _palette.value = palette
        _showReasoningTraces.value = showReasoningTraces
        _notificationBoardIds.value = notificationBoardIds
        _notificationSettings.value = notificationSettings
        _chatsPaneLeadingFraction.value = chatsPaneLeadingFraction
        _boardPaneLeadingFraction.value = boardPaneLeadingFraction
        _conversationCreation.value = conversationCreation
        DieterLauncherIcon.apply(appContext, _palette.value)
    }

    private fun markMutation() {
        mutationVersion.incrementAndGet()
        if (asyncLoading) scope.launch {
            delay(25)
            hydrate()
        }
    }

    fun setPalette(palette: DieterPalette) {
        markMutation()
        preferences.edit().putString(KEY_PALETTE, palette.slug).apply()
        _palette.value = palette
        scope.launch {
            DieterLauncherIcon.apply(appContext, palette)
            DieterActivityWidgetProvider.updateAll(appContext)
        }
    }

    fun setShowReasoningTraces(show: Boolean) {
        markMutation()
        preferences.edit().putBoolean(KEY_SHOW_REASONING_TRACES, show).apply()
        _showReasoningTraces.value = show
    }

    fun setBoardNotificationsEnabled(boardId: String, enabled: Boolean) {
        if (boardId.isBlank()) return
        markMutation()
        val updated = _notificationBoardIds.value.toMutableSet().apply {
            if (enabled) add(boardId) else remove(boardId)
        }.toSet()
        preferences.edit().putStringSet(KEY_NOTIFICATION_BOARD_IDS, updated).apply()
        _notificationBoardIds.value = updated
    }

    fun setNotificationBoardIds(boardIds: Set<String>) {
        markMutation()
        val updated = boardIds.filterTo(mutableSetOf(), String::isNotBlank).toSet()
        preferences.edit().putStringSet(KEY_NOTIFICATION_BOARD_IDS, updated).apply()
        _notificationBoardIds.value = updated
    }

    fun setNotificationSettings(settings: DieterNotificationSettings) {
        markMutation()
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

    private fun projectSharedNavigation(values: Map<String,String>) {
        navigationFolders.project(values)
        _projectOrder.value = SharedNavigation.ordered(values, "projects-order")
        _pinnedChatOrder.value = SharedNavigation.ordered(values, "pinned-order")
        _collapsedChatProjectIds.value = SharedNavigation.flags(values, "chats-section", inverted = true)
        _expandedChatProjectIds.value = SharedNavigation.flags(values, "chats-disclosure")
    }

    fun setProjectOrder(projectIds: List<String>) {
        SharedNavigation.order(sharedNavigation, _projectOrder.value, projectIds.distinct(), "projects-order")
        projectSharedNavigation(sharedNavigation.values.value)
    }
    fun setChatProjectCollapsed(projectId: String, collapsed: Boolean) {
        sharedNavigation.put("chats-section.$projectId.expanded", !collapsed)
        projectSharedNavigation(sharedNavigation.values.value)
    }
    fun setChatProjectExpanded(projectId: String, expanded: Boolean) {
        sharedNavigation.put("chats-disclosure.$projectId.expanded", expanded)
        projectSharedNavigation(sharedNavigation.values.value)
    }
    fun setPinnedChatOrder(chatIds: List<String>) {
        SharedNavigation.order(sharedNavigation, _pinnedChatOrder.value, chatIds.distinct(), "pinned-order")
        projectSharedNavigation(sharedNavigation.values.value)
    }

    fun setChatsPaneLeadingFraction(fraction: Float) {
        setPaneLeadingFraction(KEY_CHATS_PANE_LEADING_FRACTION, fraction, _chatsPaneLeadingFraction)
    }

    fun setBoardPaneLeadingFraction(fraction: Float) {
        setPaneLeadingFraction(KEY_BOARD_PANE_LEADING_FRACTION, fraction, _boardPaneLeadingFraction)
    }

    private fun setPaneLeadingFraction(key: String, fraction: Float, state: MutableStateFlow<Float>) {
        if (!fraction.isFinite()) return
        val persistedFraction = fraction.coerceIn(0f, 1f)
        markMutation()
        preferences.edit().putFloat(key, persistedFraction).apply()
        state.value = persistedFraction
    }

    fun setConversationCreationPreferences(value: ConversationCreationPreferences) {
        markMutation()
        preferences.edit()
            .putString(KEY_CONVERSATION_CREATION_PROVIDER, value.provider)
            .putString(KEY_CONVERSATION_CREATION_MODEL, value.model)
            .putString(KEY_CONVERSATION_CREATION_EFFORT, value.effort)
            .putString(KEY_CONVERSATION_CREATION_WORKSPACE_MODE, value.workspaceMode)
            .apply()
        _conversationCreation.value = value
    }

    private fun readPalette(): DieterPalette = DieterPalette.resolve(
        preferences.getString(KEY_PALETTE, DieterPalette.DEFAULT.slug),
    )

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

    private fun readPaneLeadingFraction(key: String): Float =
        preferences.getFloat(key, DEFAULT_PANE_LEADING_FRACTION)
            .takeIf(Float::isFinite)
            ?.coerceIn(0f, 1f)
            ?: DEFAULT_PANE_LEADING_FRACTION

    private fun readConversationCreationPreferences() = ConversationCreationPreferences(
        provider = preferences.getString(KEY_CONVERSATION_CREATION_PROVIDER, "").orEmpty(),
        model = preferences.getString(KEY_CONVERSATION_CREATION_MODEL, "").orEmpty(),
        effort = preferences.getString(KEY_CONVERSATION_CREATION_EFFORT, "").orEmpty(),
        workspaceMode = preferences.getString(KEY_CONVERSATION_CREATION_WORKSPACE_MODE, "worktree")
            .orEmpty().ifBlank { "worktree" },
    )

    companion object {
        private const val PREFERENCES = "dieter_app_settings"
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
        private const val KEY_CHATS_PANE_LEADING_FRACTION = "chats_pane_leading_fraction"
        private const val KEY_BOARD_PANE_LEADING_FRACTION = "board_pane_leading_fraction"
        private const val KEY_CONVERSATION_CREATION_PROVIDER = "conversation_creation_provider"
        private const val KEY_CONVERSATION_CREATION_MODEL = "conversation_creation_model"
        private const val KEY_CONVERSATION_CREATION_EFFORT = "conversation_creation_effort"
        private const val KEY_CONVERSATION_CREATION_WORKSPACE_MODE = "conversation_creation_workspace_mode"

        fun selectedPalette(context: Context): DieterPalette = DieterPalette.resolve(
            context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getString(KEY_PALETTE, DieterPalette.DEFAULT.slug),
        )
    }
}
