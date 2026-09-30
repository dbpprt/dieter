package com.dbpprt.dieter.core.testing

import com.dbpprt.dieter.core.platform.SignatureVerifier
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** Ed25519 through the JDK's provider; Android and Apple hosts supply their own. */
object JcaSignatureVerifier : SignatureVerifier {
    private val spkiPrefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

    override fun verifyEd25519(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean = runCatching {
        val key = KeyFactory.getInstance("Ed25519").generatePublic(X509EncodedKeySpec(spkiPrefix + publicKey))
        Signature.getInstance("Ed25519").run {
            initVerify(key)
            update(message)
            verify(signature)
        }
    }.getOrDefault(false)
}

/** A disposable Ed25519 machine identity for signing screen bindings in tests. */
class TestMachineKey(private val pair: KeyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()) {
    /** A PEM wrapping the SubjectPublicKeyInfo, which is all the core reads from a certificate. */
    val certificatePem: String = "-----BEGIN CERTIFICATE-----\n" +
        Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(pair.public.encoded) + "\n-----END CERTIFICATE-----\n"

    fun sign(message: ByteArray): ByteArray = Signature.getInstance("Ed25519").run {
        initSign(pair.private)
        update(message)
        sign()
    }
}
