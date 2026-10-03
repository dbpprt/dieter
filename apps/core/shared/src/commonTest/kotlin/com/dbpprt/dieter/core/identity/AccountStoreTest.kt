package com.dbpprt.dieter.core.identity

import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class AccountStoreTest {
    private val storage = CoreStorage(FakeFileSystem(), "/state".toPath())

    @Test
    fun useAddsActivatesAndRenames() {
        val store = AccountStore(storage)
        val spare = Gateway.parse("http://127.0.0.1:9", "")!!
        store.use(spare)
        assertEquals(listOf(Gateway.DEFAULT.origin, spare.origin), store.state.value.gateways.map { it.origin })
        assertEquals(spare.origin, store.state.value.active.origin)
        assertEquals("Custom", store.state.value.active.name, "an unnamed new gateway")

        store.use(Gateway.parse(Gateway.DEFAULT.origin, "Work")!!)
        assertEquals(Gateway.DEFAULT.origin, store.state.value.active.origin)
        assertEquals(listOf("Work", "Custom"), store.state.value.gateways.map { it.name })
        store.use(Gateway.parse(spare.origin, "")!!)
        assertEquals("Custom", store.state.value.active.name, "a blank name keeps the existing one")
        assertEquals(store.state.value, AccountStore(storage).state.value, "persisted")

        assertFailsWith<CoreException> { store.use(Gateway.parse("http://example.com", "Remote plaintext")!!) }
    }

    @Test
    fun removeKeepsOneAndMovesTheActiveGateway() {
        val store = AccountStore(storage)
        val spare = Gateway.parse("http://127.0.0.1:9", "Spare")!!
        store.use(spare)
        store.remove(spare.origin)
        assertEquals(listOf(Gateway.DEFAULT.origin), store.state.value.gateways.map { it.origin })
        assertEquals(Gateway.DEFAULT.origin, store.state.value.active.origin, "the first remaining gateway becomes active")
        store.remove("https://unknown.example:443")
        assertFailsWith<CoreException> { store.remove(Gateway.DEFAULT.origin) }
    }
}
