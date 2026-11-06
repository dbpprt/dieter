package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.api.gateway.v1.DeviceKeyAlgorithm
import com.getdieter.api.gateway.v1.DeviceKind
import com.getdieter.api.gateway.v1.DeviceRosterEntry
import com.getdieter.core.testing.JcaSignatureVerifier
import java.io.ByteArrayInputStream
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/** What a gateway could forge, and every way an entry can fail to extend a pinned roster. */
class RosterTest {
    private val machine = Signer.machine("d_studio")
    private val phone = Signer.app("Phone")
    private val base = roster(genesis(machine)).add(phone.descriptor, machine)

    private fun rejects(entry: DeviceRosterEntry, roster: Roster = base): RosterException =
        assertFailsWith<RosterException> { roster.extend(listOf(entry), JcaSignatureVerifier) }

    @Test
    fun membersAddAndRevokeDevicesSignedByMembers() {
        val laptop = Signer.app("Laptop")
        val second = Signer.machine("d_build", "Build box")
        val grown = base.add(laptop.descriptor, phone).add(second.descriptor, laptop)
        assertEquals(4, grown.length)
        assertEquals(phone.id, grown.member(laptop.id)?.addedBy)
        assertEquals(second.id, grown.daemon("d_build")?.deviceId)
        val revoked = grown.revoke(second.id, phone)
        assertTrue(revoked.member(second.id)!!.revoked)
        assertNull(revoked.daemon("d_build"))
        // A device may revoke itself.
        assertTrue(revoked.revoke(laptop.id, laptop).member(laptop.id)!!.revoked)
    }

    @Test
    fun entriesTheGatewayCouldForgeAreRejected() {
        val stranger = Signer.app("Stranger")
        val laptop = Signer.app("Laptop")
        // Signed by a key that is not a member.
        rejects(
            Roster.signed(base.addition(laptop.descriptor, stranger.id, CREATED), stranger.sign)
        )
        // A member's ID with another key's signature.
        rejects(Roster.signed(base.addition(laptop.descriptor, phone.id, CREATED), stranger.sign))
        // A valid signature over other bytes.
        val signed = Roster.signed(base.addition(laptop.descriptor, phone.id, CREATED), phone.sign)
        rejects(signed.copy(created_at = "2026-10-12T09:00:01Z"))
        // Another account, another previous hash, a skipped sequence.
        rejects(
            Roster.signed(
                base
                    .addition(laptop.descriptor, phone.id, CREATED)
                    .copy(account = "other|github:1"),
                phone.sign,
            )
        )
        rejects(
            Roster.signed(
                base
                    .addition(laptop.descriptor, phone.id, CREATED)
                    .copy(previous = "forged".encodeUtf8().sha256()),
                phone.sign,
            )
        )
        rejects(
            Roster.signed(
                base.addition(laptop.descriptor, phone.id, CREATED).copy(sequence = 3),
                phone.sign,
            )
        )
        // A device ID that is not its key's.
        rejects(
            Roster.signed(
                base.addition(laptop.descriptor.copy(device_id = stranger.id), phone.id, CREATED),
                phone.sign,
            )
        )
        // Re-adding a member.
        rejects(Roster.signed(base.addition(phone.descriptor, machine.id, CREATED), machine.sign))
    }

    @Test
    fun revokedSignersCannotSign() {
        val laptop = Signer.app("Laptop")
        val revoked = base.add(laptop.descriptor, machine).revoke(laptop.id, machine)
        val tablet = Signer.app("Tablet")
        rejects(
            Roster.signed(revoked.addition(tablet.descriptor, laptop.id, CREATED), laptop.sign),
            revoked,
        )
    }

