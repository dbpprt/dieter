package com.dbpprt.dieter.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class GatewayEditsTest {
    @Test fun draftsStartFromTheSavedGateways() {
        assertEquals(GatewayDraft("https://gateway.getdieter.com:443", "Dieter Gateway", "https://gateway.getdieter.com"), GatewayDraft.of(Gateway.DEFAULT))
    }

    @Test fun editsValidateBeforeSaving() {
        val default = GatewayDraft.of(Gateway.DEFAULT)
        assertEquals("Keep at least one connection.", GatewayEdits(emptyList()).problem)
        assertEquals("Enter a gateway address such as https://gateway.example.com.", GatewayEdits(listOf(default, GatewayDraft("new", "New", "https://host/path"))).problem)
        assertEquals("Remote gateways must use HTTPS.", GatewayEdits(listOf(GatewayDraft("new", "New", "http://gateway.example.com"))).problem)
        assertNull(GatewayEdits(listOf(GatewayDraft("dev", "Dev", "http://127.0.0.1:4242"))).problem)
        assertEquals("Connection addresses must be unique.", GatewayEdits(listOf(default, GatewayDraft("copy", "Copy", "HTTPS://gateway.getdieter.com"))).problem)
    }

    @Test fun savingKeepsLabelsAndTheChosenActiveGateway() {
        val edits = GatewayEdits(listOf(GatewayDraft.of(Gateway.DEFAULT), GatewayDraft("custom_1", "  ", "https://gateway.example.com:8443")))
        assertNull(edits.problem)
        assertEquals(listOf("Dieter Gateway", "Custom"), edits.gateways.map { it.name })
        assertEquals("https://gateway.example.com:8443", edits.activeOrigin("custom_1"))
        assertEquals(Gateway.DEFAULT.origin, edits.activeOrigin("removed"))
        assertNull(GatewayEdits(emptyList()).activeOrigin("x"))
    }
}
