package com.dbpprt.dieter.settings

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/** Keeps the launcher's activity alias (and therefore its icon) aligned with the selected palette. */
object DieterLauncherIcon {
    private val aliases = linkedMapOf(
        DieterPalette.ELECTRIC_BLUE to "LauncherElectricBlue",
        DieterPalette.JADE_OPERATOR to "LauncherJadeOperator",
        DieterPalette.COPPER_CIRCUIT to "LauncherCopperCircuit",
        DieterPalette.ULTRAVIOLET_RELAY to "LauncherUltravioletRelay",
        DieterPalette.SOLAR_COMMAND to "LauncherSolarCommand",
        DieterPalette.ARCTIC_CONSOLE to "LauncherArcticConsole",
        DieterPalette.CORAL_SIGNAL to "LauncherCoralSignal",
        DieterPalette.ACID_TERMINAL to "LauncherAcidTerminal",
    )

    fun apply(context: Context, selected: DieterPalette) {
        val appContext = context.applicationContext
        val manager = appContext.packageManager
        val settings = aliases.map { (palette, alias) ->
            PackageManager.ComponentEnabledSetting(
                ComponentName(appContext.packageName, "${appContext.packageName}.$alias"),
                if (palette == selected) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                } else {
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                },
                PackageManager.DONT_KILL_APP,
            )
        }
        if (Build.VERSION.SDK_INT >= 33) {
            manager.setComponentEnabledSettings(settings)
        } else {
            // Enable first so launchers never observe a moment with no entry point.
            settings.sortedBy { it.enabledState != PackageManager.COMPONENT_ENABLED_STATE_ENABLED }
                .forEach { setting ->
                    val componentName = setting.componentName ?: return@forEach
                    manager.setComponentEnabledSetting(
                        componentName,
                        setting.enabledState,
                        setting.enabledFlags,
                    )
                }
        }
    }
}
