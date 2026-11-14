package com.getdieter.core.navigation

import com.getdieter.api.v1.KVDeleteRequest
import com.getdieter.api.v1.KVEntry
import com.getdieter.api.v1.KVFrame
import com.getdieter.api.v1.KVListRequest
import com.getdieter.api.v1.KVMoveRequest
import com.getdieter.api.v1.KVPage
import com.getdieter.api.v1.KVPutRequest
import com.getdieter.api.v1.KVRef
import com.getdieter.api.v1.KVServiceClient
import com.getdieter.api.v1.KVWatchRequest
import com.getdieter.api.v1.PeerVersion
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.storage.CoreStorage
import com.squareup.wire.GrpcCall
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcServerStreamingCall
import com.squareup.wire.GrpcStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/**
 * Delivery of shared navigation edits across several machines. A phone reaches its machines in name
 * order, so the first one it asks can be a machine whose replica has not received the account's
 * records (in the field: a machine whose peer sync was blocked). Edits must still reach the
 * account, without ever rolling back what the client shows.
 */
class SharedKvDeliveryTest {
    private val pin = "inbox-pin.c1.pinned"

    /** One daemon's KV records, as far as its replica has received them. */
    private class Machine(val daemonId: String, private val actor: String) : KVServiceClient {
        val records = LinkedHashMap<String, KVEntry>()
        val reads = mutableListOf<String>()
        val writes = mutableListOf<String>()
        val moves = mutableListOf<KVMoveRequest>()

        /** Every read fails with this status, e.g. a machine too busy to answer. */
        var failReads: GrpcStatus? = null

        override fun GetKV(): GrpcCall<KVRef, KVEntry> = call { ref ->
            reads += ref.key
            failReads?.let { throw GrpcException(it, "scripted") }
            records[ref.key] ?: throw GrpcException(GrpcStatus.NOT_FOUND, "KV key not found")
        }

        override fun PutKV(): GrpcCall<KVPutRequest, KVEntry> = call {
            write(it.ref!!.key, it.expected_revision, it.value_json)
        }

        override fun DeleteKV(): GrpcCall<KVDeleteRequest, KVEntry> = call {
            write(it.ref!!.key, it.expected_revision, ByteString.EMPTY, deleted = true)
        }

        override fun MoveKV(): GrpcCall<KVMoveRequest, KVEntry> = call {
            moves += it
            val rank = (it.after_key.takeIf(String::isNotEmpty)?.let(::rank) ?: "") + "m"
            write(
                it.ref!!.key,
                it.expected_revision,
                SharedKv.encodePosition(KvPosition(it.parent, rank)),
            )
        }

        override fun ListKV(): GrpcCall<KVListRequest, KVPage> = error("unused")

        override fun WatchKV(): GrpcServerStreamingCall<KVWatchRequest, KVFrame> = error("unused")

        private fun rank(key: String) =
            records[key]?.let { SharedKv.decodePosition(it.value_json)?.rank }

        private fun write(
            key: String,
            revision: String,
            value: ByteString,
            deleted: Boolean = false,
        ): KVEntry {
            val old = records[key]
            if (old?.revision.orEmpty() != revision)
                throw GrpcException(GrpcStatus.ABORTED, "revision changed")
            val clock = HashMap<String, Long>()
            for (version in old?.versions.orEmpty()) for ((id, count) in version.clock) clock[id] =
                maxOf(clock[id] ?: 0L, count)
            clock[actor] = (clock[actor] ?: 0L) + 1
            writes += key
            return entry(key, value, clock, deleted).also { records[key] = it }
        }

        /** A unary call answered at once; a thrown [GrpcException] reaches the caller as is. */
        private fun <S : Any, R : Any> call(answer: (S) -> R): GrpcCall<S, R> =
            object : GrpcCall<S, R> by GrpcCall(answer) {
                override suspend fun execute(request: S): R = answer(request)
            }
    }

    private class Fleet(vararg machines: Machine) : KvMachines {
        val byId = machines.associateBy { it.daemonId }

        override suspend fun <T> call(
            machineId: String,
            block: suspend (KVServiceClient) -> T,
        ): T = block(byId.getValue(machineId))
    }

    private fun TestScope.delivering(
        fleet: Fleet,
        view: Map<String, KVEntry>,
        order: List<String> = fleet.byId.keys.toList(),
    ): SharedKv {
        val kv =
            SharedKv(
                "navigation",
                fleet,
                acceptor = { id -> fleet.byId[id]?.let { KvAcceptor("account", it.daemonId) } },
                SilentLogger,
            )
        kv.bind(CoreStorage(FakeFileSystem(), "/state".toPath()))
        kv.apply(view)
        backgroundScope.launch { kv.run(MutableStateFlow(order), MutableStateFlow(true)) }
        return kv
    }

