package com.dbpprt.dieter.screens

import com.dbpprt.dieter.data.DIETER_PROTOCOL_VERSION

import com.dbpprt.dieter.v1.RemoteDesktopSessionBinding
import com.google.protobuf.ByteString
import java.security.MessageDigest
import java.util.Base64
import java.util.Properties
import org.junit.Assert.*
import org.junit.Test

class ScreenTrustTest {
    private val fixture = Properties().apply { load(ScreenTrustTest::class.java.getResourceAsStream("/screen-trust.properties")) }
    private fun bytes(key: String) = Base64.getDecoder().decode(fixture.getProperty(key))
    private val binding get() = RemoteDesktopSessionBinding.newBuilder().setClientNonce("nonce")
        .setHelperDtlsFingerprint("sha-256 01:23:45").setExpiresAt("2100-01-01T00:00:00Z")
        .setOfferSha256(ByteString.copyFrom(MessageDigest.getInstance("SHA-256").digest("test offer".toByteArray())))
        .setDaemonSignature(ByteString.copyFrom(bytes("signature"))).setControlGranted(true).setDisplayId("primary")
        .setInputProtocolVersion(DIETER_PROTOCOL_VERSION).setInputEpoch(ByteString.copyFrom(bytes("epoch"))).build()
    private fun verify(value: RemoteDesktopSessionBinding = binding, offer: String = "test offer", answer: String = "a=fingerprint:sha-256 01:23:45\r\n") =
        ScreenTrust.verify(value, "session", "nonce", offer, answer, bytes("certificate"), true, "primary")
    @Test fun acceptsDaemonSignatureFromIndependentGoFixture() { verify() }
    @Test fun rejectsAlteredOfferAndConflictingFingerprints() {
        assertThrows(IllegalArgumentException::class.java) { verify(offer = "other offer") }
        assertThrows(IllegalArgumentException::class.java) { verify(answer = "a=fingerprint:sha-256 01:23:45\na=fingerprint:sha-256 99:99") }
    }
    @Test fun rejectsPrivilegeEpochDisplayAndExpiryChanges() {
        listOf(binding.toBuilder().setControlGranted(false), binding.toBuilder().setDisplayId("secondary"),
            binding.toBuilder().setInputEpoch(ByteString.copyFrom(ByteArray(16))), binding.toBuilder().setInputProtocolVersion(0),
            binding.toBuilder().setExpiresAt("2020-01-01T00:00:00Z"), binding.toBuilder().setDaemonSignature(ByteString.copyFrom(ByteArray(64))))
            .forEach { value -> assertThrows(IllegalArgumentException::class.java) { verify(value.build()) } }
    }
}
