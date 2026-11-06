package com.getdieter.android

import android.app.Activity
import android.content.res.Configuration
import android.os.Build
import android.view.Display

/**
 * Whether this window runs on a desktop, so the Automatic interface shows the desktop shell:
 * Samsung DeX, a desk dock, a PC, a connected display, or Android's desktop windowing.
 */
internal object DesktopSignals {
    /** What the platform reports about one window. */
    data class Window(
        /** Samsung's `Configuration.semDesktopModeEnabled` equals `SEM_DESKTOP_MODE_ENABLED`. */
        val samsungDex: Boolean,
        val uiModeType: Int,
        /** `android.hardware.type.pc`, e.g. ChromeOS and Android PCs. */
        val pc: Boolean,
        val displayId: Int,
        /** `Configuration.toString()`, which names the window's windowing mode. */
        val configuration: String,
    )

    fun desktop(window: Window): Boolean =
        window.samsungDex ||
            window.uiModeType == Configuration.UI_MODE_TYPE_DESK ||
            window.pc ||
            // Connected displays (DeX on a monitor, Android 16 external displays) are not the
            // phone's own screen.
            window.displayId != Display.DEFAULT_DISPLAY ||
            // Desktop windowing runs tasks in freeform windows; the mode has no public API.
            window.configuration.contains("mWindowingMode=freeform")

    fun detect(activity: Activity): Boolean {
        val configuration = activity.resources.configuration
        val display =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) activity.display
            else @Suppress("DEPRECATION") activity.windowManager.defaultDisplay
        return desktop(
            Window(
                samsungDex = samsungDex(configuration),
                uiModeType = configuration.uiMode and Configuration.UI_MODE_TYPE_MASK,
                pc = activity.packageManager.hasSystemFeature("android.hardware.type.pc"),
                displayId = display?.displayId ?: Display.DEFAULT_DISPLAY,
                configuration = configuration.toString(),
            )
        )
    }

    private fun samsungDex(configuration: Configuration): Boolean = runCatching {
        val type = configuration.javaClass
        type.getField("SEM_DESKTOP_MODE_ENABLED").getInt(type) ==
            type.getField("semDesktopModeEnabled").getInt(configuration)
    }
        .getOrDefault(false)
}
