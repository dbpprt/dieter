package com.getdieter.core.trust

import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.toByteString

/**
 * The two device key encodings the roster allows, as DER SubjectPublicKeyInfo. Only the exact DER
 * forms Go's `x509.ParsePKIXPublicKey` accepts for these keys are recognized: Ed25519 (daemons,
 * recovery keys) and uncompressed ECDSA P-256 (apps).
 */
object DeviceKeyFormats {
    /** SEQUENCE { SEQUENCE { OID 1.3.101.112 } BIT STRING (0 unused bits, 32 bytes) }. */
    private val ED25519_PREFIX =
        byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

    /**
     * SEQUENCE { SEQUENCE { OID id-ecPublicKey, OID prime256v1 } BIT STRING (0 unused bits, 0x04 X
     * Y) }.
     */
    private val P256_PREFIX =
        byteArrayOf(
            0x30,
            0x59,
            0x30,
            0x13,
            0x06,
            0x07,
            0x2a,
            0x86.toByte(),
            0x48,
            0xce.toByte(),
            0x3d,
            0x02,
            0x01,
            0x06,
            0x08,
            0x2a,
            0x86.toByte(),
            0x48,
            0xce.toByte(),
            0x3d,
            0x03,
            0x01,
            0x07,
            0x03,
            0x42,
            0x00,
            0x04,
        )

    /** The raw 32-byte key of an Ed25519 SubjectPublicKeyInfo, or null. */
    fun ed25519Raw(spki: ByteArray): ByteArray? =
        if (spki.size == ED25519_PREFIX.size + 32 && spki.startsWith(ED25519_PREFIX))
            spki.copyOfRange(ED25519_PREFIX.size, spki.size)
        else null

    /** An uncompressed ECDSA P-256 SubjectPublicKeyInfo. */
    fun isP256(spki: ByteArray): Boolean =
        spki.size == P256_PREFIX.size + 64 && spki.startsWith(P256_PREFIX)

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean =
        size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
}

/**
 * A self-signed X.509 certificate for this install's device key: the container a TLS client
 * certificate needs. The daemon reads only its SubjectPublicKeyInfo and checks it against the
 * roster; issuer, validity and serial carry no trust. The certificate is deterministic apart from
 * the ECDSA signature, so the core can rebuild it at any time.
 */
object DeviceCertificate {
    /** ecdsa-with-SHA256 (1.2.840.10045.4.3.2), parameters absent. */
    private val ECDSA_WITH_SHA256 =
        Der.sequence(
            Der.tlv(
                0x06,
                byteArrayOf(0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x04, 0x03, 0x02),
            )
        )

    /** commonName (2.5.4.3). */
    private val COMMON_NAME = Der.tlv(0x06, byteArrayOf(0x55, 0x04, 0x03))

    // UTCTime 2020-01-01 and RFC 5280's "no well-defined expiration" GeneralizedTime.
    private const val NOT_BEFORE = "200101000000Z"
    private const val NOT_AFTER = "99991231235959Z"

    /**
     * The DER certificate of [publicKey] (an ECDSA P-256 SubjectPublicKeyInfo) named [deviceId],
     * signed by [sign], which returns a DER ECDSA signature over SHA-256 of its input.
     */
    fun selfSigned(
        publicKey: ByteArray,
        deviceId: String,
        sign: (ByteArray) -> ByteArray,
    ): ByteString {
        require(DeviceKeyFormats.isP256(publicKey)) { "device key must be ECDSA P-256" }
        val name =
            Der.sequence(
                Der.set(Der.sequence(COMMON_NAME, Der.tlv(0x0c, deviceId.encodeToByteArray())))
            )
        val tbs =
            Der.sequence(
                // [0] EXPLICIT Version v3.
                Der.tlv(0xa0, Der.tlv(0x02, byteArrayOf(0x02))),
                Der.tlv(0x02, serial(publicKey)),
                ECDSA_WITH_SHA256,
                name,
                Der.sequence(
                    Der.tlv(0x17, NOT_BEFORE.encodeToByteArray()),
                    Der.tlv(0x18, NOT_AFTER.encodeToByteArray()),
                ),
                name,
                publicKey,
            )
        val signature = sign(tbs)
        return Der.sequence(tbs, ECDSA_WITH_SHA256, Der.tlv(0x03, byteArrayOf(0) + signature))
            .toByteString()
    }

    /** A positive, minimal 8-byte serial derived from the key. */
    private fun serial(publicKey: ByteArray): ByteArray =
        publicKey.toByteString().sha256().toByteArray().copyOf(8).also {
            it[0] = ((it[0].toInt() and 0x3f) or 0x40).toByte()
        }
}

/** Minimal DER encoding: definite lengths, caller-ordered contents. */
internal object Der {
    fun tlv(tag: Int, content: ByteArray): ByteArray {
        val out = Buffer().writeByte(tag)
        val length = content.size
        when {
            length < 0x80 -> out.writeByte(length)
            length <= 0xff -> out.writeByte(0x81).writeByte(length)
            length <= 0xffff -> out.writeByte(0x82).writeShort(length)
            else -> out.writeByte(0x83).writeByte(length shr 16).writeShort(length and 0xffff)
        }
        return out.write(content).readByteArray()
    }

    fun sequence(vararg parts: ByteArray): ByteArray = tlv(0x30, concat(parts))

    fun set(vararg parts: ByteArray): ByteArray = tlv(0x31, concat(parts))

    private fun concat(parts: Array<out ByteArray>): ByteArray {
        val out = Buffer()
        parts.forEach { out.write(it) }
        return out.readByteArray()
    }
}
