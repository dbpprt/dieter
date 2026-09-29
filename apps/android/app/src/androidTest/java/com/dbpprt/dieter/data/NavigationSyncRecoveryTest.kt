package com.dbpprt.dieter.data

import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.settings.SharedKV
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.connection.peerSyncWarnings
import com.dbpprt.dieter.gateway.v1.*
import com.dbpprt.dieter.v1.*
import io.grpc.Status
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.time.Instant

/** Real durable Android preferences and coroutine subscriptions; only the
 * transport is controlled so failures and recovery are deterministic. */
class NavigationSyncRecoveryTest {
    private class Transport {
        val frames = Channel<Result<KVFrame>>(16)
        val failWrites = AtomicBoolean(false)
        val account = AtomicReference("fixture")
        val writes = CopyOnWriteArrayList<KVPutRequest>()
        val repository = Proxy.newProxyInstance(DieterRepository::class.java.classLoader,
            arrayOf(DieterRepository::class.java)) { _, method, args ->
            when (method.name) {
                "listKV" -> KVPage.newBuilder().setAccount(account.get()).setDaemonId("desktop").build()
                "watchKV" -> frames.receiveAsFlow().map { it.getOrThrow() }
                "getKV" -> throw Status.NOT_FOUND.asRuntimeException()
                "putKV" -> {
                    val request = args!![0] as KVPutRequest
                    writes.add(request)
                    if (failWrites.get()) throw Status.FAILED_PRECONDITION.asRuntimeException()
                    KVEntry.newBuilder().setKey(request.ref.key).setValueJson(request.valueJson).build()
                }
                else -> error("Unexpected navigation call: ${method.name}")
            }
        } as DieterRepository

        suspend fun caughtUp() = frames.send(Result.success(KVFrame.newBuilder().setAccount(account.get()).setCaughtUp(true).build()))
    }

