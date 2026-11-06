package com.getdieter.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Device-bound encrypted storage for Dieter bearer sessions. */
class DieterCredentialStore(context: Context) {
    private val preferences =
        context.getSharedPreferences("dieter_native_credentials", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private data class CachedCredential(val encoded: String, val token: String?)

    private val decrypted =
        object : LinkedHashMap<String, CachedCredential>(16, 0.75f, true) {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<String, CachedCredential>?
            ) = size > 16
        }

    @Synchronized
    fun get(endpointID: String): String? {
        val encoded =
            preferences.getString(endpointID, null)
                ?: run {
                    decrypted.remove(endpointID)
                    return null
                }
        // SharedPreferences is process-shared. Compare the encrypted value so a
        // sign-in or sign-out through another store instance cannot leave this cache stale.
        decrypted[endpointID]?.let { if (it.encoded == encoded) return it.token }
        val token = runCatching {
            CredentialSeal.open(Base64.decode(encoded, Base64.NO_WRAP), ::key)
        }
            .getOrNull()
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
        val encoded = Base64.encodeToString(CredentialSeal.seal(token, ::key), Base64.NO_WRAP)
        preferences.edit().putString(endpointID, encoded).apply()
        decrypted[endpointID] = CachedCredential(encoded, token)
    }

    private fun key(): SecretKey {
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let {
            return it
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
            generateKey()
        }
    }

    private companion object {
        const val KEY_ALIAS = "dieter-native-session-v1"
    }
}