    private fun TestScope.settle() {
        advanceTimeBy(30.seconds)
        runCurrent()
    }

    /**
     * The phone's first machine never received the pin; the next one, which did, takes the unpin.
     */
    @Test
    fun anEditSkipsAMachineThatHasNotSeenWhatTheClientShows() = runTest {
        val lagging = Machine("d_mbp_office", "actor_lagging")
        val current = Machine("d_mini_home", "actor_current")
        val shown = entry(pin, "true".encodeUtf8(), mapOf("actor_current" to 1L))
        current.records[pin] = shown
        val kv = delivering(Fleet(lagging, current), mapOf(pin to shown))

        NavigationEditor(kv).pinInboxCard("c1", false)
        NavigationEditor(kv).pinInboxCard("c2", true)
        settle()

        assertEquals(0, kv.status.value.pending, "status: ${kv.status.value}")
        assertNull(kv.status.value.deliveryError)
        assertEquals("false", current.records.getValue(pin).value_json.utf8())
        assertTrue(pin !in lagging.writes, "a machine behind the client never takes the edit")
        // A key no machine shows yet goes to the preferred machine; the queue did not stall.
        assertEquals(listOf("inbox-pin.c2.pinned"), lagging.writes)
        assertEquals(setOf("c2"), NavigationLayout(kv.values.value).inboxPins())
    }

    @Test
    fun anUnsentEditMovesOnFromABusyMachine() = runTest {
        val busy =
            Machine("d_mbp_office", "actor_busy").apply {
                failReads = GrpcStatus.RESOURCE_EXHAUSTED
            }
        val other = Machine("d_mini_home", "actor_other")
        val kv = delivering(Fleet(busy, other), emptyMap())

        NavigationEditor(kv).pinInboxCard("c1", true)
        settle()

        assertEquals(0, kv.status.value.pending, "status: ${kv.status.value}")
        assertEquals("true", other.records.getValue(pin).value_json.utf8())
        assertTrue(busy.writes.isEmpty())
    }

    /** Never a rollback: with every machine behind, the edit waits for one that catches up. */
    @Test
    fun anEditWaitsUntilSomeMachineHasSeenWhatTheClientShows() = runTest {
        val first = Machine("d_mbp_office", "actor_first")
        val second = Machine("d_mini_home", "actor_second")
        val shown = entry(pin, "true".encodeUtf8(), mapOf("actor_third" to 1L))
        val kv = delivering(Fleet(first, second), mapOf(pin to shown))

        NavigationEditor(kv).pinInboxCard("c1", false)
        settle()
        assertEquals(1, kv.status.value.pending)
        assertNotNull(kv.status.value.deliveryError)
        assertTrue(first.writes.isEmpty() && second.writes.isEmpty())

        second.records[pin] = shown
        settle()
        assertEquals(0, kv.status.value.pending, "status: ${kv.status.value}")
        assertEquals(listOf(pin), second.writes)
        assertEquals(
            mapOf("actor_third" to 1L, "actor_second" to 1L),
            second.records.getValue(pin).versions.single().clock,
        )
        assertTrue(first.writes.isEmpty())
    }

    /**
     * A move anchors on its neighbour as the client shows it, so it goes where that neighbour is.
     */
    @Test
    fun aMoveGoesToAMachineThatHasSeenItsNeighbour() = runTest {
        val lagging = Machine("d_mbp_office", "actor_lagging")
        val current = Machine("d_mini_home", "actor_current")
        val neighbour = "chats-item.a.position"
        val placed =
            entry(
                neighbour,
                SharedKv.encodePosition(KvPosition("folder", "h")),
                mapOf("actor_current" to 1L),
            )
        current.records[neighbour] = placed
        val kv = delivering(Fleet(lagging, current), mapOf(neighbour to placed))

        kv.move("chats-item.b.position", "folder", after = neighbour)
        settle()

        assertEquals(0, kv.status.value.pending, "status: ${kv.status.value}")
        assertTrue(lagging.writes.isEmpty())
        assertEquals(neighbour, current.moves.single().after_key)
    }

    private companion object {
        fun entry(
            key: String,
            value: ByteString,
            clock: Map<String, Long>,
            deleted: Boolean = false,
        ) =
            KVEntry(
                namespace = "navigation",
                key = key,
                revision =
                    clock.entries.sortedBy { it.key }.joinToString { "${it.key}=${it.value}" },
                value_json = value,
                deleted = deleted,
                versions =
                    listOf(PeerVersion(clock = clock, value_json = value, deleted = deleted)),
            )
    }
}
