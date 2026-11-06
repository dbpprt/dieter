package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.core.runtime.secureRandomBytes
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.toByteString

/**
 * A new device joins with a one-time secret that only its own screen shows, as a code a person
 * types on a trusted device. The secret never reaches the gateway: the request's proof binds the
 * new device's descriptor, so the approver adds exactly that key, and the approver's confirmation
 * binds the roster root and the entry that added the device, so the new device pins the approver's
 * roster rather than one the gateway made up. `internal/security/roster/pairing.go` is the Go side.
 */
object Pairing {
    const val SECRET_BYTES = 10
    private const val REQUEST_LABEL = "dieter-pair-request-v1"
    private const val CONFIRM_LABEL = "dieter-pair-confirm-v1"

    /** A fresh pairing secret. */
    fun newSecret(): ByteArray = secureRandomBytes(SECRET_BYTES)

    /** The printable form of [secret], e.g. "ABCD-EFGH-JKMN-PQRS". */
    fun code(secret: ByteArray): String = Codes.group(Codes.encode(secret), 4)

    /**
     * The secret of a typed code in any case, with or without separators and with confusable
     * characters; null when it is not a pairing code.
     */
    fun parse(code: String): ByteArray? =
        Codes.decode(code)?.takeIf { it.size == SECRET_BYTES && Codes.normalize(code).length == 16 }

    /** Authenticates a pairing request's descriptor. */
    fun proof(secret: ByteArray, device: DeviceDescriptor): ByteString =
        mac(secret, REQUEST_LABEL, Rosters.descriptorBytes(device))

    fun verifyProof(secret: ByteArray, device: DeviceDescriptor, proof: ByteString): Boolean =
        constantTimeEquals(proof(secret, device).toByteArray(), proof.toByteArray())

    /** Authenticates the roster a new device pins: its root and the entry that added it. */
    fun confirmation(secret: ByteArray, root: ByteString, addition: ByteString): ByteString =
        mac(secret, CONFIRM_LABEL, root.toByteArray(), addition.toByteArray())

    fun verifyConfirmation(
        secret: ByteArray,
        root: ByteString,
        addition: ByteString,
        confirmation: ByteString,
    ): Boolean =
        constantTimeEquals(
            confirmation(secret, root, addition).toByteArray(),
            confirmation.toByteArray(),
        )

    private fun mac(secret: ByteArray, label: String, vararg fields: ByteArray): ByteString {
        val message = Buffer().writeUtf8(label)
        Rosters.writeFields(message, *fields)
        return message.readByteString().hmacSha256(secret.toByteString())
    }
}