    private fun fixture(test: suspend (SharedKV, Transport) -> Unit) = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.packageName.endsWith(".e2e"))
        val name = "navigation-recovery-${UUID.randomUUID()}"
        val preferences = context.getSharedPreferences(name, 0)
        preferences.edit().putString("activeAccount", "fixture").putString("activeDaemon", "desktop").commit()
        val store = SharedKV(preferences)
        val transport = Transport()
        try {
            store.awaitPendingWrites()
            store.bind(transport.repository)
            withTimeout(15_000) { test(store, transport) }
        } finally {
            store.close()
            transport.frames.close()
            context.deleteSharedPreferences(name)
        }
    }

    @Test fun readFailureSurvivesLocalEditsAndClearsOnCaughtUp() = fixture { store, transport ->
        transport.frames.send(Result.failure(Status.PERMISSION_DENIED.asRuntimeException()))
        store.status.first { it.error?.contains("denied") == true }
        store.put("project-folder.one.name", "Work")
        store.awaitPendingWrites()
        store.status.first { it.pending == 0 }
        assertEquals("\"Work\"", store.values.value["project-folder.one.name"])
        assertTrue(store.status.value.error!!.contains("denied"))
        transport.caughtUp()
        store.status.first { it.error == null }
    }

    @Test fun successfulWatchDoesNotHideFailedEditAndRetryKeepsOperationIdentity() = fixture { store, transport ->
        transport.failWrites.set(true)
        transport.caughtUp()
        store.put("project-folder.one.name", "Work")
        store.status.first { it.pending == 1 && it.error?.contains("cannot sync") == true }
        val original = transport.writes.first()
        transport.caughtUp()
        // A value change proves the successful frame has been applied before
        // asserting that its read success did not erase the write failure.
        transport.frames.send(Result.success(KVFrame.newBuilder().setAccount("fixture").setCaughtUp(true)
            .addEntries(KVEntry.newBuilder().setKey("observed").setValueJson(com.google.protobuf.ByteString.copyFromUtf8("true"))).build()))
        store.values.first { it["observed"] == "true" }
        assertTrue(store.status.value.error!!.contains("cannot sync"))
        assertEquals(1, store.status.value.pending)
        transport.failWrites.set(false)
        store.status.first { it.pending == 0 && it.error == null }
        assertTrue(transport.writes.size >= 2)
        assertTrue(transport.writes.all { it == original })
    }

    @Test fun routePauseClearsReadErrorAndPreservesOfflineEditsForRebind() = fixture { store, transport ->
        transport.frames.send(Result.failure(Status.UNAUTHENTICATED.asRuntimeException()))
        store.status.first { it.error?.contains("Sign in") == true }
        store.bind(null)
        store.awaitPendingWrites()
        assertNull(store.status.value.error)
        store.put("project-folder.one.name", "Work")
        store.awaitPendingWrites()
        assertEquals(1, store.status.value.pending)
        assertTrue(transport.writes.isEmpty())
        store.bind(transport.repository)
        transport.caughtUp()
        store.status.first { it.pending == 0 && it.error == null }
        assertEquals("\"Work\"", store.values.value["project-folder.one.name"])
    }

    @Test fun accountSwitchDoesNotCarryFailedEditsOrTheirWarningIntoAnotherAccount() = fixture { store, transport ->
        transport.failWrites.set(true)
        transport.caughtUp()
        store.put("project-folder.one.name", "Private folder")
        store.status.first { it.pending == 1 && it.error != null }
        transport.account.set("other-account")
        store.bind(transport.repository)
        store.status.first { it.pending == 0 && it.error == null }
        assertFalse(store.values.value.containsKey("project-folder.one.name"))
        transport.caughtUp()
    }

    @Test fun selectedMachineDiagnosticsFollowPresenceAndUnchangedStateRecovery() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.packageName.endsWith(".e2e"))
        val preferences = context.getSharedPreferences("dieter_connection", 0)
        preferences.edit().clear().putBoolean("desired_connected", false).putString("background_sync_mode", "app_only").commit()
        val origin = DieterEndpoint("sync-fixture", "Fixture", "127.0.0.1", 14243, secure = false)
        val peerOnline = MutableStateFlow(false)
        val failed = AtomicBoolean(true)
        val requests = CopyOnWriteArrayList<GetStateRequest>()
        val endpoints = MutableStateFlow(listOf(origin))
        val active = MutableStateFlow(origin)
        fun daemons() = listOf(
            Daemon.newBuilder().setId("desktop").setName("Desktop").setOnline(true)
                .setCompatibility(CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE).build(),
            Daemon.newBuilder().setId("laptop").setName("Laptop").setOnline(peerOnline.value)
                .setCompatibility(CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE).build(),
        )
        val cursor = SyncCursor.newBuilder().setEpoch("fixture").setSequence(1).setProjectionVersion(5).build()
        val issue = PeerSyncDiagnostic.newBuilder().setPeerId("laptop").setFailureCode("DeadlineExceeded")
            .setLastAttemptAt(Instant.now().toString()).build()
        val repository = Proxy.newProxyInstance(DieterRepository::class.java.classLoader,
            arrayOf(DieterRepository::class.java)) { _, method, args ->
            when (method.name) {
                "getEndpoints" -> endpoints.value
                "getActiveEndpoint" -> active.value
                "replaceEndpoints" -> { @Suppress("UNCHECKED_CAST") val next = args!![0] as List<DieterEndpoint>; endpoints.value = next; Unit }
                "selectEndpoint" -> { active.value = args!![0] as DieterEndpoint; Unit }
                "compatibility" -> CompatibilityResponse.newBuilder().setStatus(CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE).build()
                "daemons" -> ListDaemonsResponse.newBuilder().addAllDaemons(daemons()).build()
                "prepareDaemon", "dataRoute" -> "fixture"
                "health" -> HealthResponse.newBuilder().setStatus("ok").build()
                "runtimeStatus" -> RuntimeStatus.newBuilder().setReady(true).build()
                "harnesses" -> HarnessCatalog.getDefaultInstance()
                "directRefreshAtMillis" -> null
                "watchSync" -> flow {
                    emit(SyncFrame.newBuilder().setCursor(cursor).setSnapshot(GlobalSnapshot.getDefaultInstance()).build())
                    awaitCancellation()
                }
                "watchDaemons" -> peerOnline.map { DaemonPresenceUpdate.newBuilder().addAllDaemons(daemons()).build() }
                "state" -> {
                    val request = args!![0] as GetStateRequest
                    requests.add(request)
                    State.newBuilder().setCursor(cursor).setNotModified(request.hasIfNotModified())
                        .also { if (failed.get()) it.addPeerSyncIssues(issue) }.build()
                }
                "relayState" -> State.newBuilder().setCursor(cursor).build()
                "reconnect", "close" -> Unit
                else -> error("Unexpected directory call: ${method.name}")
            }
        } as DieterRepository
        val manager = DieterConnectionManager(context, repository)
        try {
            withTimeout(10_000) {
                manager.state.first { !it.desiredConnected }
                manager.updateEndpoints(listOf(origin), origin.id)
                manager.onAppForegrounded()
                manager.connect()
                val initial = manager.state.first { it.phase == ConnectionPhase.CONNECTED && it.peerSyncIssues.isNotEmpty() }
                assertEquals("desktop", initial.endpoint?.daemonId)
                assertTrue(peerSyncWarnings(initial).isEmpty())
                peerOnline.value = true
                manager.state.first { peerSyncWarnings(it).singleOrNull()?.contains("Desktop and Laptop") == true }
                // Same epoch/sequence, no workspace mutation. The selected
                // machine must still refresh and clear its own diagnostics.
                failed.set(false)
                manager.refreshMachineDirectory()
                manager.state.first { it.peerSyncIssues.isEmpty() }
                assertTrue(requests.any { it.hasIfNotModified() })
                assertTrue(peerSyncWarnings(manager.state.value).isEmpty())
            }
        } finally {
            manager.close()
            preferences.edit().clear().putBoolean("desired_connected", false).commit()
        }
    }
}
