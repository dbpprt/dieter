package com.dbpprt.dieter.core.presentation

import kotlin.math.roundToLong

/** Byte counts in binary units, e.g. "512 B", "1.5 KB", "240 MB", independent of the device locale. */
object ByteSizes {
    private val units = listOf("B", "KB", "MB", "GB", "TB")

    fun format(bytes: Long): String {
        var amount = bytes.coerceAtLeast(0).toDouble()
        var unit = 0
        while (amount >= 1024 && unit < units.lastIndex) {
            amount /= 1024
            unit++
        }
        val number = if (unit == 0 || amount >= 100) amount.roundToLong().toString() else TokenCounts.format1(amount)
        return "$number ${units[unit]}"
    }
}
