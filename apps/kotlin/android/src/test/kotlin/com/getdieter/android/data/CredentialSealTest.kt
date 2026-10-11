package com.getdieter.android.data

import java.security.GeneralSecurityException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/**
 * Session tokens sealed with AES-GCM, as the credential store keeps them, with a JVM key in place
 * of the Android Keystore's.
 */
class CredentialSealTest {
    private fun newKey(): SecretKey =
        KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    private val key = newKey()
    private val token = "isolated-session-token-é"

    @Test
    fun aSealedTokenOpensWithItsKey() {
        val stored = CredentialSeal.seal(token) { key }
        val ivLength = stored.first().toInt()
        assertEquals(12, ivLength)
        assertEquals(1 + ivLength + token.toByteArray().size + 16, stored.size, "IV and GCM tag")
        assertEquals(token, CredentialSeal.open(stored) { key })
        assertFalse(
            CredentialSeal.seal(token) { key }.contentEquals(stored),
            "every seal uses a fresh IV",
        )
    }

    @Test
    fun anotherKeyOrAnyChangedByteDoesNotOpen() {
        val stored = CredentialSeal.seal(token) { key }
        assertFailsWith<GeneralSecurityException> { CredentialSeal.open(stored) { newKey() } }
        for (index in 1 until stored.size) {
            val tampered = stored.copyOf().also { it[index] = (it[index] + 1).toByte() }
            assertFailsWith<GeneralSecurityException>("byte $index") {
                CredentialSeal.open(tampered) { key }
            }
        }
    }

    @Test
    fun aMalformedRecordFailsWithoutFetchingTheKey() {
        var fetched = 0
        val counting = {
            fetched++
            key
        }
        assertFailsWith<NoSuchElementException> { CredentialSeal.open(ByteArray(0), counting) }
        for (record in
            listOf(
                byteArrayOf(11) + ByteArray(11) + ByteArray(20),
                byteArrayOf(17) + ByteArray(17) + ByteArray(20),
                byteArrayOf(12) + ByteArray(12),
                byteArrayOf(12) + ByteArray(5),
            )) {
            assertFailsWith<IllegalArgumentException> { CredentialSeal.open(record, counting) }
        }
        assertEquals(0, fetched)
    }

    @Test
    fun theRecordLayoutIsLengthIvThenCiphertext() {
        val stored = CredentialSeal.seal(token) { key }
        val iv = stored.copyOfRange(1, 13)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE,
            key,
            javax.crypto.spec.GCMParameterSpec(128, iv),
        )
        assertContentEquals(
            token.toByteArray(),
            cipher.doFinal(stored.copyOfRange(13, stored.size)),
        )
    }
}
