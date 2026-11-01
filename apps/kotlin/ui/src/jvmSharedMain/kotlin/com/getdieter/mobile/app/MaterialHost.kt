package com.getdieter.mobile.app

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontFamily
import com.getdieter.mobile.design.*
import com.getdieter.mobile.desktop.DesktopKeys
import com.getdieter.mobile.desktop.DesktopShell
import com.getdieter.mobile.desktop.DesktopTheme
import com.getdieter.mobile.desktop.tokens
import com.getdieter.mobile.resources.Res
import com.getdieter.mobile.resources.sora_variable
import com.getdieter.mobile.store.*
import org.jetbrains.compose.resources.Font

/**
 * The Material host used on Android and in JVM tests; iOS hosts each route natively, so this and
 * the desktop shell are compiled for Android and the JVM only. [onWindow] receives the theme's
 * darkness and background ARGB so the host can style its window.
 *
 * [desktopHost] is the platform's desktop signal (Samsung DeX, Android desktop windowing, a
 * connected display, a PC); with it, or with the Desktop interface chosen in Settings, a window
 * large enough shows the desktop shell. [keys] lets the host hand it keyboard shortcuts.
 */
@Composable
fun MobileApp(
    store: MobileStore,
    openUrl: (String) -> Unit = {},
    onWindow: (dark: Boolean, background: Int) -> Unit = { _, _ -> },
    desktopHost: Boolean = false,
    keys: DesktopKeys? = null,
) {
    val signInUrl by store.session.signInUrl.collectAsState()
    LaunchedEffect(signInUrl) {
        if (signInUrl.isNotEmpty()) {
            openUrl(signInUrl)
            store.session.signInUrl.value = ""
        }
    }
    MobileTheme(store, apple = false) {
        val dark = store.isDark()
        val mode by store.layout.interfaceMode.collectAsState()
        val selected by store.theme.palette.collectAsState()
        CompositionLocalProvider(LocalMobileStore provides store) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                if (DesktopLayout.shows(mode, desktopHost, maxWidth.value, maxHeight.value)) {
                    DesktopTheme(selected, dark, FontFamily(Font(Res.font.sora_variable))) {
                        val canvas = tokens.canvas.toArgb()
                        SideEffect { onWindow(dark, canvas) }
                        DesktopShell(store, openUrl, keys)
                    }
                } else {
                    val background = palette.background.toArgb()
                    SideEffect { onWindow(dark, background) }
                    Surface(Modifier.fillMaxSize(), color = palette.background) {
                        MaterialShell(store, openUrl)
                    }
                }
            }
        }
    }
}
