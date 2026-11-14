package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.api.gateway.v1.DeviceKeyAlgorithm
import com.getdieter.api.gateway.v1.DeviceKind
import com.getdieter.api.gateway.v1.DeviceRosterEntry
import com.getdieter.api.gateway.v1.DeviceRosterOperation
import com.getdieter.core.testing.JcaSignatureVerifier
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import okio.ByteString.Companion.decodeHex
import okio.ByteString.Companion.toByteString

/**
 * The Go reference's golden vectors (tests/fixtures/roster/vectors.json, written by
 * internal/security/roster): canonical bytes, hashes, device IDs, descriptor bytes, signatures and
 * pairing values must match byte for byte.
 */
class RosterVectorsTest {
    private val fixture: JsonObject =
        Json.parseToJsonElement(
                File(
                        checkNotNull(System.getProperty("dieter.repository")) {
                            "run through ./gradlew jvmTest"
                        },
                        "tests/fixtures/roster/vectors.json",
                    )
                    .readText()
            )
            .jsonObject

    private fun JsonObject.text(name: String) = getValue(name).jsonPrimitive.content

    private fun entry(vector: JsonObject) =
        DeviceRosterEntry(
            account = vector.text("account"),
            sequence = vector.getValue("sequence").jsonPrimitive.long,
            previous = vector.text("previous").decodeHex(),
            operation =
                DeviceRosterOperation.fromValue(vector.getValue("operation").jsonPrimitive.int)!!,
            device =
                DeviceDescriptor(
                    device_id = vector.text("deviceId"),
                    kind = DeviceKind.fromValue(vector.getValue("kind").jsonPrimitive.int)!!,
                    platform = vector.text("platform"),
                    name = vector.text("name"),
                    algorithm =
                        DeviceKeyAlgorithm.fromValue(
                            vector.getValue("algorithm").jsonPrimitive.int
                        )!!,
                    public_key = vector.text("publicKey").decodeHex(),
                    daemon_id = vector.text("daemonId"),
                ),
            signer = vector.text("signer"),
            created_at = vector.text("createdAt"),
            signature = vector.text("signature").decodeHex(),
        )

    private val vectors = fixture.getValue("entries").jsonArray.map { it.jsonObject }
    private val entries = vectors.map(::entry)

    @Test
    fun canonicalBytesAndHashesMatchTheGoReference() {
        for ((vector, entry) in vectors.zip(entries)) {
            assertEquals(
                vector.text("canonical"),
                Rosters.canonical(entry).toByteString().hex(),
                "canonical bytes of entry ${entry.sequence}",
            )
            assertEquals(
                vector.text("hash"),
                Rosters.hash(entry).hex(),
                "hash of ${entry.sequence}",
            )
        }
    }

    @Test
    fun theWholeChainVerifiesWithItsSignatures() {
        val roster = Roster.verify(entries, JcaSignatureVerifier)
        assertEquals(fixture.text("rootHash"), roster.root.hex())
        assertEquals(fixture.text("headHash"), roster.headHash.hex())
        assertEquals(fixture.text("account"), roster.account)
        assertEquals(5, roster.length)
        // The app (ECDSA) added the second machine; the recovery key revoked it.
        val second = assertNotNull(roster.member("dv_9z3gn9ch5z2wmtck3rjb7h5yqg"))
        assertTrue(second.revoked)
        assertEquals("dv_yqv7bax4e0d157yahsztz84py8", second.addedBy)
        assertEquals(null, roster.daemon("d_vectorsecond"))
        assertEquals(
            "dv_xmvgns9pdhvr9pj914ppzhram4",
            roster.daemon("d_vectormachine")?.deviceId,
        )
    }

    @Test
    fun deviceIdsAndDescriptorBytesMatchTheGoReference() {
        val roster = Roster.verify(entries, JcaSignatureVerifier)
        for (device in fixture.getValue("devices").jsonArray.map { it.jsonObject }) {
            val id = device.text("deviceId")
            assertEquals(id, Rosters.deviceId(device.text("publicKey").decodeHex().toByteArray()))
            assertEquals(
                device.text("descriptor"),
                Rosters.descriptorBytes(roster.member(id)!!.descriptor).toByteString().hex(),
            )
        }
    }

    @Test
    fun pairingCodeProofAndConfirmationMatchTheGoReference() {
        val roster = Roster.verify(entries, JcaSignatureVerifier)
        val pairing = fixture.getValue("pairing").jsonObject
        val secret = pairing.text("secret").decodeHex().toByteArray()
        val code = pairing.text("code")
        assertEquals(code, Pairing.code(secret))
        assertEquals(secret.toByteString(), Pairing.parse(code)?.toByteString())
        assertEquals(
            secret.toByteString(),
            Pairing.parse(code.lowercase().replace("-", " ").replace('1', 'l'))?.toByteString(),
        )
        val device = roster.member(pairing.text("deviceId"))!!.descriptor
        val proof = pairing.text("proof").decodeHex()
        assertEquals(proof, Pairing.proof(secret, device))
        assertTrue(Pairing.verifyProof(secret, device, proof))
        val addition = pairing.text("addHash").decodeHex()
        assertEquals(addition, Rosters.hash(roster.addition(device.device_id)!!))
        val confirmation = pairing.text("confirmation").decodeHex()
        assertEquals(confirmation, Pairing.confirmation(secret, roster.root, addition))
        assertTrue(Pairing.verifyConfirmation(secret, roster.root, addition, confirmation))
    }
}
