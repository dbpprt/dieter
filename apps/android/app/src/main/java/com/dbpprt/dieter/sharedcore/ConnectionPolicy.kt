package com.dbpprt.dieter.sharedcore

import android.content.Context
import com.dbpprt.dieter.connection.DieterSyncService
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.admin.BackgroundPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * When the core may stay connected. The core owns the policy
 * ([BackgroundPolicy]); Android owns the foreground state, the sync service,
 * and its periodic windows.
 */
class ConnectionPolicy(
    context: Context,
    private val core: CoreRuntime,
    /** Starts or stops the background sync service; isolated tests pass a no-op. */
    private val backgroundService: (Context, Boolean) -> Unit = { appContext, run ->
        if (run) DieterSyncService.start(appContext) else DieterSyncService.stop(appContext)
    },
) {
    private data class Flags(
        val foreground: Boolean = false,
        val serviceActive: Boolean = false,
        val periodicWindow: Boolean = false,
        val widgetRefreshes: Int = 0,
    )

    private val appContext = context.applicationContext
    private val settings = SharedCore.settings(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val flags = MutableStateFlow(Flags())
    private val mutableMode = MutableStateFlow(BackgroundMode.parse(settings.string(BackgroundPolicy.MODE_KEY)))
    val mode: StateFlow<BackgroundMode> = mutableMode.asStateFlow()

    /** The user's stay-connected choice for the active gateway. */
    val desired: StateFlow<Boolean> get() = mutableDesired
    private val mutableDesired = MutableStateFlow(core.accounts.state.value.wantsConnection)

    init {
        scope.launch {
            core.accounts.state.map { it.wantsConnection }.distinctUntilChanged().collect { wants ->
                mutableDesired.value = wants
                // The boot receiver reads this before the core exists.
                settings.putString(BackgroundPolicy.DESIRED_KEY, wants.toString())
            }
        }
        scope.launch {
            combine(flags, mutableDesired, mutableMode) { flags, desired, mode ->
                BackgroundPolicy.shouldRun(desired, mode, flags.foreground, flags.serviceActive, flags.periodicWindow, flags.widgetRefreshes > 0)
            }.distinctUntilChanged().collect(core::setActive)
        }
        scope.launch {
            combine(mutableDesired, mutableMode) { desired, mode -> desired && mode.usesBackgroundService }
                .distinctUntilChanged()
                .collect { run -> backgroundService(appContext, run) }
        }
    }

    fun setForeground(value: Boolean) = flags.update { it.copy(foreground = value) }

    fun setServiceActive(value: Boolean) = flags.update { it.copy(serviceActive = value, periodicWindow = value && it.periodicWindow) }

    fun setPeriodicWindow(value: Boolean) = flags.update { it.copy(periodicWindow = value) }

    /** Both widget providers can refresh concurrently without closing each other's connection. */
    suspend fun <T> withWidgetRefresh(block: suspend () -> T): T {
        flags.update { it.copy(widgetRefreshes = it.widgetRefreshes + 1) }
        try {
            return block()
        } finally {
            flags.update { it.copy(widgetRefreshes = it.widgetRefreshes - 1) }
        }
    }

    fun setMode(value: BackgroundMode) {
        settings.putString(BackgroundPolicy.MODE_KEY, value.wire)
        mutableMode.value = value
    }
}
