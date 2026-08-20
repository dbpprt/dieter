package com.dbpprt.nauclio.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NauclioEndpointTest {
    @Test
    fun parsesPlaintextHostAndOptionalPort() {
        val explicit = nauclioEndpointFromAddress("one", "Local", "http://127.0.0.1:5151")
        val defaultPort = nauclioEndpointFromAddress("two", "Tailnet", "nauclio.tailnet.test")

        assertEquals("127.0.0.1", explicit.host)
        assertEquals(5151, explicit.port)
        assertEquals(NAUCLIO_LOCAL_PORT, defaultPort.port)
        assertEquals(false, explicit.secure)
        assertEquals("http://127.0.0.1:5151", explicit.address)
    }

    @Test
    fun parsesHttpsWithSecureDefaultPort() {
        val endpoint = nauclioEndpointFromAddress("public", "Nauclio", "https://nauclio.example")

        assertEquals("nauclio.example", endpoint.host)
        assertEquals(443, endpoint.port)
        assertEquals(true, endpoint.secure)
        assertEquals("https://nauclio.example:443", endpoint.address)
    }

    @Test
    fun parsesBracketedIpv6() {
        val endpoint = nauclioEndpointFromAddress("six", "IPv6", "[fd7a:115c:a1e0::1]:4242")

        assertEquals("fd7a:115c:a1e0::1", endpoint.host)
        assertEquals(4242, endpoint.port)
    }

    @Test
    fun rejectsPathsAndInvalidPorts() {
        assertThrows(IllegalArgumentException::class.java) {
            nauclioEndpointFromAddress("path", "Path", "nauclio.example:4242/api")
        }
        assertThrows(IllegalArgumentException::class.java) {
            nauclioEndpointFromAddress("port", "Port", "nauclio.example:70000")
        }
    }
}
