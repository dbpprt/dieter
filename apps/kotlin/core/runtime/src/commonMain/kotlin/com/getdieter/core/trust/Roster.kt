package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.api.gateway.v1.DeviceKeyAlgorithm
import com.getdieter.api.gateway.v1.DeviceKind
import com.getdieter.api.gateway.v1.DeviceRoster
import com.getdieter.api.gateway.v1.DeviceRosterEntry
import com.getdieter.api.gateway.v1.DeviceRosterOperation
import com.getdieter.core.platform.SignatureVerifier
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.toByteString

/**
 * Why a roster was refused. [conflict] marks a different entry at a sequence number the device has
 * already pinned (equivocation); anything else is a malformed or unauthorized entry.
 */
class RosterException(val conflict: Boolean, message: String) : Exception(message)

/**
 * The account device roster's encodings: canonical entry bytes, hashes, device IDs and descriptor
 * bytes. They match `internal/security/roster` byte for byte (golden vectors in
 * `tests/fixtures/roster`).
 */
object Rosters {
    const val MAX_ENTRIES = 4096
    const val MAX_ACTIVE = 64
    const val MAX_ENTRY_BYTES = 1024
    const val MAX_NAME_BYTES = 64
    internal const val MAX_SHORT_FIELD = 128

    private const val SIGNING_DOMAIN = "dieter-roster-v1"
    private const val DESCRIPTOR_DOMAIN = "dieter-device-v1"
    private const val DEVICE_PREFIX = "dv_"

    /** "dv_" + lowercase Crockford base32 of the first 16 bytes of SHA-256 of the DER key. */
    fun deviceId(publicKey: ByteArray): String =
        DEVICE_PREFIX +
            Codes.encode(publicKey.toByteString().sha256().toByteArray().copyOf(16)).lowercase()

    /** The bytes an entry's signature covers and its hash commits to; the signature is excluded. */
    fun canonical(entry: DeviceRosterEntry): ByteArray {
        val device = entry.device ?: DeviceDescriptor()
        val out = Buffer().writeUtf8(SIGNING_DOMAIN)
        writeFields(
            out,
            entry.account.encodeToByteArray(),
            entry.sequence.toULong().toString().encodeToByteArray(),
            entry.previous.toByteArray(),
            entry.operation.value.toString().encodeToByteArray(),
            device.device_id.encodeToByteArray(),
            device.kind.value.toString().encodeToByteArray(),
            device.platform.encodeToByteArray(),
            device.name.encodeToByteArray(),
            device.algorithm.value.toString().encodeToByteArray(),
            device.public_key.toByteArray(),
            device.daemon_id.encodeToByteArray(),
            entry.signer.encodeToByteArray(),
            entry.created_at.encodeToByteArray(),
        )
        return out.readByteArray()
    }

    /** SHA-256 of [canonical]: what the next entry's previous field and a pinned head commit to. */
    fun hash(entry: DeviceRosterEntry): ByteString = canonical(entry).toByteString().sha256()

    /** The printable form of a roster hash: unpadded base64url. */
    fun encodeHash(hash: ByteString): String = hash.base64Url().trimEnd('=')

    /** The canonical encoding of a device descriptor, which a pairing proof covers. */
    fun descriptorBytes(device: DeviceDescriptor): ByteArray {
        val out = Buffer().writeUtf8(DESCRIPTOR_DOMAIN)
        writeFields(
            out,
            device.device_id.encodeToByteArray(),
            device.kind.value.toString().encodeToByteArray(),
            device.platform.encodeToByteArray(),
            device.name.encodeToByteArray(),
            device.algorithm.value.toString().encodeToByteArray(),
            device.public_key.toByteArray(),
            device.daemon_id.encodeToByteArray(),
        )
        return out.readByteArray()
    }

    /** Each field as a 4-byte big-endian length followed by its bytes. */
    internal fun writeFields(out: Buffer, vararg fields: ByteArray) {
        for (field in fields) {
            out.writeInt(field.size)
            out.write(field)
        }
    }

    /** Why [device] cannot ask to join, or null when it can. */
    fun descriptorProblem(device: DeviceDescriptor): String? =
        if (device.kind == DeviceKind.DEVICE_KIND_RECOVERY) "a recovery key cannot ask to join"
        else memberProblem(device)

