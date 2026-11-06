package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientFailure
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class DevicesModelTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    @Test
    fun theDevicesAreObservedOnlyWhileAViewShowsThem() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            assertFalse(core.observing(Slice.SLICE_DEVICES))
            val list = store.devices.show()
            val gate = store.devices.show()
            assertTrue(core.observing(Slice.SLICE_DEVICES))
            core.publish(
                Slice.SLICE_DEVICES,
                update =
                    Update(
                        devices =
                            DevicesSlice(
                                trust = DeviceTrust.DEVICE_TRUST_TRUSTED,
                                title = "This device is trusted",
                            )
                    ),
            )
            runCurrent()
            assertEquals("This device is trusted", store.devices.slice.value.title)
            list()
            list()
            assertTrue(core.observing(Slice.SLICE_DEVICES), "another view still shows them")
            gate()
            assertFalse(core.observing(Slice.SLICE_DEVICES))
        } finally {
            store.close()
        }
    }

    @Test
    fun approvingSendsTheTypedCodeAndKeepsTheCoresReasonWhenItFails() = runTest {
        var accept = false
        val core = FakeMobileCore { command ->
            if (command.devices?.approve != null && !accept)
                throw ClientFailure(Failure(message = "No device is waiting with this code."))
            Result(outcome = Outcome(succeeded = true))
        }
        val store = store(core)
        try {
            var added = 0
            store.devices.approve("ABCD-EFGH-JKMN-PQRS") { added++ }
            runCurrent()
            assertEquals(
                DeviceApproval("ABCD-EFGH-JKMN-PQRS"),
                core.sentOf { it.devices?.approve }.single(),
            )
            assertEquals("No device is waiting with this code.", store.devices.approvalError.value)
            assertEquals(0, added)
            assertEquals("", store.error.value, "the field shows the failure, not a snackbar")

            accept = true
            store.devices.approve("ABCD-EFGH-JKMN-PQRS") { added++ }
            runCurrent()
            assertEquals("", store.devices.approvalError.value)
            assertEquals(1, added)
        } finally {
            store.close()
        }
    }

    @Test
    fun removeResetAndRefreshAreDeviceCommands() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.devices.remove("dv_pixel")
            store.devices.reset()
            store.devices.refresh()
            runCurrent()
            assertEquals(
                listOf(
                    DevicesCommand(revoke = DeviceRef("dv_pixel")),
                    DevicesCommand(reset = Step()),
                    DevicesCommand(refresh = Step()),
                ),
                core.sentOf { it.devices },
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun onlyATrustedOrStillUnknownDeviceShowsMachineContent() {
        val pairing = DeviceTrust.entries.filter { SessionSlice(device_trust = it).pairing }.toSet()
        assertEquals(
            setOf(
                DeviceTrust.DEVICE_TRUST_NO_ROSTER,
                DeviceTrust.DEVICE_TRUST_PENDING,
                DeviceTrust.DEVICE_TRUST_REVOKED,
                DeviceTrust.DEVICE_TRUST_CONFLICT,
            ),
            pairing,
        )
    }
}
