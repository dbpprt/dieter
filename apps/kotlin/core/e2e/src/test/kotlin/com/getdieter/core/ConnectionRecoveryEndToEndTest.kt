package com.getdieter.core

import com.getdieter.api.v1.CreateConversationRequest
import com.getdieter.api.v1.MessagePart
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.SetConnected
import com.getdieter.client.v1.SetForeground
import com.getdieter.client.v1.SystemWoke
import com.getdieter.core.client.ClientApi
import com.getdieter.core.connection.ConnectionPhase
import com.getdieter.core.connection.StreamConfig
import com.getdieter.core.connection.SyncState
import com.getdieter.core.conversation.ConversationSession
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.platform.SoftwareDeviceKeys
import com.getdieter.core.testing.ConnectionPerChannelTransport
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.IsolatedGateway
import com.getdieter.core.testing.SharedGateway
import com.getdieter.core.testing.StallingProxy
import com.getdieter.core.testing.await
import com.getdieter.core.testing.jvmTestPlatform
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.junit.AfterClass

/**
 * After a Mac sleeps and wakes, the connections it had open can lead nowhere without ever failing.
 * The core replaces them on its own once its watchdogs notice, and at once when the app reports the
 * wake.
 */
class ConnectionRecoveryEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private suspend fun connect(fixture: IsolatedGateway, proxy: StallingProxy): CoreRuntime {
        val keys =
            SoftwareDeviceKeys(
                Files.createTempDirectory("wake-device").resolve("key").toFile(),
                deviceName = "Wake test",
            )
        val runtime =
            runtime(
                fixture,
                platform =
                    jvmTestPlatform(
                        deviceKeys = keys,
                        transport = ConnectionPerChannelTransport(keys),
                    ),
                gatewayUrl = proxy.url,
            )
        runtime.awaitConnected()
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        return runtime
    }

    @Test
    fun silentConnectionsAreReplacedWithoutAnyFailure() = e2e {
        val fixture = shared.acquire()
        StallingProxy(fixture.address).use { proxy ->
            val runtime = connect(fixture, proxy)
            val silent = runtime.connection.session.value
            proxy.stall()
            // The machine's silent stream turns its view stale first; the silent presence stream
            // then ends the session, and the next one connects afresh.
            runtime.awaitSync(fixture.daemonId, SyncState.STALE)
            runtime.connection.session.await(
                60.seconds,
                describe = { "a new session: ${runtime.connection.state.value}" },
            ) {
                it != null && it !== silent
            }
            runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
            assertTrue(runtime.connection.machines.value.online.any { it.id == fixture.daemonId })
        }
    }

    @Test
    fun aWakeReopensSilentConnectionsAtOnce() = e2e {
        verifyImmediateRecovery(Command(system_woke = SystemWoke()))
    }

    @Test
    fun desktopActivationReopensSilentBackgroundConnectionsAtOnce() = e2e {
        verifyImmediateRecovery(Command(set_foreground = SetForeground(foreground = true)))
    }

    private suspend fun verifyImmediateRecovery(command: Command) {
        val fixture = shared.acquire()
        StallingProxy(fixture.address).use { proxy ->
            val runtime = connect(fixture, proxy)
            val actor = runtime(fixture)
            actor.awaitLoaded(fixture)
            val card =
                actor.onMachine(fixture.daemonId) {
                    it.CreateCard()
                        .execute(
                            CreateConversationRequest(
                                project_id = fixture.projectId,
                                board_id = fixture.boardId,
                                lane = "todo",
                                title = "Changed while the desktop was away",
                                workspace_mode = "project",
                            )
                        )
                }
            actor.awaitSynced(card.id)
            runtime.awaitSynced(card.id)
            val silent = runtime.connection.session.value
            proxy.stall()
            actor.onBoard { archive(card.id) }
            assertTrue(runtime.workspace.state.value.card(card.id) != null)
            ClientApi(runtime).dispatch(command)
            // Well before the silent stream would have turned the machine's view stale.
            runtime.connection.session.await(
                10.seconds,
                describe = { "a new session: ${runtime.connection.state.value}" },
            ) {
                it != null && it !== silent
            }
            runtime.connection.syncs.await(
                10.seconds,
                describe = { "current: ${runtime.connection.syncs.value[fixture.daemonId]}" },
            ) {
                it[fixture.daemonId]?.current == true
            }
            // Current is a barrier for the full account projection, not just a healthy socket.
            assertEquals(null, runtime.workspace.state.value.card(card.id))
        }
    }

    @Test
    fun aWakeKeepsADisconnect() = e2e {
        val fixture = shared.acquire()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        val api = ClientApi(runtime)
        api.dispatch(Command(set_connected = SetConnected(connected = false)))
        runtime.connection.state.await(30.seconds) { it.phase == ConnectionPhase.DISCONNECTED }
        api.dispatch(Command(system_woke = SystemWoke()))
        api.dispatch(Command(set_foreground = SetForeground(foreground = true)))
        delay(2.seconds)
        assertEquals(ConnectionPhase.DISCONNECTED, runtime.connection.state.value.phase)
        assertEquals(null, runtime.connection.session.value)
    }

    /**
     * A phone disconnects while it is in the background. Its machines did nothing wrong: coming
     * back, the inbox never says they are offline or not responding while the app reconnects.
     */
    @Test
    fun aBackgroundedAppNeverBlamesItsMachines() = e2e {
        val fixture = shared.acquire()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitSync(fixture.daemonId, SyncState.LIVE)
        runtime.awaitLoaded(fixture)
        val created =
            runtime.onMachine(fixture.daemonId) {
                it.CreateCard()
                    .execute(
                        CreateConversationRequest(
                            project_id = fixture.projectId,
                            board_id = fixture.boardId,
                            lane = "todo",
                            title = "Waiting while the phone is away",
                            workspace_mode = "project",
                        )
                    )
            }
        runtime.awaitSynced(created.id)
        val card = runtime.workspace.state.value.card(created.id)!!
        val blamed = mutableListOf<String>()
        val watcher =
            runtime.scope.launch {
                runtime.connection.syncs.collect { syncs ->
                    runtime
                        .staleness(card, syncs, runtime.connection.machines.value)
                        ?.let(blamed::add)
                }
            }
        try {
            runtime.setActive(false)
            runtime.connection.state.await { it.phase == ConnectionPhase.DISCONNECTED }
            // Well past the grace period a broken stream gets before its machine is blamed.
            delay(StreamConfig().grace + 3.seconds)
            runtime.setActive(true)
            runtime.awaitConnected()
            runtime.connection.syncs.await(30.seconds) { it[fixture.daemonId]?.current == true }
        } finally {
            watcher.cancel()
        }
        assertEquals(emptyList(), blamed)
    }

    /**
     * Returning to the foreground replaces the gateway session while an open conversation waits for
     * a route to its machine. The conversation resubscribes on the new session and keeps streaming;
     * it never needs to be closed and opened again.
     */
    @Test
    fun anOpenConversationOutlivesASessionReplacedWhileItConnects() = e2e {
        val fixture = shared.acquire()
        StallingProxy(fixture.address).use { proxy ->
            val runtime = connect(fixture, proxy)
            runtime.awaitLoaded(fixture)
            val local =
                runtime.createConversation(
                    CreateConversationRequest(
                        project_id = fixture.projectId,
                        title = "first question",
                        prompt = "first question",
                        provider = "mock",
                        model = "mock",
                        effort = "low",
                        workspace_mode = "project",
                    ),
                    chat = true,
                )
            val session = runtime.openConversation(local.id)
            session.awaitReplies(1)
            session.view.await { !it.syncing }

            // The connections go silent while away, and the conversation has to pick its
            // machine's route again over the silent gateway.
            proxy.stall()
            runtime.onCore { runtime.sessions.invalidate(fixture.daemonId) }
            session.view.await(10.seconds) { it.syncing }
            delay(1.seconds)
            ClientApi(runtime).dispatch(Command(set_foreground = SetForeground(foreground = true)))
            runtime.awaitConnected()
            runtime.awaitSync(fixture.daemonId, SyncState.LIVE)

            runtime.sendMessage(
                session.cardId,
                listOf(MessagePart(type = "text", text = "second question")),
            )
            session.awaitReplies(2)
            assertEquals(false, session.view.value.syncing)
        }
    }

    private suspend fun ConversationSession.awaitReplies(count: Int) =
        view.await(60.seconds, describe = { "$count replies: ${view.value}" }) { view ->
            OutboxPolicy.isServerBacked(view.cardId) &&
                view.messages.count { it.role == "assistant" } >= count &&
                view.conversation?.status?.let { it != "running" && it != "starting" } == true
        }

    companion object {
        private val shared = SharedGateway()

        @JvmStatic @AfterClass fun closeFixture() = shared.close()
    }
}