    @Test
    fun descriptorsFollowTheirKindsRules() {
        val second = Signer.machine("d_studio", "Second Studio")
        // One active device per machine.
        rejects(Roster.signed(base.addition(second.descriptor, phone.id, CREATED), phone.sign))
        // A machine needs its daemon ID; an app has none.
        rejects(
            Roster.signed(
                base.addition(second.descriptor.copy(daemon_id = ""), phone.id, CREATED),
                phone.sign,
            )
        )
        val tablet = Signer.app("Tablet")
        rejects(
            Roster.signed(
                base.addition(tablet.descriptor.copy(daemon_id = "d_x"), phone.id, CREATED),
                phone.sign,
            )
        )
        // A machine's key must be Ed25519, names are bounded, platforms are [a-z0-9].
        rejects(
            Roster.signed(
                base.addition(
                    tablet.descriptor.copy(kind = DeviceKind.DEVICE_KIND_DAEMON, daemon_id = "d_x"),
                    phone.id,
                    CREATED,
                ),
                phone.sign,
            )
        )
        rejects(
            Roster.signed(
                base.addition(tablet.descriptor.copy(name = "x".repeat(65)), phone.id, CREATED),
                phone.sign,
            )
        )
        rejects(
            Roster.signed(
                base.addition(tablet.descriptor.copy(name = "bell\u0007"), phone.id, CREATED),
                phone.sign,
            )
        )
        rejects(
            Roster.signed(
                base.addition(tablet.descriptor.copy(platform = "Android"), phone.id, CREATED),
                phone.sign,
            )
        )
        rejects(
            Roster.signed(
                base.addition(
                    tablet.descriptor.copy(
                        algorithm = DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ED25519
                    ),
                    phone.id,
                    CREATED,
                ),
                phone.sign,
            )
        )
        assertEquals(
            "a recovery key cannot ask to join",
            Rosters.descriptorProblem(Signer.recovery().descriptor),
        )
        assertNull(Rosters.descriptorProblem(tablet.descriptor))
    }

    @Test
    fun revocationsNameOnlyAnActiveDeviceAndKeepOneThatConnects() {
        rejects(
            Roster.signed(
                base.revocation(phone.id, machine.id, CREATED).let {
                    it.copy(device = it.device!!.copy(name = "Phone"))
                },
                machine.sign,
            )
        )
        rejects(Roster.signed(base.revocation("dv_unknown", machine.id, CREATED), machine.sign))
        val alone = base.revoke(phone.id, machine)
        rejects(
            Roster.signed(alone.revocation(machine.id, machine.id, CREATED), machine.sign),
            alone,
        )
        rejects(Roster.signed(alone.revocation(phone.id, machine.id, CREATED), machine.sign), alone)
    }

    @Test
    fun theFirstEntryIsASelfSignedGenesisOfAMachineOrApp() {
        assertFailsWith<RosterException> { roster(genesis(Signer.recovery())) }
        assertFailsWith<RosterException> {
            roster(genesis(machine).copy(signer = phone.id))
        }
        assertFailsWith<RosterException> {
            roster(Roster.signed(genesis(machine).copy(previous = "x".encodeUtf8()), machine.sign))
        }
        assertFailsWith<RosterException> { roster() }
        assertEquals(phone.id, roster(genesis(phone)).members.single().deviceId)
    }

    @Test
    fun aDifferentEntryAtAPinnedSequenceIsAConflict() {
        val laptop = Signer.app("Laptop")
        val tablet = Signer.app("Tablet")
        val pinned = base.add(laptop.descriptor, phone)
        val fork = base.add(tablet.descriptor, phone)
        // The same history is accepted again, and extended.
        assertEquals(pinned.length, pinned.extend(pinned.entries, JcaSignatureVerifier).length)
        val longer = pinned.add(tablet.descriptor, machine)
        assertEquals(4, pinned.extend(longer.entries, JcaSignatureVerifier).length)
        val conflict =
            assertFailsWith<RosterException> { pinned.extend(fork.entries, JcaSignatureVerifier) }
        assertTrue(conflict.conflict)
        // A new genesis, e.g. a replaced roster, conflicts as well.
        val replaced = roster(genesis(Signer.machine("d_other")))
        assertTrue(
            assertFailsWith<RosterException> {
                    pinned.extend(replaced.entries, JcaSignatureVerifier)
                }
                .conflict
        )
        // An invalid entry is not a conflict.
        assertFalse(
            rejects(longer.entries.last().copy(signature = ByteArray(70).toByteString()), pinned)
                .conflict
        )
        // Nor is garbled data at a pinned sequence: only a member-signed fork is evidence.
        val garbled = fork.entries.last().copy(signature = ByteArray(70).toByteString())
        assertFalse(
            assertFailsWith<RosterException> {
                    pinned.extend(listOf(garbled), JcaSignatureVerifier)
                }
                .conflict
        )
    }

