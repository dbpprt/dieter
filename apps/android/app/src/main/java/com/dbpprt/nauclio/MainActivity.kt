package com.dbpprt.nauclio

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.dbpprt.nauclio.ui.NauclioApp
import com.dbpprt.nauclio.ui.theme.NauclioTheme
import com.dbpprt.nauclio.connection.NauclioSyncService

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        val container = (application as NauclioApplication).container
        handleIntent(intent, container)
        setContent {
            NauclioTheme {
                NauclioApp(container)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent, (application as NauclioApplication).container)
    }

    private fun handleIntent(intent: Intent?, container: NauclioContainer) {
        intent?.data?.let(container.connectionManager::completeAuthentication)
        container.requestOpen(
            cardId = intent?.getStringExtra(NauclioSyncService.EXTRA_CARD_ID).orEmpty(),
            showConnection = intent?.getBooleanExtra(NauclioSyncService.EXTRA_SHOW_CONNECTION, false) == true,
        )
    }
}
