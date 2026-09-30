package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.GetConversationRequest
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.MemorySecureStore
import com.dbpprt.dieter.core.testing.await
import com.dbpprt.dieter.core.testing.jvmTestPlatform
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okio.Path.Companion.toOkioPath

/** OUTBOX scenarios: durable commands against a real daemon. */
class OutboxEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    private fun card(fixture: com.dbpprt.dieter.core.testing.IsolatedGateway, title: String) = CreateConversationRequest(
        project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = title, prompt = "Plan $title", defer_start = true,
        workspace_mode = "project",
    )

    @Test
    fun aCardQueuedOfflineIsDeliveredOnceTheMachineReturns() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        fixture.daemonOffline()
        runtime.connection.state.await(describe = { "offline: ${runtime.connection.state.value}" }) { it.phase == ConnectionPhase.NO_MACHINE }

        val optimistic = runtime.createConversation(card(fixture, "Offline card"), chat = false)
        assertTrue(optimistic.id.startsWith(OutboxPolicy.LOCAL_PREFIX))
        val pending = runtime.workspace.state.value
        assertEquals("Offline card", pending.card(optimistic.id)?.title)
        assertTrue(optimistic.id in pending.pendingCardIds)
        assertEquals(1, runtime.outbox.view.value.machines[fixture.daemonId]?.changeCount)

        fixture.daemonOnline()
        val expected = OutboxPolicy.expectedConversationId(runtime.clientId, runtime.outbox.view.value.entries.single().command_id)!!
        val synced = runtime.workspace.state.await(45.seconds, describe = { "server card $expected" }) {
            it.card(expected)?.title == "Offline card" && it.card(optimistic.id) == null
        }
        assertTrue(expected !in synced.pendingCardIds)
        runtime.outbox.view.await(describe = { "outbox drained: ${runtime.outbox.view.value.entries}" }) { it.entries.isEmpty() }
        assertEquals(expected, runtime.outbox.view.value.resolve(optimistic.id))
    }

    @Test
    fun aCreatedCardNeverShowsTwiceWhileItSyncs() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val title = "Exactly once"
        // Every state the UI could render, including the one where the feed lists the
        // card before the create reply arrives.
        val seen = java.util.concurrent.CopyOnWriteArrayList<Int>()
        val watcher = runtime.scope.launch { runtime.workspace.state.collect { view -> seen += view.allItems.count { it.title == title } } }
        runtime.createConversation(
            CreateConversationRequest(project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = title, prompt = "p", defer_start = true, workspace_mode = "project"),
            chat = false,
        )
        runtime.workspace.state.await(30.seconds, describe = { "synced" }) { view -> view.allItems.any { it.title == title && OutboxPolicy.isServerBacked(it.id) } }
        runtime.outbox.view.await(30.seconds, describe = { "settled: ${runtime.outbox.view.value.entries}" }) { it.entries.isEmpty() }
        watcher.cancel()
        assertTrue(seen.isNotEmpty() && seen.all { it <= 1 }, "counts per state: $seen")
        assertEquals(1, runtime.workspace.state.value.allItems.count { it.title == title })
    }

    @Test
    fun aMessageToAPendingChatWaitsForItAndIsRetargeted() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        fixture.daemonOffline()
        runtime.connection.state.await { it.phase == ConnectionPhase.NO_MACHINE }

        val chat = runtime.createConversation(
            CreateConversationRequest(project_id = fixture.projectId, title = "Chat", prompt = "first", provider = "mock", model = "mock", effort = "low", defer_start = true, workspace_mode = "project"),
            chat = true,
        )
        val messageId = runtime.sendMessage(chat.id, listOf(MessagePart(type = "text", text = "follow-up")), HarnessSelection("mock", "mock", "low"))
        assertTrue(messageId in runtime.outbox.view.value.pendingMessageIds)

        fixture.daemonOnline()
        runtime.outbox.view.await(45.seconds, describe = { "delivered: ${runtime.outbox.view.value.entries}" }) { view ->
            view.entries.none { it.server_id.isEmpty() }
        }
        val serverId = runtime.outbox.view.value.resolve(chat.id)
        assertTrue(OutboxPolicy.isServerBacked(serverId))
        val transcript = runtime.onMachine(fixture.daemonId) { it.GetConversation().execute(GetConversationRequest(card_id = serverId, limit = 50)) }
        val texts = transcript.conversation!!.messages.flatMap { it.parts }.map { it.text } + transcript.conversation!!.queue.flatMap { it.parts }.map { it.text }
        assertTrue("follow-up" in texts, "transcript: $texts")
    }

    @Test
    fun aDefinitiveRejectionWaitsForTheUser() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val rejected = runtime.createConversation(card(fixture, "Nowhere").copy(board_id = "b_missing"), chat = false)

        val failed = runtime.outbox.view.await(describe = { "failed: ${runtime.outbox.view.value.entries}" }) { rejected.id in it.failedIds }
        assertNotNull(failed.failure(rejected.id))
        assertEquals("failed", runtime.workspace.state.value.card(rejected.id)?.runtime)
        assertTrue(failed.machines.getValue(fixture.daemonId).failed)

        runtime.retryPending(rejected.id)
        runtime.outbox.view.await { view -> view.entries.single().attempts >= 1 && rejected.id in view.failedIds }
        assertEquals(1, runtime.discardPending(rejected.id))
        runtime.workspace.state.await { it.card(rejected.id) == null }
        assertTrue(runtime.outbox.view.value.entries.isEmpty())
    }

    @Test
    fun theJournalSurvivesARestart() = e2e {
        val fixture = fixture()
        val directory = Files.createTempDirectory("dieter-core-outbox").toOkioPath()
        val secrets = MemorySecureStore()
        val first = runtime(fixture, jvmTestPlatform(directory, secrets))
        first.awaitConnected()
        first.awaitLoaded(fixture)
        fixture.daemonOffline()
        first.connection.state.await { it.phase == ConnectionPhase.NO_MACHINE }
        val optimistic = first.createConversation(card(fixture, "Survivor"), chat = false)
        val clientId = first.clientId
        first.shutdown()
        runtimes -= first

        val second = runtime(fixture, jvmTestPlatform(directory, secrets))
        assertEquals(clientId, second.clientId, "the install keeps its sync client ID")
        second.workspace.state.await(describe = { "restored pending card" }) { it.card(optimistic.id)?.title == "Survivor" }
        fixture.daemonOnline()
        second.outbox.view.await(45.seconds, describe = { "drained: ${second.outbox.view.value.entries}" }) { it.entries.isEmpty() }
        assertEquals(1, second.workspace.state.value.allItems.count { it.title == "Survivor" })
    }

    @Test
    fun aRepeatedSubmissionCreatesOneCard() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val request = card(fixture, "Once")
        val first = runtime.createConversation(request, chat = false, submissionId = "capture-1")
        runtime.outbox.view.await(describe = { "drained" }) { it.entries.isEmpty() }
        // A capture retry after the acknowledgement was applied reuses the command.
        val again = runtime.createConversation(request, chat = false, submissionId = "capture-1")
        runtime.outbox.view.await(describe = { "drained again" }) { it.entries.isEmpty() }
        delay(500)
        assertEquals(1, runtime.workspace.state.value.allItems.count { it.title == "Once" })
        assertEquals(runtime.outbox.view.value.resolve(first.id), runtime.outbox.view.value.resolve(again.id))
    }
}
