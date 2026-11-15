package com.getdieter.android

import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.core.view.WindowCompat
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.getdieter.android.update.AppUpdateDialog
import com.getdieter.mobile.app.*
import com.getdieter.mobile.desktop.DesktopKeys
import com.getdieter.mobile.navigation.MobileRoute
import com.getdieter.mobile.navigation.ToolPage
import com.getdieter.mobile.share.*
import com.getdieter.mobile.store.InterfaceMode
import com.getdieter.mobile.store.pairing
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var session: DieterSession
    private val notificationPermission =
        registerForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
        ) {
            if (::session.isInitialized) {
                session.notifications.refreshToken()
                session.runtime.refreshPushRegistration()
            }
        }
    private val store
        get() = session.store

    /** DeX, desktop windowing or a connected display; see [DesktopSignals]. */
    private var desktop by mutableStateOf(false)
    private val keys = DesktopKeys()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        session = ViewModelProvider(this)[DieterSession::class.java]
        desktop = DesktopSignals.detect(this)
        if (BuildConfig.DEBUG) {
            val url = intent.getStringExtra("fixture_url")
            val token = intent.getStringExtra("fixture_token")
            val pairingCode = intent.getStringExtra("fixture_pairing_code").orEmpty()
            if (url != null && token != null) session.adoptFixture(url, token, pairingCode)
            // Flows pick the shell: interface=desktop|touch|automatic.
            intent.getStringExtra("interface")?.let { value ->
                InterfaceMode.entries
                    .firstOrNull { it.name.equals(value, ignoreCase = true) }
                    ?.let(store.layout::setInterfaceMode)
            }
            intent.getStringExtra("script")?.let {
                if (savedInstanceState == null) store.debugScript(it)
            }
        }
        intent.data?.let { store.session.completeSignIn(it.toString()) }
        // After recreation the store already holds this share and shows its folder.
        if (savedInstanceState == null) {
            receiveShare(intent)
            openFolder(intent)
        }
        session.notifications.tap(intent)
        lifecycleScope.launch {
            lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.RESUMED) {
                store.session.slice.collect { state ->
                    if (
                        !session.fixtureAdopted &&
                            state.phase !=
                                com.getdieter.client.v1.SessionSlice.Phase.PHASE_AUTH_REQUIRED &&
                            !state.pairing &&
                            state.synced
                    )
                        requestNotificationPermission()
                }
            }
        }
        setContent {
            // Debuggable builds (debug and e2e) expose the shared Compose testTags as
            // Android resource ids, which Maestro flows select.
            Box(Modifier.semantics { testTagsAsResourceId = BuildConfig.DEBUG }) {
                MobileApp(
                    store,
                    openUrl = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) },
                    onWindow = ::styleWindow,
                    desktopHost = desktop,
                    keys = keys,
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

    // Window resizes, DeX and display moves arrive as configuration changes (see the manifest).
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        desktop = DesktopSignals.detect(this)
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        desktop = DesktopSignals.detect(this)
    }

    /**
     * The desktop shell's shortcuts while nothing in it has focus; with focus inside, the shell
     * sees them first itself.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        keys.handle(androidx.compose.ui.input.key.KeyEvent(event)) ||
            super.onKeyDown(keyCode, event)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { store.session.completeSignIn(it.toString()) }
        receiveShare(intent)
        openFolder(intent)
        session.notifications.tap(intent)
    }

    /**
     * Text and files shared from another app open as a new task; through "Save to folder…" (the
     * share sheet's second Dieter entry) the files go into a synced folder.
     */
    private fun receiveShare(intent: Intent) {
        if (!AndroidShare.isShare(intent)) return
        val folder = intent.component?.className == SAVE_TO_FOLDER
        lifecycleScope.launch {
            store.sharing.receive(
                if (folder) AndroidShare.readForFolder(applicationContext, intent)
                else AndroidShare.read(applicationContext, intent)
            )
        }
    }

    /** A folder notification opens its folder. */
    private fun openFolder(intent: Intent) {
        val folderId =
            intent.getStringExtra(com.getdieter.android.folders.FolderNotifications.EXTRA_FOLDER)
                ?: return
        intent.removeExtra(com.getdieter.android.folders.FolderNotifications.EXTRA_FOLDER)
        val list = MobileRoute.Tool(ToolPage.FOLDERS)
        store.openMore(list)
        store.showFrom(list, MobileRoute.Folder(folderId))
    }

    private companion object {
        /** The share sheet's "Save to folder…" entry (an alias of this activity). */
        const val SAVE_TO_FOLDER = "com.getdieter.android.SaveToFolder"
    }

    override fun onStart() {
        super.onStart()
        if (::session.isInitialized) store.setForeground(true)
    }

    override fun onResume() {
        super.onResume()
        if (::session.isInitialized) {
            session.updates.refreshInstallerPermission()
            session.notifications.refreshToken()
            session.runtime.refreshPushRegistration()
        }
    }

    private fun requestNotificationPermission() {
        if (android.os.Build.VERSION.SDK_INT < 33) return
        val preferences = getSharedPreferences("dieter_push", MODE_PRIVATE)
        if (preferences.getBoolean("permissionAsked", false)) return
        preferences.edit().putBoolean("permissionAsked", true).apply()
        notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
    }

    override fun onStop() {
        // Recreation (rotation, dark mode) keeps the app on screen and its connection open.
        if (::session.isInitialized && !isChangingConfigurations) store.setForeground(false)
        super.onStop()
    }
}
