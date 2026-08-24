package com.dbpprt.dieter

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dbpprt.dieter.ui.DieterApp
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.connection.DieterSyncService

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        val container = (application as DieterApplication).container
        handleIntent(intent, container)
        setContent {
            val palette by container.appPreferences.palette.collectAsStateWithLifecycle()
            DieterTheme(palette) {
                DieterApp(container)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent, (application as DieterApplication).container)
    }

    private fun handleIntent(intent: Intent?, container: DieterContainer) {
        intent?.data?.let(container.connectionManager::completeAuthentication)
        container.requestOpen(
            cardId = intent?.getStringExtra(DieterSyncService.EXTRA_CARD_ID).orEmpty(),
            showConnection = intent?.getBooleanExtra(DieterSyncService.EXTRA_SHOW_CONNECTION, false) == true,
        )
    }
}
