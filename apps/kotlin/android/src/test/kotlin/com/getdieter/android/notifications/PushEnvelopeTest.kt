package com.getdieter.android.notifications

import java.io.File
import java.util.Base64
import kotlin.test.*
import org.json.JSONObject
import org.junit.Test

class PushEnvelopeTest {
    @Test
    fun opensDaemonEnvelopeAndRejectsWrongAccountAndTampering() {
        val vector =
            JSONObject(
                File(System.getProperty("dieter.repository"), "tests/fixtures/push-envelope.json")
                    .readText()
            )
        val privateKey = Base64.getDecoder().decode(vector.getString("privateKey"))
        val sealed = Base64.getDecoder().decode(vector.getString("sealed"))
        assertEquals(vector.getString("cardId"), PushEnvelope.open(privateKey, sealed))
        assertNull(PushEnvelope.open(ByteArray(32) { 9 }, sealed))
        val changed =
            sealed.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        assertNull(PushEnvelope.open(privateKey, changed))
        assertNull(PushEnvelope.open(privateKey, sealed.copyOf(59)))
        assertNull(PushEnvelope.open(privateKey, ByteArray(2049)))
    }
}
