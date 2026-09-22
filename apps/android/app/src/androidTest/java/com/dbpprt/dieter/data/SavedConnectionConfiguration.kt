package com.dbpprt.dieter.data

import com.dbpprt.dieter.connection.DieterConnectionManager

/** Restore the emulator's actual connection choices, including custom gateways,
 * after a fixture borrows the process-wide manager. Credentials stay untouched. */
internal class SavedConnectionConfiguration(private val manager: DieterConnectionManager) {
    private val state = manager.state.value
    private val endpoints = state.configuredConnections.map {
        dieterEndpointFromAddress(it.id, it.label, it.address)
    }

    fun restore() {
        manager.disconnect()
        manager.updateEndpoints(endpoints, selectedGatewayId = state.activeGatewayId)
        manager.setBackgroundSyncMode(state.backgroundSyncMode)
        if (state.desiredConnected) manager.connect()
    }
}
