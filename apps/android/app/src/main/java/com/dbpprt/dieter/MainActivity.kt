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
            statusBarStyle = SystemBarStyle.auto(
                android.graphics.Color.TRANSPARENT,
                android.graphics.Color.TRANSPARENT,
            ),
            navigationBarStyle = SystemBarStyle.auto(
                android.graphics.Color.TRANSPARENT,
                android.graphics.Color.TRANSPARENT,
            ),
        )
        val container = (application as DieterApplication).container
        val captureId = savedInstanceState?.getString(com.dbpprt.dieter.ui.TaskCaptureStore.CAPTURE_ID)
        if (captureId != null) {
            intent.putExtra(com.dbpprt.dieter.ui.TaskCaptureStore.CAPTURE_ID, captureId)
            // The persisted draft is the source of truth after recreation. Never re-import.
            intent.action = Intent.ACTION_MAIN
        } else {
            intent.removeExtra(com.dbpprt.dieter.ui.TaskCaptureStore.CAPTURE_ID)
        }
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
        intent.removeExtra(com.dbpprt.dieter.ui.TaskCaptureStore.CAPTURE_ID)
        setIntent(intent)
        handleIntent(intent, (application as DieterApplication).container)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        intent?.getStringExtra(com.dbpprt.dieter.ui.TaskCaptureStore.CAPTURE_ID)?.let {
            outState.putString(com.dbpprt.dieter.ui.TaskCaptureStore.CAPTURE_ID, it)
        }
        super.onSaveInstanceState(outState)
    }

    private fun handleIntent(intent: Intent?, container: DieterContainer) {
        intent?.let(container.taskCaptures::receive)
        intent?.data?.takeIf { it.scheme == "dieter-android" && it.host == "oauth" }?.let(container::completeSignIn)
        container.requestOpen(
            cardId = intent?.getStringExtra(DieterSyncService.EXTRA_CARD_ID).orEmpty(),
            showInbox = intent?.getBooleanExtra(com.dbpprt.dieter.widget.DieterActivityWidgetProvider.EXTRA_OPEN_INBOX, false) == true ||
                intent?.getBooleanExtra(com.dbpprt.dieter.widget.DieterUsageWidgetProvider.EXTRA_OPEN_ACCOUNTS, false) == true,
            showConnection = intent?.getBooleanExtra(DieterSyncService.EXTRA_SHOW_CONNECTION, false) == true,
        )
    }
}
