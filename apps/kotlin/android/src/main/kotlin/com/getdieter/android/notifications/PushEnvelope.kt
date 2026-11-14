package com.getdieter.android.notifications

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.json.JSONObject

/** Platform crypto adapter for the daemon's X25519/HKDF-SHA256/AES-GCM envelope. */
internal object PushEnvelope {
    fun open(privateKey: ByteArray, sealed: ByteArray): String? = runCatching {
        require(sealed.size in 60..2048)
        val agreement = X25519Agreement()
        agreement.init(X25519PrivateKeyParameters(privateKey, 0))
        val secret = ByteArray(32)
        agreement.calculateAgreement(X25519PublicKeyParameters(sealed, 0), secret, 0)
        val info = "dieter-attention-v1".toByteArray()
        val symmetric = ByteArray(32)
        HKDFBytesGenerator(SHA256Digest()).apply {
            init(HKDFParameters(secret, byteArrayOf(), info))
            generateBytes(symmetric, 0, symmetric.size)
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(symmetric, "AES"),
            GCMParameterSpec(128, sealed.copyOfRange(32, 44)),
        )
        cipher.updateAAD(info)
        val plain = cipher.doFinal(sealed.copyOfRange(44, sealed.size))
        JSONObject(String(plain, Charsets.UTF_8)).getString("cardId").takeIf {
            it.isNotBlank() && it.length <= 256
        }
    }
        .getOrNull()
}
