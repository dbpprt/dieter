package com.getdieter.core

import com.getdieter.client.v1.Command
import com.getdieter.client.v1.DeviceApproval
import com.getdieter.client.v1.DeviceRef
import com.getdieter.client.v1.DeviceTrust
import com.getdieter.client.v1.DevicesCommand
import com.getdieter.client.v1.DevicesSlice
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Step
import com.getdieter.client.v1.Update
import com.getdieter.core.client.ClientApi
import com.getdieter.core.client.ClientFailure
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.await
import com.getdieter.core.trust.TrustState
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Device trust over the real gateway and daemon: the fixture's machine pairs a client with the
 * fixture's code, that client approves a second one by the code it shows, machines answer only
 * trusted devices, and a revoked device loses them.
 */
class ClientApiDevicesEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private fun ClientApi.devices(): MutableStateFlow<DevicesSlice?> {
        val slice = MutableStateFlow<DevicesSlice?>(null)
        observe(Slice.SLICE_DEVICES, "") { update ->
            Update.ADAPTER.decode(update.encode()).devices?.let { slice.value = it }
        }
        return slice
    }

    @Test
    fun aTrustedClientApprovesAndRevokesAnotherByItsCode() = e2e {
        val fixture = fixture()
        val trusted = runtime(fixture)
        trusted.awaitConnected()
        trusted.onMachine(fixture.daemonId) { it.Health().execute(Unit) }
        val api = ClientApi(trusted)
        val devices = api.devices()
        val shown =
            devices.await(describe = { "trusted devices: ${devices.value}" }) { slice ->
                slice?.trust == DeviceTrust.DEVICE_TRUST_TRUSTED &&
                    slice.devices.any { it.daemon_id == fixture.daemonId }
            }!!
        val self = shown.devices.first()
        assertTrue(self.this_device)
        assertEquals("App", self.kind_label)
        assertEquals(trusted.trust.deviceId, shown.this_device_id)
        assertEquals("Machine", shown.devices.first { it.daemon_id == fixture.daemonId }.kind_label)
        assertTrue(shown.notices.any { it.text.startsWith("${self.name} was added by ") })

        // A second client without the fixture's code waits with a code of its own.
        val pending = runtime(fixture, pairingCode = null)
        pending.awaitConnected(trusted = false)
        val waiting =
            pending.trust.view.await(describe = { "pending: ${pending.trust.view.value}" }) {
                it.state == TrustState.PENDING && it.pairingCode != null
            }
        val refused =
            assertFailsWith<Exception> {
                pending.onMachine(fixture.daemonId) { it.Health().execute(Unit) }
            }
        assertEquals("This device is not trusted yet.", refused.message)
        val wrong =
            assertFailsWith<ClientFailure> {
                api.dispatch(
                    Command(
                        devices =
                            DevicesCommand(approve = DeviceApproval(code = "0000-0000-0000-0000"))
                    )
                )
            }
        assertEquals("No device is waiting with this code.", wrong.failure.message)
        api.dispatch(Command(devices = DevicesCommand(refresh = Step())))
        devices.await(describe = { "waiting devices: ${devices.value?.requests}" }) { slice ->
            slice?.requests?.any { it.device_id == pending.trust.deviceId } == true
        }
        val approved =
            api.dispatch(
                Command(
                    devices =
                        DevicesCommand(
                            approve = DeviceApproval(code = waiting.pairingCode!!.lowercase())
                        )
                )
            )
        assertEquals(true, approved.outcome?.succeeded)
        pending.awaitTrusted()
        pending.onMachine(fixture.daemonId) { it.Health().execute(Unit) }

        // Removing it ends its trust; its machines refuse it.
        api.dispatch(
            Command(
                devices = DevicesCommand(revoke = DeviceRef(device_id = pending.trust.deviceId))
            )
        )
        devices.await(describe = { "revoked: ${devices.value?.devices}" }) { slice ->
            slice?.devices?.any { it.device_id == pending.trust.deviceId && it.revoked } == true
        }
        pending.trust.view.await(
            30.seconds,
            describe = { "revoked: ${pending.trust.view.value}" },
        ) {
            it.state == TrustState.REVOKED
        }
    }
}
