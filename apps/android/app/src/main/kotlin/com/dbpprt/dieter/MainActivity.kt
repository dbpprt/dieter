package com.dbpprt.dieter

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.core.view.WindowCompat
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import com.dbpprt.dieter.mobile.*
import com.dbpprt.dieter.update.AppUpdateDialog
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var session: DieterSession
    private val store
        get() = session.store

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        session = ViewModelProvider(this)[DieterSession::class.java]
        if (BuildConfig.DEBUG) {
            val url = intent.getStringExtra("fixture_url")
            val token = intent.getStringExtra("fixture_token")
            if (url != null && token != null) session.adoptFixture(url, token)
            intent.getStringExtra("script")?.let {
                if (savedInstanceState == null) store.debugScript(it)
            }
        }
        intent.data?.let { store.completeSignIn(it.toString()) }
        // After recreation the store already holds this share.
        if (savedInstanceState == null) receiveShare(intent)
        setContent {
            Box {
                MobileApp(
                    store,
                    openUrl = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) },
                    onWindow = ::styleWindow,
                )
                AppUpdateDialog(session.updates)
            }
        }
        if (session.updates.automaticChecksEnabled) session.updates.checkForUpdates()
    }

    /** Transparent system bars whose icons follow the app's appearance. */
    private fun styleWindow(dark: Boolean, background: Int) {
        val transparent = android.graphics.Color.TRANSPARENT
        val style =
            if (dark) SystemBarStyle.dark(transparent)
            else SystemBarStyle.light(transparent, transparent)
        enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
        if (android.os.Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
        // Activity recreation can leave the decor's light window background
        // beneath transparent system bars. Paint it with the app's background.
        window.decorView.setBackgroundColor(background)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !dark
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { store.completeSignIn(it.toString()) }
        receiveShare(intent)
    }

    /** Text and files shared from another app open as a new task. */
    private fun receiveShare(intent: Intent) {
        if (!AndroidShare.isShare(intent)) return
        lifecycleScope.launch { store.share(AndroidShare.read(applicationContext, intent)) }
    }

    override fun onStart() {
        super.onStart()
        if (::session.isInitialized) store.setForeground(true)
    }

    override fun onResume() {
        super.onResume()
        if (::session.isInitialized) session.updates.refreshInstallerPermission()
    }

    override fun onStop() {
        if (::session.isInitialized) store.setForeground(false)
        super.onStop()
    }
}
