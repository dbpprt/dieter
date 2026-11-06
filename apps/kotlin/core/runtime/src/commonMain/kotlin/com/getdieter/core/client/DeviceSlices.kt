package com.getdieter.core.client

import com.getdieter.client.v1.DeviceEntry
import com.getdieter.client.v1.DeviceNotice
import com.getdieter.client.v1.DeviceTrust as ClientDeviceTrust
import com.getdieter.client.v1.DevicesSlice
import com.getdieter.client.v1.PairingEntry
import com.getdieter.core.trust.DevicesPresentation
import com.getdieter.core.trust.TrustState

// The Devices slice: this device's trust and the account's device roster.

internal fun deviceTrust(state: TrustState): ClientDeviceTrust =
    when (state) {
        TrustState.UNKNOWN -> ClientDeviceTrust.DEVICE_TRUST_UNKNOWN
        TrustState.NO_ROSTER -> ClientDeviceTrust.DEVICE_TRUST_NO_ROSTER
        TrustState.PENDING -> ClientDeviceTrust.DEVICE_TRUST_PENDING
        TrustState.TRUSTED -> ClientDeviceTrust.DEVICE_TRUST_TRUSTED
        TrustState.REVOKED -> ClientDeviceTrust.DEVICE_TRUST_REVOKED
        TrustState.CONFLICT -> ClientDeviceTrust.DEVICE_TRUST_CONFLICT
    }

internal fun devicesSlice(devices: DevicesPresentation): DevicesSlice =
    DevicesSlice(
        trust = deviceTrust(devices.state),
        pairing_code = devices.pairingCode,
        this_device_id = devices.thisDeviceId,
        devices =
            devices.devices.map {
                DeviceEntry(
                    device_id = it.deviceId,
                    name = it.name,
                    kind_label = it.kindLabel,
                    platform = it.platform,
                    this_device = it.thisDevice,
                    revoked = it.revoked,
                    added_by = it.addedBy,
                    daemon_id = it.daemonId,
                    revocable = it.revocable,
                )
            },
        requests =
            devices.requests.map {
                PairingEntry(
                    request_id = it.requestId,
                    name = it.name,
                    kind_label = it.kindLabel,
                    platform = it.platform,
                    device_id = it.deviceId,
                )
            },
        notices = devices.notices.map { DeviceNotice(sequence = it.sequence, text = it.text) },
        title = devices.title,
        detail = devices.detail,
        error = devices.error,
        loading = devices.loading,
    )
