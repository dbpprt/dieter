package com.dbpprt.dieter.settings

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/** Keeps the launcher's activity alias (and therefore its icon) aligned with the selected palette. */
object DieterLauncherIcon {
    private val aliases = linkedMapOf(
        DieterPalette.MONOCHROME to "LauncherMonochrome",
        DieterPalette.ELECTRIC_BLUE to "LauncherElectricBlue",
        DieterPalette.JADE_OPERATOR to "LauncherJadeOperator",
        DieterPalette.COPPER_CIRCUIT to "LauncherCopperCircuit",
        DieterPalette.ULTRAVIOLET_RELAY to "LauncherUltravioletRelay",
        DieterPalette.SOLAR_COMMAND to "LauncherSolarCommand",
        DieterPalette.ARCTIC_CONSOLE to "LauncherArcticConsole",
        DieterPalette.CORAL_SIGNAL to "LauncherCoralSignal",
    )

    fun apply(context: Context, selected: DieterPalette) {
        val appContext = context.applicationContext
        val manager = appContext.packageManager
        val componentStates = aliases.map { (palette, alias) ->
            Pair(
                ComponentName(appContext.packageName, "${appContext.packageName}.$alias"),
                if (palette == selected) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                } else {
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                },
            )
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val settings = componentStates.map { (componentName, enabledState) ->
                PackageManager.ComponentEnabledSetting(
                    componentName,
                    enabledState,
                    PackageManager.DONT_KILL_APP,
                )
            }
            manager.setComponentEnabledSettings(settings)
        } else {
            // Enable first so launchers never observe a moment with no entry point.
            componentStates
                .sortedBy { (_, enabledState) -> enabledState != PackageManager.COMPONENT_ENABLED_STATE_ENABLED }
                .forEach { (componentName, enabledState) ->
                    manager.setComponentEnabledSetting(
                        componentName,
                        enabledState,
                        PackageManager.DONT_KILL_APP,
                    )
                }
        }
    }
}
