package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopSessionBinding
import com.getdieter.api.v1.StartRemoteDesktopRequest
import com.getdieter.core.platform.SignatureVerifier
import com.getdieter.core.runtime.Timestamps
import com.getdieter.core.trust.DeviceKeyFormats
import kotlin.time.Instant
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

const val SCREEN_INPUT_PROTOCOL = 3

class ScreenTrustException(message: String) : IllegalStateException(message)

/**
 * Verifies the daemon-signed binding of a screen session: it ties the session to this client's
 * offer, the host's DTLS fingerprint, the granted control and display, and an input epoch. The
 * signature must come from the machine's Ed25519 key in the pinned device roster. Any failure is
 * fatal.
 */
object ScreenTrust {
    private const val CONTEXT = "dieter-remote-desktop-v3"

    /** The exact signed message: ten fields joined by newlines. */
    fun message(sessionId: String, binding: RemoteDesktopSessionBinding): ByteString =
        listOf(
                CONTEXT,
                sessionId,
                binding.client_nonce,
                binding.helper_dtls_fingerprint,
                binding.expires_at,
                binding.offer_sha256.base64Url().trimEnd('='),
                binding.control_granted.toString(),
                binding.display_id,
                binding.input_protocol_version.toString(),
                binding.input_epoch.base64Url().trimEnd('='),
            )
            .joinToString("\n")
            .encodeUtf8()

    fun verify(
        binding: RemoteDesktopSessionBinding,
        sessionId: String,
        request: StartRemoteDesktopRequest,
        answerSdp: String,
        daemonPublicKey: ByteString,
        now: Instant,
        verifier: SignatureVerifier,
    ) {
        fun fail(reason: String): Nothing = throw ScreenTrustException(reason)
        if (sessionId.isEmpty()) fail("The screen session has no identity.")
        if (binding.client_nonce != request.client_nonce)
            fail("The screen session belongs to another request.")
        val offer = request.offer?.sdp ?: fail("The screen request has no offer.")
        if (binding.offer_sha256 != offer.encodeUtf8().sha256())
            fail("The screen session answers another offer.")
        val fingerprints =
            answerSdp
                .lineSequence()
                .map { it.trim() }
                .filter { it.startsWith("a=fingerprint:") }
                .map { it.removePrefix("a=fingerprint:").trim() }
                .toSet()
        if (
            fingerprints != setOf(binding.helper_dtls_fingerprint) ||
                !binding.helper_dtls_fingerprint.startsWith("sha-256 ")
        ) {
            fail("The screen host's encryption key does not match the signed session.")
        }
        if (
            binding.input_protocol_version != SCREEN_INPUT_PROTOCOL ||
                request.input_protocol_version != SCREEN_INPUT_PROTOCOL
        ) {
            fail("Update the Dieter daemon and client together")
        }
        if (binding.input_epoch.size != 16) fail("The screen session has an invalid input epoch.")
        if (
            binding.control_granted != request.control ||
                binding.display_id != request.display_id.ifEmpty { "primary" }
        ) {
            fail("The screen session does not match the requested display or control.")
        }
        val expires =
            Timestamps.parse(binding.expires_at)
                ?: fail("The screen session has an invalid expiry.")
        if (expires <= now)
            fail("The screen session expired before it was verified. Check this device's clock.")
        val key =
            DeviceKeyFormats.ed25519Raw(daemonPublicKey.toByteArray())
                ?: fail("The machine's trusted key is not an Ed25519 key.")
        if (
            binding.daemon_signature.size != 64 ||
                !verifier.verifyEd25519(
                    key,
                    message(sessionId, binding).toByteArray(),
                    binding.daemon_signature.toByteArray(),
                )
        ) {
            fail("The screen session was not signed by the trusted machine.")
        }
    }
}
