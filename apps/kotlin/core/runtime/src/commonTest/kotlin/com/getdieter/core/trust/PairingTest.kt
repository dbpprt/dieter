package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.api.gateway.v1.DeviceKeyAlgorithm
import com.getdieter.api.gateway.v1.DeviceKind
import com.getdieter.core.client.rules.DeviceExports
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.ByteString.Companion.decodeHex

/**
 * Pairing values every platform computes alike; the expected values are the Go reference's golden
 * vectors (tests/fixtures/roster/vectors.json).
 */
class PairingTest {
    private val phone =
        DeviceDescriptor(
            device_id = "dv_yqv7bax4e0d157yahsztz84py8",
            kind = DeviceKind.DEVICE_KIND_CLIENT,
            platform = "ios",
            name = "Dennis’ iPhone",
            algorithm = DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256,
            public_key =
                ("3059301306072a8648ce3d020106082a8648ce3d03010703420004cad3b4907225676285dd6fac57e1" +
                        "97fc1dad5282efe67fbefb13499298aa23b729bbc3605239971f5f4d152369700085ae58fec2de" +
                        "1b590a03f76052d467969b")
                    .decodeHex(),
        )
    private val secret = "105ff3e44e67c8e6f897".decodeHex().toByteArray()

    @Test
    fun deviceIdsCodesAndProofsMatchTheGoReference() {
        assertEquals(phone.device_id, Rosters.deviceId(phone.public_key.toByteArray()))
        assertEquals("21FZ-7S2E-CZ4E-DY4Q", Pairing.code(secret))
        assertContentEquals(secret, Pairing.parse("21fz 7s2e cz4e dy4q"))
        assertEquals(
            "ded318ea08241f9ef605091a11f18dd1af356dca34222e1e5ce6d2961d0da7eb",
            Pairing.proof(secret, phone).hex(),
        )
        val root = "4b53406eb2934587baa953e1474e981703b26c3e234cc6f9ad238bb109d0c0d3".decodeHex()
        val addition =
            "81219bfe8580896aeee463c877c3e21822a1ef032fa8a1234a37fe497ede367d".decodeHex()
        val confirmation =
            "b45070a8fdd47d81923f29174368e6824e0c21e125e105196e5abf87217cb5ee".decodeHex()
        assertTrue(Pairing.verifyConfirmation(secret, root, addition, confirmation))
        assertFalse(Pairing.verifyConfirmation(secret, addition, root, confirmation))
        assertFalse(Pairing.verifyProof(Pairing.newSecret(), phone, Pairing.proof(secret, phone)))
    }

    @Test
    fun theCodeFieldGroupsWhatIsTyped() {
        assertEquals("", DeviceExports.pairingCodeInput(""))
        assertEquals("ABCD-EF", DeviceExports.pairingCodeInput("abc d-ef"))
        assertEquals("0011-21FZ-7S2E-CZ4E", DeviceExports.pairingCodeInput("ooil21FZ7S2ECZ4EDY4Q"))
        assertFalse(DeviceExports.pairingCodeComplete("21FZ-7S2E-CZ4E"))
        assertTrue(DeviceExports.pairingCodeComplete("21fz7s2ecz4edy4q"))
        assertNull(Pairing.parse("21FZ-7S2E-CZ4E-DY4Q-0"))
    }
}
