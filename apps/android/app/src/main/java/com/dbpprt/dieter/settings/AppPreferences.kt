package com.dbpprt.dieter.settings

import android.content.Context
import com.dbpprt.dieter.widget.DieterActivityWidgetProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong

const val DEFAULT_PANE_LEADING_FRACTION = 0.43f
const val DEFAULT_SIDEBAR_LEADING_FRACTION = 0.32f

/**
 * This device's appearance choices: palette, reasoning traces, and pane
 * sizes. Everything else the app remembers (navigation, creation choices,
 * notification settings, drafts) is owned by the shared core.
 */
class AppPreferences(
    context: Context,
    loadAsync: Boolean = false,
) {
    private val appContext = context.applicationContext
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
    private val _chatsPaneLeadingFraction = MutableStateFlow(
        if (loadAsync) DEFAULT_PANE_LEADING_FRACTION else readPaneLeadingFraction(KEY_CHATS_PANE_LEADING_FRACTION),
    )
    val chatsPaneLeadingFraction: StateFlow<Float> = _chatsPaneLeadingFraction.asStateFlow()
    private val _boardPaneLeadingFraction = MutableStateFlow(
        if (loadAsync) DEFAULT_PANE_LEADING_FRACTION else readPaneLeadingFraction(KEY_BOARD_PANE_LEADING_FRACTION),
    )
    val boardPaneLeadingFraction: StateFlow<Float> = _boardPaneLeadingFraction.asStateFlow()
    private val _activityPaneLeadingFraction = MutableStateFlow(
        if (loadAsync) DEFAULT_SIDEBAR_LEADING_FRACTION else readPaneLeadingFraction(KEY_ACTIVITY_PANE_LEADING_FRACTION, DEFAULT_SIDEBAR_LEADING_FRACTION),
    )
    val activityPaneLeadingFraction: StateFlow<Float> = _activityPaneLeadingFraction.asStateFlow()
    private val _projectsPaneLeadingFraction = MutableStateFlow(
        if (loadAsync) DEFAULT_SIDEBAR_LEADING_FRACTION else readPaneLeadingFraction(KEY_PROJECTS_PANE_LEADING_FRACTION, DEFAULT_SIDEBAR_LEADING_FRACTION),
    )
    val projectsPaneLeadingFraction: StateFlow<Float> = _projectsPaneLeadingFraction.asStateFlow()

    init {
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
        val chatsPaneLeadingFraction = readPaneLeadingFraction(KEY_CHATS_PANE_LEADING_FRACTION)
        val boardPaneLeadingFraction = readPaneLeadingFraction(KEY_BOARD_PANE_LEADING_FRACTION)
        val activityPaneLeadingFraction = readPaneLeadingFraction(KEY_ACTIVITY_PANE_LEADING_FRACTION, DEFAULT_SIDEBAR_LEADING_FRACTION)
        val projectsPaneLeadingFraction = readPaneLeadingFraction(KEY_PROJECTS_PANE_LEADING_FRACTION, DEFAULT_SIDEBAR_LEADING_FRACTION)
        if (mutationVersion.get() != expectedVersion) return
        _palette.value = palette
        _showReasoningTraces.value = showReasoningTraces
        _chatsPaneLeadingFraction.value = chatsPaneLeadingFraction
        _boardPaneLeadingFraction.value = boardPaneLeadingFraction
        _activityPaneLeadingFraction.value = activityPaneLeadingFraction
        _projectsPaneLeadingFraction.value = projectsPaneLeadingFraction
        DieterLauncherIcon.apply(appContext, _palette.value)
    }

    private fun markMutation() {
        mutationVersion.incrementAndGet()
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

    fun setChatsPaneLeadingFraction(fraction: Float) {
        setPaneLeadingFraction(KEY_CHATS_PANE_LEADING_FRACTION, fraction, _chatsPaneLeadingFraction)
    }

    fun setBoardPaneLeadingFraction(fraction: Float) {
        setPaneLeadingFraction(KEY_BOARD_PANE_LEADING_FRACTION, fraction, _boardPaneLeadingFraction)
    }

    fun setActivityPaneLeadingFraction(fraction: Float) {
        setPaneLeadingFraction(KEY_ACTIVITY_PANE_LEADING_FRACTION, fraction, _activityPaneLeadingFraction)
    }

    fun setProjectsPaneLeadingFraction(fraction: Float) {
        setPaneLeadingFraction(KEY_PROJECTS_PANE_LEADING_FRACTION, fraction, _projectsPaneLeadingFraction)
    }

    private fun setPaneLeadingFraction(key: String, fraction: Float, state: MutableStateFlow<Float>) {
        if (!fraction.isFinite()) return
        val persistedFraction = fraction.coerceIn(0f, 1f)
        markMutation()
        preferences.edit().putFloat(key, persistedFraction).apply()
        state.value = persistedFraction
    }

    private fun readPalette(): DieterPalette = DieterPalette.resolve(
        preferences.getString(KEY_PALETTE, DieterPalette.DEFAULT.slug),
    )

    private fun readPaneLeadingFraction(key: String, default: Float = DEFAULT_PANE_LEADING_FRACTION): Float =
        preferences.getFloat(key, default)
            .takeIf(Float::isFinite)
            ?.coerceIn(0f, 1f)
            ?: default

    companion object {
        private const val PREFERENCES = "dieter_app_settings"
        private const val KEY_PALETTE = "palette"
        private const val KEY_SHOW_REASONING_TRACES = "show_reasoning_traces"
        private const val KEY_CHATS_PANE_LEADING_FRACTION = "chats_pane_leading_fraction"
        private const val KEY_ACTIVITY_PANE_LEADING_FRACTION = "activity_pane_leading_fraction"
        private const val KEY_PROJECTS_PANE_LEADING_FRACTION = "projects_pane_leading_fraction"
        private const val KEY_BOARD_PANE_LEADING_FRACTION = "board_pane_leading_fraction"

        fun selectedPalette(context: Context): DieterPalette = DieterPalette.resolve(
            context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getString(KEY_PALETTE, DieterPalette.DEFAULT.slug),
        )
    }
}
