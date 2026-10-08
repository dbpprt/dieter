package com.dbpprt.dieter.spike

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
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
        }
        intent.data?.let { store.completeSignIn(it.toString()) }
        setContent {
            val palette by store.palette.collectAsState()
            val appearance by store.appearance.collectAsState()
            val dark =
                when (appearance) {
                    "dark" -> true
                    "light" -> false
                    else -> isSystemInDarkTheme()
                }
            val background =
                Color(if (dark) palette.tokens.darkBackground else palette.tokens.light)
            SideEffect {
                val barColor = background.toArgb()
                val style =
                    if (dark) SystemBarStyle.dark(barColor)
                    else SystemBarStyle.light(barColor, barColor)
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
                // Activity recreation can leave the decor's light window background
                // beneath transparent system bars. Paint it with the active palette.
                window.decorView.setBackgroundColor(barColor)
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
            Box(Modifier.fillMaxSize().background(background).safeDrawingPadding()) {
                MobileApp(
                    store,
                    openUrl = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) },
                )
            }
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
