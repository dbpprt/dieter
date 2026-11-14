package com.getdieter.core.testing

import com.getdieter.core.platform.JcaEcdsa
import com.getdieter.core.platform.SignatureVerifier
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import okio.ByteString
import okio.ByteString.Companion.toByteString

/**
 * Ed25519 and ECDSA P-256 through the JDK's providers; Android and Apple hosts supply their own.
 */
object JcaSignatureVerifier : SignatureVerifier {
    private val spkiPrefix =
        byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

    override fun verifyEd25519(
        publicKey: ByteArray,
        message: ByteArray,
        signature: ByteArray,
    ): Boolean = runCatching {
        val key =
            KeyFactory.getInstance("Ed25519")
                .generatePublic(X509EncodedKeySpec(spkiPrefix + publicKey))
        Signature.getInstance("Ed25519").run {
            initVerify(key)
            update(message)
            verify(signature)
        }
    }
        .getOrDefault(false)

    override fun verifyEcdsaP256(
        publicKey: ByteArray,
        message: ByteArray,
        signature: ByteArray,
    ): Boolean = JcaEcdsa.verify(publicKey, message, signature)
}

/**
 * A disposable Ed25519 machine identity for signing roster entries and screen bindings in tests.
 */
class TestMachineKey(
    private val pair: KeyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
) {
    /** The machine's DER SubjectPublicKeyInfo, as the device roster lists it. */
    val publicKey: ByteString = pair.public.encoded.toByteString()

    fun sign(message: ByteArray): ByteArray =
        Signature.getInstance("Ed25519").run {
            initSign(pair.private)
            update(message)
            sign()
        }
}
