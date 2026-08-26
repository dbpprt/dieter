package com.dbpprt.dieter.widget

import android.content.Context
import android.content.res.Configuration
import androidx.annotation.DrawableRes
import com.dbpprt.dieter.R
import com.dbpprt.dieter.settings.DieterPalette

internal fun DieterPalette.widgetUsesDarkColors(context: Context): Boolean =
    this != DieterPalette.MONOCHROME ||
        context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

@DrawableRes
internal fun DieterPalette.widgetBackground(): Int = when (this) {
    DieterPalette.MONOCHROME -> R.drawable.bg_widget_monochrome
    DieterPalette.ELECTRIC_BLUE -> R.drawable.bg_widget_electric_blue
    DieterPalette.JADE_OPERATOR -> R.drawable.bg_widget_jade_operator
    DieterPalette.COPPER_CIRCUIT -> R.drawable.bg_widget_copper_circuit
    DieterPalette.ULTRAVIOLET_RELAY -> R.drawable.bg_widget_ultraviolet_relay
    DieterPalette.SOLAR_COMMAND -> R.drawable.bg_widget_solar_command
    DieterPalette.ARCTIC_CONSOLE -> R.drawable.bg_widget_arctic_console
    DieterPalette.CORAL_SIGNAL -> R.drawable.bg_widget_coral_signal
}

@DrawableRes
internal fun DieterPalette.widgetAppChip(): Int = when (this) {
    DieterPalette.MONOCHROME -> R.drawable.bg_widget_app_chip_monochrome
    DieterPalette.ELECTRIC_BLUE -> R.drawable.bg_widget_app_chip_electric_blue
    DieterPalette.JADE_OPERATOR -> R.drawable.bg_widget_app_chip_jade_operator
    DieterPalette.COPPER_CIRCUIT -> R.drawable.bg_widget_app_chip_copper_circuit
    DieterPalette.ULTRAVIOLET_RELAY -> R.drawable.bg_widget_app_chip_ultraviolet_relay
    DieterPalette.SOLAR_COMMAND -> R.drawable.bg_widget_app_chip_solar_command
    DieterPalette.ARCTIC_CONSOLE -> R.drawable.bg_widget_app_chip_arctic_console
    DieterPalette.CORAL_SIGNAL -> R.drawable.bg_widget_app_chip_coral_signal
}

@DrawableRes
internal fun DieterPalette.widgetIconBackground(): Int = when (this) {
    DieterPalette.MONOCHROME -> R.drawable.bg_widget_icon_monochrome
    DieterPalette.ELECTRIC_BLUE -> R.drawable.bg_widget_icon_electric_blue
    DieterPalette.JADE_OPERATOR -> R.drawable.bg_widget_icon_jade_operator
    DieterPalette.COPPER_CIRCUIT -> R.drawable.bg_widget_icon_copper_circuit
    DieterPalette.ULTRAVIOLET_RELAY -> R.drawable.bg_widget_icon_ultraviolet_relay
    DieterPalette.SOLAR_COMMAND -> R.drawable.bg_widget_icon_solar_command
    DieterPalette.ARCTIC_CONSOLE -> R.drawable.bg_widget_icon_arctic_console
    DieterPalette.CORAL_SIGNAL -> R.drawable.bg_widget_icon_coral_signal
}
