package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.flow.MutableStateFlow

/** Machine telemetry. */
class MachinesModel internal constructor(private val context: StoreContext) {
    val telemetry = MutableStateFlow(TelemetrySlice())
    private var selected = ""

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_TELEMETRY, "") {
            it.telemetry?.let { value -> telemetry.value = value }
        }
    }

    /** Streams telemetry of the shown machine; empty stops the stream. */
    internal fun select(machineId: String) {
        if (machineId == selected) return
        selected = machineId
        context.command(
            Command(
                telemetry =
                    TelemetryCommand(select = TelemetrySelect(machineId, machineId.isNotEmpty()))
            )
        )
    }
}
