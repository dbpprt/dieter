package com.dbpprt.dieter

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.dbpprt.dieter.connection.AndroidNotifications
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.sharedcore.ConnectionPolicy
import com.dbpprt.dieter.sharedcore.SharedCore
import com.dbpprt.dieter.ui.AppHost
import com.dbpprt.dieter.ui.TaskCaptureStore
import com.dbpprt.dieter.update.AppUpdateManager
import com.dbpprt.dieter.widget.DieterActivityWidgetProvider
import com.dbpprt.dieter.widget.DieterUsageWidgetProvider
import com.dbpprt.dieter.widget.WidgetUsagePrefs
import com.dbpprt.dieter.widget.usageSnapshots
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

data class DieterOpenRequest(val cardId: String = "", val showConnection: Boolean = false, val showInbox: Boolean = false, val nonce: Long = System.nanoTime())

/**
 * App-scoped objects. The shared core owns all client logic; Android supplies
 * its platform services, the connection policy, and the app's appearance.
 */
class DieterContainer(context: Context) : AppHost {
    private val appContext = context.applicationContext
    val notifications = AndroidNotifications(appContext)
    val core: CoreRuntime = SharedCore.create(appContext, notifications)
    val policy = ConnectionPolicy(appContext, core)
    val appPreferences = AppPreferences(context, loadAsync = true)
    internal val taskCaptures = TaskCaptureStore(appContext, core)
    val appUpdateManager = AppUpdateManager(context)
    private val widgetScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    init {
        notifications.bind(core, appPreferences)
        core.start()
        // Conflate while rendering instead of debouncing an active stream:
        // continuous changes must never starve the home-screen update.
        widgetScope.launch {
            combine(
                core.workspace.state.map { it.allItems },
                core.connection.state.map { it.phase to it.gateway?.origin },
                appPreferences.palette,
            ) { items, connection, palette -> listOf(items, connection, palette) }
                .distinctUntilChanged()
                .conflate()
                .collect {
                    DieterActivityWidgetProvider.updateAll(appContext)
                    DieterUsageWidgetProvider.updateAll(appContext)
                    delay(1_500)
                }
        }
        widgetScope.launch {
            core.quotas.view.map { it.groups to it.live }.distinctUntilChanged().collect { (groups, live) ->
                // Only an actual gateway frame can replace the persisted cache.
                // Startup and a paused connection both begin with no live data.
                if (live) WidgetUsagePrefs.saveCache(appContext, usageSnapshots(groups), System.currentTimeMillis())
                DieterUsageWidgetProvider.updateAll(appContext)
            }
        }
    }

    override fun openUrl(url: String) {
        appContext.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Completes OAuth sign-in from the redirect deep link. */
    fun completeSignIn(uri: Uri) {
        widgetScope.launch { runCatching { core.completeSignIn(uri.toString()) } }
    }

    private val _openRequest = MutableStateFlow<DieterOpenRequest?>(null)
    val openRequest = _openRequest.asStateFlow()

    fun requestOpen(cardId: String = "", showConnection: Boolean = false, showInbox: Boolean = false) {
        if (cardId.isNotBlank() || showConnection || showInbox) _openRequest.value = DieterOpenRequest(cardId, showConnection, showInbox)
    }

    fun consumeOpenRequest(request: DieterOpenRequest) {
        if (_openRequest.value == request) _openRequest.value = null
    }
}
