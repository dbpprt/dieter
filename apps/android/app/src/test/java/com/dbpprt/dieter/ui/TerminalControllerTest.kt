package com.dbpprt.dieter.ui

import com.dbpprt.dieter.data.TerminalClient
import com.dbpprt.dieter.v1.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Assert.*
import org.junit.Test

class TerminalControllerTest {
    private class Client(val load: suspend () -> TerminalsResponse) : TerminalClient {
        var resizeCall: suspend () -> Terminal = { error("unused") }
        override suspend fun terminals() = load()
        override suspend fun create(request: CreateTerminalRequest): Terminal = error("unused")
        override fun watch(id: String, afterSequence: Long): Flow<TerminalFrame> = emptyFlow()
        override suspend fun write(id: String, data: ByteArray) = Unit
        override suspend fun resize(id: String, columns: Int, rows: Int): Terminal = resizeCall()
        override suspend fun rename(id: String, name: String): Terminal = error("unused")
        override suspend fun close(id: String) = Unit
    }
    private fun response(id: String) = TerminalsResponse.newBuilder().addTerminals(Terminal.newBuilder().setId(id)).build()

    @Test fun lateReadCannotReplaceNewMachineState() = runBlocking {
        val release = CompletableDeferred<Unit>()
        var client: TerminalClient = Client { withContext(NonCancellable) { release.await() }; response("old") }
        val errors = mutableListOf<String>()
        val owner = TerminalController(this, { client }, { false }, {}, errors::add)
        owner.bind("old")
        owner.load()
        yield()
        owner.bind("new")
        client = Client { response("new") }
        owner.load()
        yield()
        release.complete(Unit)
        yield()
        assertEquals(listOf("new"), owner.state.terminals.map { it.id })
        assertFalse(owner.state.terminalLoading)
        assertTrue(errors.isEmpty())
    }

    @Test fun canceledFailureCannotPublishAnErrorOrClearNewLoadingState() = runBlocking {
        val release = CompletableDeferred<Unit>()
        var client: TerminalClient = Client { withContext(NonCancellable) { release.await() }; error("obsolete") }
        val errors = mutableListOf<String>()
        val owner = TerminalController(this, { client }, { false }, {}, errors::add)
        owner.bind("route")
        owner.load()
        yield()
        client = Client { response("current") }
        owner.load()
        yield()
        release.complete(Unit)
        yield()
        assertEquals("current", owner.state.selectedTerminalId)
        assertTrue(errors.isEmpty())
    }

    @Test fun supersededResizeCannotReportLateErrorOnSameRoute() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val client = Client { response("terminal") }
        client.resizeCall = {
            withContext(NonCancellable) {
                entered.complete(Unit)
                release.await()
                error("obsolete resize")
            }
        }
        val errors = mutableListOf<String>()
        val owner = TerminalController(this, { client }, { false }, {}, errors::add)
        owner.bind("route")
        owner.resize("terminal", 80, 24)
        withTimeout(3000) { entered.await() }
        client.resizeCall = { Terminal.newBuilder().setId("terminal").build() }
        owner.resize("terminal", 100, 30)
        release.complete(Unit)
        yield()
        assertTrue(errors.isEmpty())
        owner.cancel()
    }
}
