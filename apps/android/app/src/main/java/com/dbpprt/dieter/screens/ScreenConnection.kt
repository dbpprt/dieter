package com.dbpprt.dieter.screens

import com.dbpprt.dieter.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.v1.DieterServiceGrpcKt
import com.dbpprt.dieter.v1.RemoteDesktopSessionBinding
import org.bouncycastle.asn1.x509.Certificate
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64

/** Owns an independent authenticated route; never changes foreground project routing. */
class ScreenConnection(
    val rpc: DieterServiceGrpcKt.DieterServiceCoroutineStub,
    val certificate: ByteArray,
    val rtc: RTCConfiguration,
    val route: String,
    val refreshAtMillis: Long? = null,
    private val onClose: () -> Unit,
) : AutoCloseable {
    override fun close() = onClose()
}

internal object ScreenTrust {
    fun verify(binding: RemoteDesktopSessionBinding, session: String, nonce: String, offer: String,
               answer: String, certificate: ByteArray, control: Boolean, display: String, protocol: Int = 2) {
        val hash = MessageDigest.getInstance("SHA-256").digest(offer.toByteArray())
        val fingerprints = answer.lineSequence().map(String::trim)
            .filter { it.startsWith("a=fingerprint:") }.map { it.substringAfter("a=fingerprint:").trim() }.toSet()
        require(session.isNotEmpty() && binding.clientNonce == nonce && binding.offerSha256.toByteArray().contentEquals(hash) &&
            fingerprints == setOf(binding.helperDtlsFingerprint) && binding.helperDtlsFingerprint.startsWith("sha-256 ") &&
            protocol in 2..3 && binding.inputProtocolVersion == protocol && binding.inputEpoch.size() == 16 &&
            binding.controlGranted == control && binding.displayId == display) { "Untrusted screen-sharing session" }
        require(Instant.parse(binding.expiresAt).isAfter(Instant.now())) { "Screen-sharing session expired" }
        val body = certificate.decodeToString().replace("-----BEGIN CERTIFICATE-----", "")
            .replace("-----END CERTIFICATE-----", "").filterNot(Char::isWhitespace)
        val key = Certificate.getInstance(Base64.getDecoder().decode(body)).subjectPublicKeyInfo
        require(key.algorithm.algorithm.id == "1.3.101.112") { "Invalid enrolled daemon key" }
        val encoder = Base64.getUrlEncoder().withoutPadding()
        val message = listOf("dieter-remote-desktop-v$protocol", session, nonce, binding.helperDtlsFingerprint,
            binding.expiresAt, encoder.encodeToString(hash), control.toString(), display, protocol.toString(),
            encoder.encodeToString(binding.inputEpoch.toByteArray())).joinToString("\n").toByteArray()
        val verifier = Ed25519Signer()
        verifier.init(false, Ed25519PublicKeyParameters(key.publicKeyData.bytes, 0))
        verifier.update(message, 0, message.size)
        require(verifier.verifySignature(binding.daemonSignature.toByteArray())) { "Invalid screen-sharing signature" }
    }
}
