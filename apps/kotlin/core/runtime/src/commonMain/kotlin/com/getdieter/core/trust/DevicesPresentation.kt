package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceKind
import com.getdieter.api.gateway.v1.DeviceRosterOperation

/** One device of the account, as the Devices view lists it. */
data class DeviceRow(
    val deviceId: String,
    val name: String,
    /** "Machine", "App" or "Recovery key". */
    val kindLabel: String,
    val platform: String,
    val thisDevice: Boolean,
    val revoked: Boolean,
    /** The name of the device that added it; empty for the first device. */
    val addedBy: String,
    val daemonId: String,
    /** Only active devices other than recovery keys, and never the last that can connect. */
    val revocable: Boolean,
)

/** A device waiting to join; its code is never listed. */
data class WaitingDeviceRow(
    val requestId: String,
    val name: String,
    val kindLabel: String,
    val platform: String,
    val deviceId: String,
)

/** A recent roster change, e.g. "Pixel 9 was added by MacBook". */
data class DeviceNoticeRow(val sequence: Long, val text: String)

/** The Devices view: this device's trust, the account's devices, and what to do next. */
data class DevicesPresentation(
    val state: TrustState,
    val pairingCode: String,
    val thisDeviceId: String,
    val devices: List<DeviceRow>,
    val requests: List<WaitingDeviceRow>,
    val notices: List<DeviceNoticeRow>,
    val title: String,
    val detail: String,
    val error: String,
    val loading: Boolean,
)

/** The Devices view's wording, ordering and enablement. */
object DevicesPresenter {
    /** Roster changes the view lists, newest first. */
    const val NOTICE_LIMIT = 10

    fun present(view: TrustView): DevicesPresentation {
        val roster = view.roster
        val shown = view.state in setOf(TrustState.TRUSTED, TrustState.REVOKED, TrustState.CONFLICT)
        val connecting = roster?.connectingCount ?: 0
        val devices =
            if (roster == null || !shown) emptyList()
            else
                roster.members
                    .map { member ->
                        val descriptor = member.descriptor
                        DeviceRow(
                            deviceId = member.deviceId,
                            name = descriptor.name,
                            kindLabel = kindLabel(member.kind),
                            platform = descriptor.platform,
                            thisDevice = member.deviceId == view.deviceId,
                            revoked = member.revoked,
                            addedBy =
                                member.addedBy
                                    .takeIf { it.isNotEmpty() }
                                    ?.let { roster.member(it)?.descriptor?.name ?: it }
                                    .orEmpty(),
                            daemonId = descriptor.daemon_id,
                            revocable =
                                view.state == TrustState.TRUSTED &&
                                    member.active &&
                                    member.kind != DeviceKind.DEVICE_KIND_RECOVERY &&
                                    !(member.connects && connecting <= 1),
                        )
                    }
                    .sortedWith(
                        compareBy<DeviceRow> { it.revoked }
                            .thenBy { !it.thisDevice }
                            .thenBy { it.name.lowercase() }
                            .thenBy { it.deviceId }
                    )
        val requests =
            if (view.state != TrustState.TRUSTED) emptyList()
            else
                view.requests.mapNotNull { request ->
                    val device = request.device ?: return@mapNotNull null
                    WaitingDeviceRow(
                        requestId = request.id,
                        name = device.name,
                        kindLabel = kindLabel(device.kind),
                        platform = device.platform,
                        deviceId = device.device_id,
                    )
                }
        return DevicesPresentation(
            state = view.state,
            pairingCode = view.pairingCode.takeIf { view.state == TrustState.PENDING }.orEmpty(),
            thisDeviceId = view.deviceId,
            devices = devices,
            requests = requests,
            notices = if (shown) notices(roster) else emptyList(),
            title = title(view.state),
            detail = detail(view),
            error = view.problem.orEmpty(),
            loading = view.loading,
        )
    }

    fun kindLabel(kind: DeviceKind): String =
        when (kind) {
            DeviceKind.DEVICE_KIND_DAEMON -> "Machine"
            DeviceKind.DEVICE_KIND_RECOVERY -> "Recovery key"
            else -> "App"
        }

    /** Recent additions and removals, newest first: "Pixel 9 was added by MacBook". */
    fun notices(roster: Roster?): List<DeviceNoticeRow> {
        if (roster == null) return emptyList()
        fun name(deviceId: String) = roster.member(deviceId)?.descriptor?.name ?: deviceId
        return roster.entries
            .asReversed()
            .asSequence()
            .mapNotNull { entry ->
                val subject = entry.device?.device_id ?: return@mapNotNull null
                val text =
                    when (entry.operation) {
                        DeviceRosterOperation.DEVICE_ROSTER_OPERATION_ADD ->
                            "${name(subject)} was added by ${name(entry.signer)}"
                        DeviceRosterOperation.DEVICE_ROSTER_OPERATION_REVOKE ->
                            "${name(subject)} was removed by ${name(entry.signer)}"
                        else -> return@mapNotNull null
                    }
                DeviceNoticeRow(entry.sequence, text)
            }
            .take(NOTICE_LIMIT)
            .toList()
    }

    fun title(state: TrustState): String =
        when (state) {
            TrustState.UNKNOWN -> "Checking this device"
            TrustState.NO_ROSTER -> "Set up Dieter on a machine first"
            TrustState.PENDING -> "Waiting for approval"
            TrustState.TRUSTED -> "This device is trusted"
            TrustState.REVOKED -> "This device was removed"
            TrustState.CONFLICT -> "Your trusted devices conflict"
        }

    fun detail(view: TrustView): String =
        when (view.state) {
            TrustState.UNKNOWN ->
                "Dieter reads your account's trusted devices once it is connected to your gateway."
            TrustState.NO_ROSTER ->
                "Your account has no trusted devices yet. Run `dieter device init` on a machine " +
                    "you own, then pair this device with the code it shows."
            TrustState.PENDING ->
                "On a device you already trust, open Devices and type this code. Keep it " +
                    "private: anyone who types it on one of your trusted devices adds this device."
            TrustState.TRUSTED ->
                "This device reaches your machines over end-to-end encrypted connections. To add " +
                    "a device, type the code it shows."
            TrustState.REVOKED ->
                "Another device removed this one from your account, so it can no longer reach " +
                    "your machines. Reset trust to pair it again."
            TrustState.CONFLICT ->
                (view.conflict?.let { "$it " }.orEmpty()) +
                    "Connections stay closed. If nobody reset your account's devices, your " +
                    "gateway may be compromised. Reset trust to pair this device again."
        }
}
