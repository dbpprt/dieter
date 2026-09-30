package com.dbpprt.dieter.ui

import com.dbpprt.dieter.core.machines.MachineRow
import java.util.Locale

/** A picker must not move its targets when presence, route latency, or selection changes. */
internal fun stableMachineOrder(machines: List<MachineRow>): List<MachineRow> =
    machines.distinctBy { it.id }.sortedWith(compareBy<MachineRow> { it.label.lowercase(Locale.ROOT) }.thenBy { it.id })