    /** Why [device] cannot be a roster member, or null. */
    internal fun memberProblem(device: DeviceDescriptor): String? {
        val name = device.name
        val platform = device.platform
        val nameBytes = name.encodeToByteArray().size
        if (nameBytes == 0 || nameBytes > MAX_NAME_BYTES || name.any { it.isISOControl() })
            return "device name is invalid"
        if (
            platform.isEmpty() ||
                platform.length > 16 ||
                platform.any { it !in 'a'..'z' && it !in '0'..'9' }
        )
            return "device platform is invalid"
        if (device.daemon_id.encodeToByteArray().size > MAX_SHORT_FIELD)
            return "daemon ID is too long"
        val key = device.public_key.toByteArray()
        if (deviceId(key) != device.device_id) return "device ID does not match its key"
        keyProblem(device.algorithm, key)?.let {
            return it
        }
        return when (device.kind) {
            DeviceKind.DEVICE_KIND_DAEMON ->
                if (
                    device.daemon_id.isEmpty() ||
                        device.algorithm != DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ED25519
                )
                    "a machine needs its daemon ID and an Ed25519 key"
                else null
            DeviceKind.DEVICE_KIND_CLIENT ->
                if (device.daemon_id.isNotEmpty()) "an app has no daemon ID" else null
            DeviceKind.DEVICE_KIND_RECOVERY ->
                if (
                    device.daemon_id.isNotEmpty() ||
                        device.algorithm != DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ED25519
                )
                    "a recovery key is an Ed25519 key without a daemon ID"
                else null
            else -> "device kind is unknown"
        }
    }

    /** Why [key] is not a valid DER key of [algorithm], or null. */
    private fun keyProblem(algorithm: DeviceKeyAlgorithm, key: ByteArray): String? {
        if (key.isEmpty() || key.size > MAX_SHORT_FIELD) return "device key is invalid"
        val matches =
            when (algorithm) {
                DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ED25519 ->
                    DeviceKeyFormats.ed25519Raw(key) != null
                DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256 ->
                    DeviceKeyFormats.isP256(key)
                else -> false
            }
        return if (matches) null else "device key does not match its algorithm"
    }

    /**
     * Checks a device signature over [message]: Ed25519 directly, ECDSA P-256 as a DER signature
     * over SHA-256([message]).
     */
    fun verifies(
        verifier: SignatureVerifier,
        device: DeviceDescriptor,
        message: ByteArray,
        signature: ByteArray,
    ): Boolean {
        val key = device.public_key.toByteArray()
        return when (device.algorithm) {
            DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ED25519 -> {
                val raw = DeviceKeyFormats.ed25519Raw(key) ?: return false
                signature.size == 64 && verifier.verifyEd25519(raw, message, signature)
            }
            DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256 ->
                DeviceKeyFormats.isP256(key) &&
                    signature.isNotEmpty() &&
                    verifier.verifyEcdsaP256(key, message, signature)
            else -> false
        }
    }
}

/** A device's verified roster record. [addedAt] is the sequence of the entry that added it. */
data class RosterMember(
    val descriptor: DeviceDescriptor,
    val addedBy: String,
    val addedAt: Long,
    val revoked: Boolean = false,
    val revokedAt: Long = 0,
) {
    val deviceId: String
        get() = descriptor.device_id

    val kind: DeviceKind
        get() = descriptor.kind

    /** May sign and, unless a recovery key, connect. */
    val active: Boolean
        get() = !revoked

    /** May authenticate a connection: an active machine or app, never a recovery key. */
    val connects: Boolean
        get() = active && descriptor.kind != DeviceKind.DEVICE_KIND_RECOVERY
}

/**
 * A verified roster: every entry after the self-signed genesis is signed by a device that was an
 * active member at the previous entry. Immutable; [extend] returns a new roster.
 */
