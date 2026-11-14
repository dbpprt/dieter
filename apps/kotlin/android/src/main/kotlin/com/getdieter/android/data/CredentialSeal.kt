package com.getdieter.android.data

import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The stored form of a session token: AES-GCM under a device-bound key, framed as the IV's length
 * (one byte), the IV, then the ciphertext and its tag. A record that is malformed, tampered with,
 * or sealed by another key does not open. The key is fetched only for a well-formed record.
 */
internal object CredentialSeal {
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val TAG_BITS = 128

    fun seal(token: String, key: () -> SecretKey): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        return byteArrayOf(cipher.iv.size.toByte()) + cipher.iv + encrypted
    }

    /** The token sealed in [stored]; throws when it does not open. */
    fun open(stored: ByteArray, key: () -> SecretKey): String {
        val ivLength = stored.first().toInt() and 0xff
        require(ivLength in 12..16 && stored.size > ivLength + 1)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(),
            GCMParameterSpec(TAG_BITS, stored.copyOfRange(1, ivLength + 1)),
        )
        return String(cipher.doFinal(stored.copyOfRange(ivLength + 1, stored.size)), Charsets.UTF_8)
    }
}
