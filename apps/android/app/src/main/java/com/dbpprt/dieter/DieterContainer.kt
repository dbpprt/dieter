package com.dbpprt.dieter

import android.content.Context
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.data.GrpcDieterRepository
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.ui.ConversationDraftStore
import com.dbpprt.dieter.ui.SharedPreferencesConversationDraftPersistence
import com.dbpprt.dieter.update.AppUpdateManager
import com.dbpprt.dieter.widget.DieterActivityWidgetProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

data class DieterOpenRequest(val cardId: String = "", val showConnection: Boolean = false, val showInbox: Boolean = false, val nonce: Long = System.nanoTime())

class DieterContainer(context: Context) {
    val repository: DieterRepository = GrpcDieterRepository(context)
    val connectionManager = DieterConnectionManager(context, repository)
    val appPreferences = AppPreferences(context, loadAsync = true)
    internal val conversationDrafts = ConversationDraftStore(
        persistence = SharedPreferencesConversationDraftPersistence(context),
    )
    val appUpdateManager = AppUpdateManager(context)
    private val widgetScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    init {
        // Conflate while rendering instead of debouncing an active stream:
        // continuous changes must never starve the home-screen update.
        val appContext = context.applicationContext
        widgetScope.launch {
            connectionManager.state.combine(appPreferences.palette) { state, palette ->
                Triple(state.activeGatewayId, palette,
                    DieterActivityWidgetProvider.model(state,
                        com.dbpprt.dieter.widget.WidgetConfig(maxItems = 20), compact = false))
            }
                .distinctUntilChanged()
                .conflate()
                .collect {
                    DieterActivityWidgetProvider.updateAll(appContext)
                    delay(1_500)
                }
        }
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
