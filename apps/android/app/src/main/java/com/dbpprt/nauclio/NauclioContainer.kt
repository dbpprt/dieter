package com.dbpprt.nauclio

import android.content.Context
import com.dbpprt.nauclio.connection.NauclioConnectionManager
import com.dbpprt.nauclio.data.NauclioRepository
import com.dbpprt.nauclio.data.GrpcNauclioRepository
import com.dbpprt.nauclio.settings.AppPreferences
import com.dbpprt.nauclio.update.AppUpdateManager
import com.dbpprt.nauclio.widget.NauclioActivityWidgetProvider
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

data class NauclioOpenRequest(val cardId: String = "", val showConnection: Boolean = false, val nonce: Long = System.nanoTime())

class NauclioContainer(context: Context) {
    val repository: NauclioRepository = GrpcNauclioRepository(context)
    val connectionManager = NauclioConnectionManager(context, repository)
    val appPreferences = AppPreferences(context)
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
                .collect { NauclioActivityWidgetProvider.updateAll(appContext) }
        }
    }
    private val _openRequest = MutableStateFlow<NauclioOpenRequest?>(null)
    val openRequest = _openRequest.asStateFlow()

    fun requestOpen(cardId: String = "", showConnection: Boolean = false) {
        if (cardId.isNotBlank() || showConnection) _openRequest.value = NauclioOpenRequest(cardId, showConnection)
    }

    fun consumeOpenRequest(request: NauclioOpenRequest) {
        if (_openRequest.value == request) _openRequest.value = null
    }
}
