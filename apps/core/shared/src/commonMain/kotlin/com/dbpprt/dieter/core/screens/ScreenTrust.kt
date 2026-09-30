package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Instant
import okio.ByteString
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.encodeUtf8

const val SCREEN_INPUT_PROTOCOL = 3

class ScreenTrustException(message: String) : IllegalStateException(message)

/**
 * Verifies the daemon-signed binding of a screen session: it ties the
 * session to this client's offer, the host's DTLS fingerprint, the granted
 * control and display, and an input epoch. The signature must come from the
 * enrolled daemon's Ed25519 certificate. Any failure is fatal.
 */
object ScreenTrust {
    private const val CONTEXT = "dieter-remote-desktop-v3"

    /** The exact signed message: ten fields joined by newlines. */
    fun message(sessionId: String, binding: RemoteDesktopSessionBinding): ByteString = listOf(
        CONTEXT, sessionId, binding.client_nonce, binding.helper_dtls_fingerprint, binding.expires_at,
        binding.offer_sha256.base64Url().trimEnd('='), binding.control_granted.toString(), binding.display_id,
        binding.input_protocol_version.toString(), binding.input_epoch.base64Url().trimEnd('='),
    ).joinToString("\n").encodeUtf8()

    fun verify(
        binding: RemoteDesktopSessionBinding,
        sessionId: String,
        request: StartRemoteDesktopRequest,
        answerSdp: String,
        certificatePem: String,
        now: Instant,
        verifier: SignatureVerifier,
    ) {
        fun fail(reason: String): Nothing = throw ScreenTrustException(reason)
        if (sessionId.isEmpty()) fail("The screen session has no identity.")
        if (binding.client_nonce != request.client_nonce) fail("The screen session belongs to another request.")
        val offer = request.offer?.sdp ?: fail("The screen request has no offer.")
        if (binding.offer_sha256 != offer.encodeUtf8().sha256()) fail("The screen session answers another offer.")
        val fingerprints = answerSdp.lineSequence().map { it.trim() }.filter { it.startsWith("a=fingerprint:") }
            .map { it.removePrefix("a=fingerprint:").trim() }.toSet()
        if (fingerprints != setOf(binding.helper_dtls_fingerprint) || !binding.helper_dtls_fingerprint.startsWith("sha-256 ")) {
            fail("The screen host's encryption key does not match the signed session.")
        }
        if (binding.input_protocol_version != SCREEN_INPUT_PROTOCOL || request.input_protocol_version != SCREEN_INPUT_PROTOCOL) {
            fail("Update the Dieter daemon and client together")
        }
        if (binding.input_epoch.size != 16) fail("The screen session has an invalid input epoch.")
        if (binding.control_granted != request.control || binding.display_id != request.display_id.ifEmpty { "primary" }) {
            fail("The screen session does not match the requested display or control.")
        }
        val expires = Timestamps.parse(binding.expires_at) ?: fail("The screen session has an invalid expiry.")
        if (expires <= now) fail("The screen session expired before it was verified. Check this device's clock.")
        val key = ed25519PublicKey(certificatePem) ?: fail("The machine certificate is not an Ed25519 certificate.")
        if (binding.daemon_signature.size != 64 || !verifier.verifyEd25519(key.toByteArray(), message(sessionId, binding).toByteArray(), binding.daemon_signature.toByteArray())) {
            fail("The screen session was not signed by the enrolled machine.")
        }
    }

    /** The raw 32-byte key from an X.509 certificate's Ed25519 SubjectPublicKeyInfo. */
    fun ed25519PublicKey(pem: String): ByteString? {
        val body = pem.lineSequence().filterNot { it.startsWith("-----") }.joinToString("").filterNot { it.isWhitespace() }
        val der = body.decodeBase64() ?: return null
        // SubjectPublicKeyInfo for Ed25519: SEQUENCE { SEQUENCE { OID 1.3.101.112 } BIT STRING (0 unused bits, 32 bytes) }.
        val prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)
        val bytes = der.toByteArray()
        outer@ for (start in 0..bytes.size - prefix.size - 32) {
            for (index in prefix.indices) if (bytes[start + index] != prefix[index]) continue@outer
            return der.substring(start + prefix.size, start + prefix.size + 32)
        }
        return null
    }
}
