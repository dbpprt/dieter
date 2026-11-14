package com.getdieter.android.notifications

import com.getdieter.android.data.DieterCredentialStore
import java.security.SecureRandom
import okio.ByteString
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters

/** Per-account keys encrypted by Android Keystore, excluded from backups. */
internal class AndroidPushKeys(private val credentials: DieterCredentialStore) {
    @Synchronized
    private fun key(account: String): X25519PrivateKeyParameters? = runCatching {
        val name = "push.private." + account.encodeUtf8().sha256().hex()
        val saved = credentials.get(name)
        if (saved != null)
            return@runCatching X25519PrivateKeyParameters(saved.decodeBase64()!!.toByteArray(), 0)
        val key = X25519PrivateKeyParameters(SecureRandom())
        val encoded = key.encoded.toByteString().base64()
        credentials.set(name, encoded)
        check(credentials.get(name) == encoded)
        key
    }
        .getOrNull()

    fun publicKey(account: String): ByteString? =
        key(account)?.generatePublicKey()?.encoded?.toByteString()

    fun open(account: String, sealed: ByteString): String? =
        key(account)?.let { PushEnvelope.open(it.encoded, sealed.toByteArray()) }
}
