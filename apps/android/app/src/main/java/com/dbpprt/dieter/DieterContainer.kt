package com.dbpprt.dieter

import android.content.Context
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.data.GrpcDieterRepository
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.update.AppUpdateManager
import com.dbpprt.dieter.widget.DieterActivityWidgetProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

data class DieterOpenRequest(val cardId: String = "", val showConnection: Boolean = false, val nonce: Long = System.nanoTime())

class DieterContainer(context: Context) {
    val repository: DieterRepository = GrpcDieterRepository(context)
    val connectionManager = DieterConnectionManager(context, repository)
    val appPreferences = AppPreferences(context, loadAsync = true)
    val appUpdateManager = AppUpdateManager(context)
    private val widgetScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    init {
        // Keep home-screen widgets in step with the sync stream. The
        // fingerprint deliberately ignores per-token conversation deltas so
        // streaming responses don't spam the widget host.
        val appContext = context.applicationContext
        @OptIn(FlowPreview::class)
        widgetScope.launch {
            connectionManager.state
                .map { state -> Triple(state.cards, state.chats, state.projectHosts) }
                .distinctUntilChanged()
                .debounce(1_500)
                .collect { DieterActivityWidgetProvider.updateAll(appContext) }
        }
    }
    private val _openRequest = MutableStateFlow<DieterOpenRequest?>(null)
    val openRequest = _openRequest.asStateFlow()

    fun requestOpen(cardId: String = "", showConnection: Boolean = false) {
        if (cardId.isNotBlank() || showConnection) _openRequest.value = DieterOpenRequest(cardId, showConnection)
    }

    fun consumeOpenRequest(request: DieterOpenRequest) {
        if (_openRequest.value == request) _openRequest.value = null
    }
}
