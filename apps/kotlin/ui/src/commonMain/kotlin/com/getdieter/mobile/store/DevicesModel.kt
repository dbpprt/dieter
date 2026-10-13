package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * This device's place among the account's trusted devices. The core reads waiting devices only
 * while the slice is observed, so the views that show it hold it with [show].
 */
class DevicesModel internal constructor(private val context: StoreContext) {
    val slice = MutableStateFlow(DevicesSlice())

    /** Why the last approval failed, e.g. "No device is waiting with this code."; empty if none. */
    val approvalError = MutableStateFlow("")
    private var viewers = 0
    private var subscription: ClientSubscription? = null

    /** Observes the devices while a view shows them; call the returned function when it leaves. */
    fun show(): () -> Unit {
        if (context.closed) return {}
        if (viewers++ == 0)
            subscription =
                context.observe(Slice.SLICE_DEVICES, "") { update ->
                    update.devices?.let { slice.value = it }
                }
        var released = false
        return {
            if (!released) {
                released = true
                if (--viewers == 0) {
                    subscription?.close()
                    subscription = null
                }
            }
        }
    }

    fun refresh() = command(DevicesCommand(refresh = Step()))

    /** Signs the device that shows [code] into the account; [added] runs when it was. */
    fun approve(code: String, added: () -> Unit) = context.action {
        approvalError.value = ""
        try {
            context.core.dispatch(Command(devices = DevicesCommand(approve = DeviceApproval(code))))
            added()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            approvalError.value = failure.message ?: "The device could not be added."
        }
    }

    fun remove(deviceId: String) = command(DevicesCommand(revoke = DeviceRef(deviceId)))

    /** Forgets this device's trust and key; it shows a new code to pair again. */
    fun reset() = command(DevicesCommand(reset = Step()))

    private fun command(value: DevicesCommand) = context.command(Command(devices = value))

    internal fun release() {
        subscription?.close()
        subscription = null
    }
}

/** Machines are unreachable in these states, so the app shows pairing instead of its content. */
val SessionSlice.pairing: Boolean
    get() =
        device_trust == DeviceTrust.DEVICE_TRUST_NO_ROSTER ||
            device_trust == DeviceTrust.DEVICE_TRUST_PENDING ||
            device_trust == DeviceTrust.DEVICE_TRUST_REVOKED ||
            device_trust == DeviceTrust.DEVICE_TRUST_CONFLICT
