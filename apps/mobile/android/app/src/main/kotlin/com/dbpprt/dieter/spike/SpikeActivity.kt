package com.dbpprt.dieter.spike

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.view.WindowCompat
import androidx.lifecycle.ViewModelProvider
import com.dbpprt.dieter.mobile.*

class SpikeActivity : ComponentActivity() {
    private lateinit var session: SpikeSession
    private val store
        get() = session.store

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        session = ViewModelProvider(this)[SpikeSession::class.java]
        if (BuildConfig.DEBUG) {
            val url = intent.getStringExtra("fixture_url")
            val token = intent.getStringExtra("fixture_token")
            if (url != null && token != null) session.adoptFixture(url, token)
            intent.getStringExtra("script")?.let {
                if (savedInstanceState == null) store.debugScript(it)
            }
        }
        intent.data?.let { store.completeSignIn(it.toString()) }
        setContent {
            MobileApp(
                store,
                openUrl = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) },
                onWindow = ::styleWindow,
            )
        }
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
    }

    override fun onStart() {
        super.onStart()
        if (::session.isInitialized) store.setForeground(true)
    }

    override fun onStop() {
        if (::session.isInitialized) store.setForeground(false)
        super.onStop()
    }
}
