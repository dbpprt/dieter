package com.dbpprt.dieter.core.composition

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CapturePagesTest {
    @Test
    fun onlyWebPagesAreRecorded() {
        assertEquals("https://example.com/path?q=task#issue", CapturePages.page(" https://example.com/path?q=task#issue "))
        assertEquals("http://localhost:3000/issue", CapturePages.page("http://localhost:3000/issue"))
        for (value in listOf("", "Search or enter address", "file:///private/data", "javascript:alert(1)", "chrome://settings", "https://", "not a URL")) {
            assertNull(CapturePages.page(value), value)
        }
    }

    @Test
    fun savedAddressesKeepExplicitPortsAndCanonicalHosts() {
        assertEquals("127.0.0.1:4018", CapturePages.hostname("http://127.0.0.1:4018/commitments/3"))
        assertEquals("localhost:4018", CapturePages.hostname("http://LOCALHOST.:04018/path?q=value"))
        assertEquals("staging.example.com", CapturePages.hostname("https://staging.example.com/commitments/3/data"))
        assertEquals("example.com:443", CapturePages.hostname("https://example.com:443/path"))
        assertEquals("[::1]:4018", CapturePages.hostname("http://[::1]:4018/path"))
        assertEquals("::1", CapturePages.hostname("http://[::1]/path"))
        assertEquals("[::1]:4018", CapturePages.hostname("http://[0:0:0:0:0:0:0:1]:4018/path"))
        assertEquals("127.0.0.1:4018", CapturePages.hostname("http://[::ffff:127.0.0.1]:4018/path"))
        assertEquals("[::c000:201]:4018", CapturePages.hostname("http://[::192.0.2.1]:4018/path"))
        assertNull(CapturePages.hostname("http://127.0.0.1:65536/path"))
        assertNull(CapturePages.hostname("http://127.0.0.1:0/path"))
    }

    @Test
    fun aPortSpecificHostnameWinsOverAHostWideOne() {
        val main = listOf("127.0.0.1")
        val vms = listOf("127.0.0.1:4018")
        val other = listOf("127.0.0.1:4019")
        assertEquals(listOf(2), CapturePages.matches("http://127.0.0.1:4018/commitments/3", listOf(main, other, vms)))
        assertEquals(listOf(1), CapturePages.matches("http://127.0.0.1:4019/different/path", listOf(main, other, vms)))
        assertEquals(listOf(0), CapturePages.matches("http://127.0.0.1:4020/path", listOf(main, other, vms)))
        assertEquals(emptyList(), CapturePages.matches("http://127.0.0.1:4018/x", listOf(other)))
        assertEquals(listOf(0, 2), CapturePages.matches("http://127.0.0.1:4018/x", listOf(vms, other, vms)), "equal specificity stays ambiguous")
    }

    @Test
    fun hostsMatchExactlyWithDefaultPortsAndBracketedIPv6() {
        assertEquals(listOf(0), CapturePages.matches("https://APP.example.com.:8443/path", listOf(listOf("app.example.com", "localhost"))))
        assertEquals(emptyList(), CapturePages.matches("https://app.example.com.evil.test", listOf(listOf("app.example.com"))))
        assertEquals(emptyList(), CapturePages.matches("file:///app.example.com", listOf(listOf("app.example.com"))))
        val http = listOf("example.com:80")
        val https = listOf("example.com:443")
        assertEquals(listOf(1), CapturePages.matches("http://example.com/path", listOf(https, http)))
        assertEquals(listOf(0), CapturePages.matches("https://example.com/path", listOf(https, http)))
        assertEquals(listOf(0), CapturePages.matches("http://[0:0:0:0:0:0:0:1]:4018/path", listOf(listOf("[::1]:4018"))))
        assertEquals(emptyList(), CapturePages.matches("http://[::1]:4019/path", listOf(listOf("[::1]:4018"))))
        assertEquals(listOf(0), CapturePages.matches("http://[::ffff:7f00:1]:4018/path", listOf(listOf("127.0.0.1:4018"))))
    }
}
