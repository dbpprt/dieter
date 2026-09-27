package com.dbpprt.dieter.ui

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import org.junit.Assert.*
import org.junit.Test

class TerminalInputControllerTest {
    @Test fun stalledWriteCountsAgainstBudgetAndAdmissionIsAtomic() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val writes = mutableListOf<String>()
        val input = TerminalInputController(this, { throw AssertionError(it) }, byteLimit = 8, pause = {})
        val caller = "123456".encodeToByteArray()
        assertTrue(input.send("a", caller) { writes.add(it.decodeToString()); release.await() })
        caller.fill(0)
        yield()
        assertFalse(input.send("a", "xyz".encodeToByteArray()) { fail("Must retain original writer") })
        assertTrue(input.send("a", "78".encodeToByteArray()) { fail("Must retain original writer") })
        release.complete(Unit)
        yield()
        assertEquals(listOf("123456", "78"), writes)
    }

    @Test fun canceledWriterCannotRemoveSuccessorOrReplayAmbiguousBytes() = runBlocking {
        val oldRelease = CompletableDeferred<Unit>()
        val newRelease = CompletableDeferred<Unit>()
        val oldWrites = mutableListOf<String>()
        val newWrites = mutableListOf<String>()
        val errors = mutableListOf<Throwable>()
        val input = TerminalInputController(this, errors::add, byteLimit = 8, pause = {})
        input.send("a", "old".encodeToByteArray()) {
            oldWrites.add(it.decodeToString())
            withContext(NonCancellable) { oldRelease.await() }
            error("delivered, response lost")
        }
        yield()
        input.cancelAll()
        assertFalse(input.send("a", ByteArray(6)) {}) // old in-flight bytes are still retained
        assertTrue(input.send("a", "new".encodeToByteArray()) {
            newWrites.add(it.decodeToString()); newRelease.await()
        })
        yield()
        oldRelease.complete(Unit)
        yield()
        assertTrue(input.send("a", "!".encodeToByteArray()) { fail("old completion removed the successor") })
        newRelease.complete(Unit)
        yield()
        assertEquals(listOf("old"), oldWrites)
        assertEquals(listOf("new", "!"), newWrites)
        assertTrue(errors.isEmpty())
    }

    @Test fun ambiguousFailureDiscardsRemainingInputWithoutRetry() = runBlocking {
        val errors = mutableListOf<Throwable>()
        val writes = mutableListOf<Int>()
        val input = TerminalInputController(this, errors::add, pause = {})
        input.send("a", ByteArray(TERMINAL_INPUT_CHUNK_LIMIT + 1)) { writes.add(it.size); error("response lost") }
        yield()
        assertEquals(listOf(TERMINAL_INPUT_CHUNK_LIMIT), writes)
        assertEquals(1, errors.size)
        assertTrue(input.send("b", ByteArray(256 * 1024)) {})
    }

    @Test fun simultaneousSessionBudgetIsBounded() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val input = TerminalInputController(this, { throw AssertionError(it) }, sessionLimit = 1, pause = {})
        assertTrue(input.send("a", byteArrayOf(1)) { release.await() })
        yield()
        assertFalse(input.send("b", byteArrayOf(1)) {})
        release.complete(Unit)
        yield()
        assertTrue(input.send("b", byteArrayOf(1)) {})
    }
}
