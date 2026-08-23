package com.dbpprt.dieter.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class DieterEndpointTest {
    @Test
    fun parsesPlaintextHostAndOptionalPort() {
        val explicit = dieterEndpointFromAddress("one", "Local", "http://127.0.0.1:5151")
        val defaultPort = dieterEndpointFromAddress("two", "Tailnet", "dieter.tailnet.test")

        assertEquals("127.0.0.1", explicit.host)
        assertEquals(5151, explicit.port)
        assertEquals(DIETER_LOCAL_PORT, defaultPort.port)
        assertEquals(false, explicit.secure)
        assertEquals("http://127.0.0.1:5151", explicit.address)
    }

    @Test
    fun parsesHttpsWithSecureDefaultPort() {
        val endpoint = dieterEndpointFromAddress("public", "Dieter", "https://dieter.example")

        assertEquals("dieter.example", endpoint.host)
        assertEquals(443, endpoint.port)
        assertEquals(true, endpoint.secure)
        assertEquals("https://dieter.example:443", endpoint.address)
    }

    @Test
    fun parsesBracketedIpv6() {
        val endpoint = dieterEndpointFromAddress("six", "IPv6", "[fd7a:115c:a1e0::1]:4242")

        assertEquals("fd7a:115c:a1e0::1", endpoint.host)
        assertEquals(4242, endpoint.port)
    }

    @Test
    fun rejectsPathsAndInvalidPorts() {
        assertThrows(IllegalArgumentException::class.java) {
            dieterEndpointFromAddress("path", "Path", "dieter.example:4242/api")
        }
        assertThrows(IllegalArgumentException::class.java) {
            dieterEndpointFromAddress("port", "Port", "dieter.example:70000")
        }
    }
}
