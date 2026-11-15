package com.getdieter.core.notifications

import kotlin.test.*
import okio.ByteString.Companion.toByteString

class PushDeliveryTest {
    private val sealed = ByteArray(80) { 7 }.toByteString()

    private fun delivery() = PushDelivery { account, bytes ->
        if (account == "owner" && bytes == sealed) "card" else null
    }

    @Test
    fun localTapWaitsForTheOriginalAccountToo() {
        val push = delivery()
        push.bind("other")
        assertNull(push.tapLocal("owner", "card"))
        push.reset()
        assertEquals("card", push.bind("owner"))
        assertNull(push.bind("owner"))
        assertNull(push.tapLocal("", "card"))
    }

    @Test
    fun coldTapWaitsForItsTrustedAccountAndIsConsumedOnce() {
        val push = delivery()
        assertNull(push.tap(sealed))
        assertNull(push.bind("other"))
        assertEquals("card", push.bind("owner"))
        assertNull(push.bind("owner"))
        push.reset()
        assertNull(push.cardId(sealed))
    }

    @Test
    fun visibilityDuplicatesAndAccountChangesShareOnePolicy() {
        val push = delivery()
        push.bind("owner")
        push.registered(true)
        push.visible("card")
        assertFalse(push.present(sealed))
        push.visible(null)
        assertFalse(push.present(sealed), "repeated delivery must not alert after leaving the card")
        push.bind("other")
        assertFalse(push.available)
        assertFalse(push.present(sealed))
        push.bind("owner")
        assertTrue(push.present(sealed))
        assertFalse(push.present(sealed))
    }

    @Test
    fun rejectsMalformedAndOversizedPayloadsBeforeCrypto() {
        var calls = 0
        val push = PushDelivery { _, _ ->
            calls++
            "card"
        }
        push.bind("owner")
        assertNull(push.tap(ByteArray(59).toByteString()))
        assertNull(push.tap(ByteArray(2049).toByteString()))
        assertEquals(0, calls)
    }
}
