package com.dbpprt.nauclio

import android.content.Context
import com.dbpprt.nauclio.connection.NauclioConnectionManager
import com.dbpprt.nauclio.data.NauclioRepository
import com.dbpprt.nauclio.data.GrpcNauclioRepository
import com.dbpprt.nauclio.settings.AppPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class NauclioOpenRequest(val cardId: String = "", val showConnection: Boolean = false, val nonce: Long = System.nanoTime())

class NauclioContainer(context: Context) {
    val repository: NauclioRepository = GrpcNauclioRepository(context)
    val connectionManager = NauclioConnectionManager(context, repository)
    val appPreferences = AppPreferences(context)
    private val _openRequest = MutableStateFlow<NauclioOpenRequest?>(null)
    val openRequest = _openRequest.asStateFlow()

    fun requestOpen(cardId: String = "", showConnection: Boolean = false) {
        if (cardId.isNotBlank() || showConnection) _openRequest.value = NauclioOpenRequest(cardId, showConnection)
    }

    fun consumeOpenRequest(request: NauclioOpenRequest) {
        if (_openRequest.value == request) _openRequest.value = null
    }
}