    @Test
    fun storedRostersVerifyAgain() {
        val decoded = Roster.decode(base.encode(), JcaSignatureVerifier)
        assertEquals(base.headHash, decoded.headHash)
        assertEquals(base.root, decoded.root)
    }

    @Test
    fun codesRoundTripAndForgiveTyping() {
        val bytes = ByteArray(10) { (it * 37 + 5).toByte() }
        val code = Pairing.code(bytes)
        assertEquals(19, code.length)
        assertContentEquals(bytes, Pairing.parse(code))
        assertContentEquals(bytes, Pairing.parse(code.lowercase().replace("-", "  ")))
        assertContentEquals(Codes.decode("0011"), Codes.decode("oOil"))
        assertNull(Pairing.parse("ABCD-EFGH-JKMN"))
        assertNull(Pairing.parse("ABCD-EFGH-JKMN-PQRU"))
        assertEquals("0123-4567", Codes.group("01234567", 4))
    }

    @Test
    fun ed25519KeysAreReadOnlyFromTheirExactEncoding() {
        val key = ByteArray(32) { it.toByte() }
        val spki =
            byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00) +
                key
        assertContentEquals(key, DeviceKeyFormats.ed25519Raw(spki))
        assertNull(DeviceKeyFormats.ed25519Raw(spki + byteArrayOf(0)))
        assertNull(DeviceKeyFormats.ed25519Raw(phone.descriptor.public_key.toByteArray()))
        assertTrue(DeviceKeyFormats.isP256(phone.descriptor.public_key.toByteArray()))
    }

    @Test
    fun theDeviceCertificateCarriesTheDeviceKeyAndItsSignature() {
        val keys = softwareKeys()
        val publicKey = keys.publicKey()
        val id = Rosters.deviceId(publicKey)
        val der = DeviceCertificate.selfSigned(publicKey, id, keys::sign)
        val certificate =
            CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(der.toByteArray())) as X509Certificate
        assertContentEquals(publicKey, certificate.publicKey.encoded)
        assertEquals("CN=$id", certificate.subjectX500Principal.name)
        assertEquals(3, certificate.version)
        assertTrue(certificate.serialNumber.signum() > 0)
        certificate.verify(certificate.publicKey)
        assertEquals("SHA256withECDSA", certificate.sigAlgName)
        assertTrue(
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(certificate.publicKey)
                update(certificate.tbsCertificate)
                verify(certificate.signature)
            }
        )
    }

    @Test
    fun displayNamesAndPlatformsAreMadeValid() {
        assertEquals("Pixel 9", DeviceTrust.deviceName(" Pixel\u0000 9 "))
        assertEquals("Dieter app", DeviceTrust.deviceName("\u0007"))
        val long = DeviceTrust.deviceName("ä".repeat(40))
        assertEquals(64, long.encodeToByteArray().size)
        assertEquals("ios", DeviceTrust.platformLabel("iOS"))
        assertEquals("app", DeviceTrust.platformLabel("—"))
        assertNull(
            Rosters.descriptorProblem(
                DeviceDescriptor(
                    device_id = phone.id,
                    kind = DeviceKind.DEVICE_KIND_CLIENT,
                    platform = DeviceTrust.platformLabel("Android"),
                    name = DeviceTrust.deviceName("😀".repeat(20)),
                    algorithm = DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256,
                    public_key = phone.descriptor.public_key,
                )
            )
        )
    }
}
