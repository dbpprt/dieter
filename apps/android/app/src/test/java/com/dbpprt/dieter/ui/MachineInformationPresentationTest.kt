package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MachineInformation
import com.dbpprt.dieter.v1.MachineOperationAction
import com.dbpprt.dieter.v1.MachineOperationCapability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MachineInformationPresentationTest {
    @Test fun formatsTelemetryWithoutInventingPrecision() {
        assertTrue(MachineInformationPresentation.bytes(11_200_000_000).endsWith("GB"))
        assertTrue(MachineInformationPresentation.rate(1_250_000.0).endsWith("/s"))
        assertEquals("14d 6h", MachineInformationPresentation.uptime(14 * 86_400L + 6 * 3_600L))
        assertEquals("2h 41m", MachineInformationPresentation.uptime(2 * 3_600L + 41 * 60L))
        assertEquals("38%", MachineInformationPresentation.percentage(37.6))
        assertEquals("0123456789", MachineInformationPresentation.shortRevision("0123456789abcdef"))
        assertEquals(null, MachineInformationPresentation.shortRevision("unknown"))
    }

    @Test fun explicitCapabilitiesOverrideLegacyPowerFlags() {
        val restart = MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART
        val shutdown = MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN
        val update = MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON
        val legacy = MachineInformation.newBuilder().setSupportsRestart(true).setSupportsShutdown(false).build()
        assertTrue(machineOperationAvailable(legacy, restart))
        assertFalse(machineOperationAvailable(legacy, shutdown))
        assertFalse(machineOperationAvailable(legacy, update))

        val explicit = legacy.toBuilder()
            .addOperationCapabilities(
                MachineOperationCapability.newBuilder()
                    .setAction(restart)
                    .setSupported(true)
                    .setAuthorized(false),
            )
            .addOperationCapabilities(
                MachineOperationCapability.newBuilder()
                    .setAction(update)
                    .setSupported(true)
                    .setAuthorized(true),
            )
            .build()
        assertFalse(machineOperationAvailable(explicit, restart))
        assertTrue(machineOperationAvailable(explicit, update))
        assertFalse(machineOperationAvailable(null, restart))
    }
}