class Roster
private constructor(
    val account: String,
    val entries: List<DeviceRosterEntry>,
    private val hashes: List<ByteString>,
    private val byId: Map<String, RosterMember>,
    private val order: List<String>,
) {
    val length: Int
        get() = entries.size

    /** The genesis entry's hash: what a paired device pins. */
    val root: ByteString
        get() = hashes.first()

    val headSequence: Long
        get() = (entries.size - 1).toLong()

    val headHash: ByteString
        get() = hashes.last()

    /** The hash of entry [sequence], or null past the head. */
    fun hashAt(sequence: Long): ByteString? = hashes.getOrNull(sequence.toIntOrMax())

    /** The entries from [sequence] on. */
    fun entriesFrom(sequence: Long): List<DeviceRosterEntry> =
        if (sequence >= entries.size) emptyList()
        else entries.subList(sequence.toInt(), entries.size)

    /** A device ever added, revoked or not. */
    fun member(deviceId: String): RosterMember? = byId[deviceId]

    /** Every device in the order it was added. */
    val members: List<RosterMember>
        get() = order.map { byId.getValue(it) }

    /** The active machine device of gateway daemon [daemonId]. */
    fun daemon(daemonId: String): RosterMember? =
        if (daemonId.isEmpty()) null
        else
            order
                .asSequence()
                .map { byId.getValue(it) }
                .firstOrNull {
                    it.active &&
                        it.kind == DeviceKind.DEVICE_KIND_DAEMON &&
                        it.descriptor.daemon_id == daemonId
                }

    /** The entry that added [deviceId] (the genesis for the first device). */
    fun addition(deviceId: String): DeviceRosterEntry? =
        byId[deviceId]?.let { entries[it.addedAt.toInt()] }

    /** Active members that may connect. */
    val connectingCount: Int
        get() = byId.values.count { it.connects }

    /**
     * Verifies [more] as a continuation of this roster. Entries it already holds are accepted when
     * identical and refused as a conflict otherwise, so a whole roster can be offered.
     */
    fun extend(more: List<DeviceRosterEntry>, verifier: SignatureVerifier): Roster {
        val builder = Builder(this)
        for (entry in more) {
            val sequence = entry.sequence
            if (sequence >= 0 && sequence < builder.entries.size) {
                if (Rosters.hash(entry) != builder.hashes[sequence.toInt()]) {
                    // Only a member-signed continuation of the earlier history is a fork;
                    // malformed or unsigned data from a relay is merely invalid.
                    builder.prefix(sequence.toInt(), verifier).append(entry, verifier)
                    throw RosterException(
                        true,
                        "device roster conflicts with the pinned roster at sequence $sequence",
                    )
                }
                continue
            }
            builder.append(entry, verifier)
        }
        return builder.build()
    }

    /** An unsigned entry that adds [device] after the head, signed by [signer]. */
    fun addition(device: DeviceDescriptor, signer: String, createdAt: String): DeviceRosterEntry =
        DeviceRosterEntry(
            account = account,
            sequence = length.toLong(),
            previous = headHash,
            operation = DeviceRosterOperation.DEVICE_ROSTER_OPERATION_ADD,
            device = device,
            signer = signer,
            created_at = createdAt,
        )

    /** An unsigned entry that revokes [deviceId] after the head, signed by [signer]. */
    fun revocation(deviceId: String, signer: String, createdAt: String): DeviceRosterEntry =
        DeviceRosterEntry(
            account = account,
            sequence = length.toLong(),
            previous = headHash,
            operation = DeviceRosterOperation.DEVICE_ROSTER_OPERATION_REVOKE,
            device = DeviceDescriptor(device_id = deviceId),
            signer = signer,
            created_at = createdAt,
        )

    /** The roster as the gateway serves it. */
    fun proto(): DeviceRoster =
        DeviceRoster(
            entries = entries,
            head_sequence = headSequence,
            head_hash = headHash,
            length = length.toLong(),
        )

    fun encode(): ByteArray = DeviceRoster.ADAPTER.encode(proto())

    companion object {
        /** Verifies a complete roster from its genesis entry. */
        fun verify(entries: List<DeviceRosterEntry>, verifier: SignatureVerifier): Roster {
            if (entries.isEmpty())
                throw RosterException(false, "a roster starts with its genesis entry")
            val builder = Builder(null)
            for (entry in entries) {
                if (entry.sequence >= 0 && entry.sequence < builder.entries.size) {
                    if (Rosters.hash(entry) != builder.hashes[entry.sequence.toInt()]) {
                        builder.prefix(entry.sequence.toInt(), verifier).append(entry, verifier)
                        throw RosterException(
                            true,
                            "device roster conflicts at sequence ${entry.sequence}",
                        )
                    }
                    continue
                }
                builder.append(entry, verifier)
            }
            return builder.build()
        }

        /** A roster stored with [encode], verified again. */
        fun decode(bytes: ByteArray, verifier: SignatureVerifier): Roster =
            verify(DeviceRoster.ADAPTER.decode(bytes).entries, verifier)

        /** [entry] with its signature by [sign] over the canonical bytes. */
        fun signed(entry: DeviceRosterEntry, sign: (ByteArray) -> ByteArray): DeviceRosterEntry =
            entry.copy(signature = sign(Rosters.canonical(entry)).toByteString())
    }

    private class Builder(base: Roster?) {
        var account: String = base?.account.orEmpty()
        val entries = base?.entries?.toMutableList() ?: mutableListOf()
        val hashes = base?.hashes?.toMutableList() ?: mutableListOf()
        val byId = base?.byId?.toMutableMap() ?: mutableMapOf()
        val order = base?.order?.toMutableList() ?: mutableListOf()

        /** The verified history before entry [sequence]; its entries verified once already. */
        fun prefix(sequence: Int, verifier: SignatureVerifier): Builder {
            val prefix = Builder(null)
            for (entry in entries.subList(0, sequence)) prefix.append(entry, verifier)
            return prefix
        }

        fun build(): Roster {
            if (entries.isEmpty())
                throw RosterException(false, "a roster starts with its genesis entry")
            return Roster(account, entries.toList(), hashes.toList(), byId.toMap(), order.toList())
        }

        fun append(entry: DeviceRosterEntry, verifier: SignatureVerifier) {
            val sequence = entries.size.toLong()
            fun invalid(reason: String): Nothing =
                throw RosterException(
                    false,
                    "device roster entry is invalid at sequence $sequence: $reason",
                )
            if (sequence >= Rosters.MAX_ENTRIES) invalid("the roster is full")
            if (entry.sequence != sequence) invalid("sequence does not follow the head")
            val canonical = Rosters.canonical(entry)
            if (canonical.size + entry.signature.size > Rosters.MAX_ENTRY_BYTES)
                invalid("entry is too large")
            if (entry.created_at.encodeToByteArray().size > Rosters.MAX_SHORT_FIELD)
                invalid("created_at is too long")
            val device = entry.device
            if (device == null || device.device_id.isEmpty()) invalid("device is missing")
            val operation = entry.operation
            if (sequence == 0L) {
                if (
                    operation != DeviceRosterOperation.DEVICE_ROSTER_OPERATION_GENESIS ||
                        entry.previous.size != 0
                )
                    invalid("the first entry must be a genesis entry")
                val accountBytes = entry.account.encodeToByteArray().size
                if (accountBytes == 0 || accountBytes > 256) invalid("account is invalid")
                account = entry.account
            } else {
                if (entry.account != account) invalid("entry belongs to another account")
                if (entry.previous != hashes[(sequence - 1).toInt()])
                    invalid("previous hash does not match the head")
            }
            fun checkSignature(signer: RosterMember) {
                if (
                    !Rosters.verifies(
                        verifier,
                        signer.descriptor,
                        canonical,
                        entry.signature.toByteArray(),
                    )
                )
                    invalid("signature is invalid")
            }
            fun activeSigner(): RosterMember {
                val signer = byId[entry.signer]
                if (signer == null || !signer.active) invalid("signer is not an active member")
                checkSignature(signer)
                return signer
            }
            when (operation) {
                DeviceRosterOperation.DEVICE_ROSTER_OPERATION_GENESIS -> {
                    if (sequence != 0L) invalid("genesis must be the first entry")
                    Rosters.memberProblem(device)?.let { invalid(it) }
                    if (device.kind == DeviceKind.DEVICE_KIND_RECOVERY)
                        invalid("a recovery key cannot start a roster")
                    if (entry.signer != device.device_id)
                        invalid("genesis must be signed by its own device")
                    val member = RosterMember(device, addedBy = "", addedAt = 0)
                    checkSignature(member)
                    byId[device.device_id] = member
                    order += device.device_id
                }
                DeviceRosterOperation.DEVICE_ROSTER_OPERATION_ADD -> {
                    val signer = activeSigner()
                    if (device.device_id in byId) invalid("device was already added")
                    Rosters.memberProblem(device)?.let { invalid(it) }
                    if (byId.values.count { it.active } >= Rosters.MAX_ACTIVE)
                        invalid("the roster has too many active devices")
                    if (
                        device.kind == DeviceKind.DEVICE_KIND_DAEMON &&
                            byId.values.any {
                                it.active &&
                                    it.kind == DeviceKind.DEVICE_KIND_DAEMON &&
                                    it.descriptor.daemon_id == device.daemon_id
                            }
                    )
                        invalid("another active device is this machine")
                    byId[device.device_id] =
                        RosterMember(device, addedBy = signer.deviceId, addedAt = sequence)
                    order += device.device_id
                }
                DeviceRosterOperation.DEVICE_ROSTER_OPERATION_REVOKE -> {
                    activeSigner()
                    if (
                        device.kind != DeviceKind.DEVICE_KIND_UNSPECIFIED ||
                            device.platform.isNotEmpty() ||
                            device.name.isNotEmpty() ||
                            device.algorithm !=
                                DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_UNSPECIFIED ||
                            device.public_key.size != 0 ||
                            device.daemon_id.isNotEmpty()
                    )
                        invalid("a revocation names only the device ID")
                    val target = byId[device.device_id]
                    if (target == null || !target.active)
                        invalid("revoked device is not an active member")
                    if (target.connects && byId.values.count { it.connects } == 1)
                        invalid("the last device that can connect cannot be revoked")
                    byId[device.device_id] = target.copy(revoked = true, revokedAt = sequence)
                }
                else -> invalid("operation is unknown")
            }
            entries += entry
            hashes += canonical.toByteString().sha256()
        }
    }
}

private fun Long.toIntOrMax(): Int =
    if (this < 0 || this > Int.MAX_VALUE) Int.MAX_VALUE else toInt()
