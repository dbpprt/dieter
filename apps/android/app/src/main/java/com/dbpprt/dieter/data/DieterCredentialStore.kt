package com.dbpprt.dieter.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound encrypted storage for Dieter bearer sessions. */
class DieterCredentialStore(context: Context) {
    private val preferences = context.getSharedPreferences("dieter_native_credentials", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private data class CachedCredential(val encoded: String, val token: String?)
    private val decrypted = object : LinkedHashMap<String, CachedCredential>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedCredential>?) = size > 16
    }

    @Synchronized
    fun get(endpointID: String): String? {
        val encoded = preferences.getString(endpointID, null) ?: run {
            decrypted.remove(endpointID)
            return null
        }
        // SharedPreferences is process-shared. Compare the encrypted value so
        // another repository's sign-in/sign-out cannot leave this cache stale.
        decrypted[endpointID]?.let { if (it.encoded == encoded) return it.token }
        val token = runCatching {
            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
            val ivLength = bytes.first().toInt() and 0xff
            require(ivLength in 12..16 && bytes.size > ivLength + 1)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(1, ivLength + 1)))
            String(cipher.doFinal(bytes.copyOfRange(ivLength + 1, bytes.size)), Charsets.UTF_8)
        }.getOrNull()
        // A temporarily unavailable Keystore is retryable; cache successful
        // decryptions only, not a transient authentication failure.
        if (token != null) decrypted[endpointID] = CachedCredential(encoded, token)
        return token
    }

    @Synchronized
    fun set(endpointID: String, token: String?) {
        if (token == null) {
            preferences.edit().remove(endpointID).apply()
            decrypted.remove(endpointID)
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        val stored = byteArrayOf(cipher.iv.size.toByte()) + cipher.iv + encrypted
        val encoded = Base64.encodeToString(stored, Base64.NO_WRAP)
        preferences.edit().putString(endpointID, encoded).apply()
        decrypted[endpointID] = CachedCredential(encoded, token)
    }

    private fun key(): SecretKey {
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }

    private companion object { const val KEY_ALIAS = "dieter-native-session-v1" }
}
