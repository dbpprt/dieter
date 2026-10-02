package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.LabelPalette
import com.dbpprt.dieter.client.v1.LabelSwatch
import com.dbpprt.dieter.core.admin.Labels

/** Board label colors and checks, as label editors call them while rendering. */
object LabelExports {
    private val palette = LabelPalette(swatches = Labels.COLORS.map { LabelSwatch(name = it.name, hex = it.value) })

    /** The ten named colors every client offers, e.g. "Ruby" "#d95c68". */
    fun palette(): LabelPalette = palette

    /** A palette color other than [exclude] (empty excludes none), for a new label. */
    fun randomColor(exclude: String): String = Labels.randomColor(exclude.ifEmpty { null })

    /** Why a label with [name] and [color] cannot be saved, e.g. "label name is required"; "" when it can. */
    fun problem(name: String, color: String): String = Labels.validate(name, color).orEmpty()
}
