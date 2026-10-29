package com.getdieter.core.mail

import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.storage.CoreStorage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class MailBodiesTest {
    private val fileSystem = FakeFileSystem()
    private val storage = CoreStorage(fileSystem, "/state/mail".toPath())

    @Test
    fun bodiesSurviveARestartAndTheLeastRecentlyUsedGoFirst() {
        val bodies = MailBodies(storage, SilentLogger, maxBytes = 10)
        bodies.put("m_1", "ml_a", "d_a", "aaaa")
        bodies.put("m_1", "ml_b", "d_b", "bbbb")
        assertEquals("aaaa", bodies.get("m_1", "ml_a", "d_a"), "reading a body uses it")
        bodies.put("m_2", "ml_c", "d_c", "cccc")
        assertNull(bodies.get("m_1", "ml_b", "d_b"), "the least recently used body went")
        assertEquals(8, bodies.bytes)

        val restarted = MailBodies(storage, SilentLogger, maxBytes = 10)
        assertEquals("aaaa", restarted.get("m_1", "ml_a", "d_a"))
        assertEquals("cccc", restarted.get("m_2", "ml_c", "d_c"))
        assertFalse(restarted.contains("m_1", "ml_b", "d_b"))
        assertEquals(
            setOf("index.pb"),
            storage.names().filterNot { it.endsWith(".md") }.toSet(),
            "nothing but the index and the bodies",
        )
        assertEquals(2, storage.names().count { it.endsWith(".md") })
    }

    @Test
    fun aChangedDigestMissesAndItsNewBodyReplacesTheOld() {
        val bodies = MailBodies(storage, SilentLogger)
        bodies.put("m_1", "ml_a", "d_old", "old")
        assertNull(bodies.get("m_1", "ml_a", "d_new"))
        assertTrue(bodies.contains("m_1", "ml_a", "d_old"))
        bodies.put("m_1", "ml_a", "d_new", "new")
        assertFalse(bodies.contains("m_1", "ml_a", "d_old"))
        assertEquals("new", bodies.get("m_1", "ml_a", "d_new"))
        assertEquals(1, storage.names().count { it.endsWith(".md") })
        assertNull(bodies.get("m_2", "ml_a", "d_new"), "bodies are per machine")
    }

    @Test
    fun aBodyAboveTheLimitIsNotKeptAndClearForgetsEverything() {
        val bodies = MailBodies(storage, SilentLogger, maxBytes = 4)
        bodies.put("m_1", "ml_a", "d_a", "too long")
        assertFalse(bodies.contains("m_1", "ml_a", "d_a"))
        bodies.put("m_1", "ml_b", "d_b", "ok")
        bodies.clear()
        assertFalse(bodies.contains("m_1", "ml_b", "d_b"))
        assertTrue(storage.names().isEmpty())
        assertFalse(MailBodies(storage, SilentLogger).contains("m_1", "ml_b", "d_b"))
    }

    @Test
    fun aBodyFileThatWentMissingIsForgotten() {
        val bodies = MailBodies(storage, SilentLogger)
        bodies.put("m_1", "ml_a", "d_a", "body")
        val file = storage.names().single { it.endsWith(".md") }
        storage.delete(file)
        assertNull(MailBodies(storage, SilentLogger).get("m_1", "ml_a", "d_a"))
        // Files the index does not name are removed on load.
        storage.write("stray.md", "x".encodeToByteArray())
        MailBodies(storage, SilentLogger)
        assertFalse("stray.md" in storage.names())
    }
}
