package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.api.gateway.v1.DeviceKeyAlgorithm
import com.getdieter.api.gateway.v1.DeviceKind
import com.getdieter.api.gateway.v1.DeviceRoster
import com.getdieter.api.gateway.v1.DeviceRosterEntry
import com.getdieter.api.gateway.v1.DeviceRosterOperation
import com.getdieter.api.gateway.v1.PairingRequest
import com.getdieter.core.platform.SoftwareDeviceKeys
import com.getdieter.core.testing.JcaSignatureVerifier
import com.getdieter.core.testing.TestMachineKey
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import java.nio.file.Files
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import okio.ByteString
import okio.ByteString.Companion.toByteString

const val ACCOUNT = "https://gateway.test|github:42"
const val CREATED = "2026-10-12T09:00:00Z"

/** A roster member that signs: a machine's Ed25519 key or an app's P-256 key. */
class Signer(val descriptor: DeviceDescriptor, val sign: (ByteArray) -> ByteArray) {
    val id: String
        get() = descriptor.device_id

    companion object {
        fun machine(
            daemonId: String,
            name: String = "Studio",
            key: TestMachineKey = TestMachineKey(),
        ): Signer {
            val publicKey = key.publicKey
            return Signer(
                DeviceDescriptor(
                    device_id = Rosters.deviceId(publicKey.toByteArray()),
                    kind = DeviceKind.DEVICE_KIND_DAEMON,
                    platform = "macos",
                    name = name,
                    algorithm = DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ED25519,
                    public_key = publicKey,
                    daemon_id = daemonId,
                ),
                key::sign,
            )
        }

        fun app(name: String = "Phone", keys: SoftwareDeviceKeys = softwareKeys()): Signer {
            val publicKey = keys.publicKey()
            return Signer(
                DeviceDescriptor(
                    device_id = Rosters.deviceId(publicKey),
                    kind = DeviceKind.DEVICE_KIND_CLIENT,
                    platform = "android",
                    name = name,
                    algorithm = DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256,
                    public_key = publicKey.toByteString(),
                ),
                keys::sign,
            )
        }

        fun recovery(key: TestMachineKey = TestMachineKey()): Signer {
            val publicKey = key.publicKey
            return Signer(
                DeviceDescriptor(
                    device_id = Rosters.deviceId(publicKey.toByteArray()),
                    kind = DeviceKind.DEVICE_KIND_RECOVERY,
                    platform = "recovery",
                    name = "Recovery key",
                    algorithm = DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ED25519,
                    public_key = publicKey,
                ),
                key::sign,
            )
        }
    }
}

fun softwareKeys(name: String = "Phone"): SoftwareDeviceKeys =
    SoftwareDeviceKeys(
        Files.createTempDirectory("dieter-keys").resolve("device-key").toFile(),
        deviceName = name,
    )

fun genesis(signer: Signer, account: String = ACCOUNT): DeviceRosterEntry =
    Roster.signed(
        DeviceRosterEntry(
            account = account,
            sequence = 0,
            operation = DeviceRosterOperation.DEVICE_ROSTER_OPERATION_GENESIS,
            device = signer.descriptor,
            signer = signer.id,
            created_at = CREATED,
        ),
        signer.sign,
    )

fun Roster.add(device: DeviceDescriptor, by: Signer): Roster =
    extend(listOf(Roster.signed(addition(device, by.id, CREATED), by.sign)), JcaSignatureVerifier)

fun Roster.revoke(deviceId: String, by: Signer): Roster =
    extend(
        listOf(Roster.signed(revocation(deviceId, by.id, CREATED), by.sign)),
        JcaSignatureVerifier,
    )

fun roster(vararg entries: DeviceRosterEntry): Roster =
    Roster.verify(entries.toList(), JcaSignatureVerifier)

/**
 * An in-memory gateway mailbox with the real compare-and-swap and idempotent pairing requests. It
 * verifies nothing, like a gateway the devices must not trust.
 */
class FakeRosterGateway : RosterGateway {
    val entries = MutableStateFlow<List<DeviceRosterEntry>>(emptyList())
    val requests = LinkedHashMap<String, PairingRequest>()
    val deleted = mutableListOf<String>()
    val posted = mutableListOf<PairingRequest>()

    /** Runs before the next append, e.g. another device's concurrent append. */
    var beforeAppend: (() -> Unit)? = null
    private var ids = 0

    fun serve(roster: Roster) {
        entries.value = roster.entries
    }

    override suspend fun roster(fromSequence: Long): DeviceRoster =
        DeviceRoster(
            entries = entries.value.drop(fromSequence.toInt()),
            length = entries.value.size.toLong(),
        )

    override fun watch(fromSequence: Long): Flow<DeviceRoster> = entries.map {
        DeviceRoster(entries = it.drop(fromSequence.toInt()), length = it.size.toLong())
    }

    override suspend fun append(entry: DeviceRosterEntry): DeviceRoster {
        beforeAppend?.let {
            beforeAppend = null
            it()
        }
        val current = entries.value
        if (
            entry.sequence != current.size.toLong() ||
                (current.isNotEmpty() && entry.previous != Rosters.hash(current.last()))
        )
            throw GrpcException(GrpcStatus.ABORTED, "the device roster changed")
        entries.value = current + entry
        return DeviceRoster(entries = entries.value, length = entries.value.size.toLong())
    }

    override suspend fun post(device: DeviceDescriptor, proof: ByteString): PairingRequest {
        val existing = requests.values.firstOrNull { it.device?.device_id == device.device_id }
        val request =
            PairingRequest(
                id = existing?.id ?: "pr_${++ids}",
                device = device,
                proof = proof,
                requested_at = "2026-10-12T09:00:0${ids % 10}Z",
                expires_at = "2100-01-01T00:00:00Z",
                confirmation = existing?.confirmation ?: ByteString.EMPTY,
            )
        requests[request.id] = request
        posted += request
        return request
    }

    override suspend fun list(): List<PairingRequest> = requests.values.toList()

    override suspend fun confirm(id: String, confirmation: ByteString): PairingRequest =
        requests.getValue(id).copy(confirmation = confirmation).also { requests[id] = it }

    override suspend fun delete(id: String) {
        requests.remove(id)
        deleted += id
    }

    /**
     * What a trusted machine does when a person types [code]: add the request that proves it and
     * confirm it.
     */
    fun approve(code: String, by: Signer) {
        val secret = Pairing.parse(code)!!
        val request = requests.values.single { Pairing.verifyProof(secret, it.device!!, it.proof) }
        val current = roster(*entries.value.toTypedArray())
        val next = current.add(request.device!!, by)
        entries.value = next.entries
        requests[request.id] =
            request.copy(
                confirmation =
                    Pairing.confirmation(secret, next.root, Rosters.hash(next.entries.last()))
            )
    }
}
