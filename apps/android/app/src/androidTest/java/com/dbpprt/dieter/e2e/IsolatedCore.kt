package com.dbpprt.dieter.e2e

import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.DieterContainer
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.GetConversationRequest
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.store.WorkspaceView
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue

/**
 * The isolated gateway the e2e runner starts on the host and reverses to the
 * device's loopback. Tests sign the app's shared core in with its disposable
 * token; nothing touches an operator's gateway or daemon.
 */
object IsolatedCore {
    private val arguments: Bundle get() = InstrumentationRegistry.getArguments()

    val gateway: Gateway
        get() = Gateway("Isolated gateway", "127.0.0.1", requireNotNull(arguments.getString("isolatedGatewayPort")).toInt(), secure = false)

    val token: String get() = requireNotNull(arguments.getString("isolatedGatewayToken"))

    /** The fixture daemon's machine ID. */
    val machineId: String get() = requireNotNull(arguments.getString("isolatedMachineId"))

    /** The fixture daemon's seeded board. */
    val boardId: String get() = requireNotNull(arguments.getString("isolatedBoardId"))

    /**
     * Signs in, keeps the app in the foreground connection mode, and waits for the fixture workspace.
     * Skips the calling test when the runner started no isolated gateway.
     */
    fun connect(container: DieterContainer, timeout: Duration = 30.seconds): WorkspaceView = runBlocking {
        assumeTrue("Needs the isolated gateway that `just e2e run` starts", !arguments.getString("isolatedGatewayToken").isNullOrBlank())
        container.core.adoptSession(gateway, token)
        container.policy.setForeground(true)
        withTimeout(timeout) {
            container.core.connection.state.first { it.phase == ConnectionPhase.CONNECTED }
            container.core.workspace.state.first { view -> view.loaded && view.projects.isNotEmpty() && view.boards.values.any { it.isNotEmpty() } }
        }
    }

    /** The machine the feed is attached to (the fixture daemon). */
    fun daemonId(container: DieterContainer): String = requireNotNull(container.core.connection.state.value.attachedMachineId)

    /** Queues a conversation through the core's outbox and returns it once the daemon's copy synced. */
    fun createConversation(container: DieterContainer, request: CreateConversationRequest, chat: Boolean, timeout: Duration = 30.seconds): Card = runBlocking {
        val local = container.core.createConversation(request, chat)
        withTimeout(timeout) {
            val id = container.core.outbox.view.first { local.id in it.resolutions }.resolve(local.id)
            requireNotNull(container.core.workspace.state.first { it.card(id) != null }.card(id))
        }
    }

    /** [daemonId]'s agent catalog, loading it through the core's metadata store. */
    fun harnesses(container: DieterContainer, daemonId: String, timeout: Duration = 30.seconds): List<Harness> = runBlocking {
        container.core.onCore { container.core.metadata.ensure(daemonId) }
        withTimeout(timeout) {
            container.core.metadata.machines.first { machines -> machines[daemonId]?.harnesses?.harnesses.orEmpty().any { it.models.isNotEmpty() } }
        }.getValue(daemonId).harnesses!!.harnesses
    }

    /** The daemon's current snapshot of a conversation (draft attachments included). */
    fun conversation(container: DieterContainer, cardId: String, daemonId: String = daemonId(container)): ConversationSnapshot = runBlocking {
        container.core.onMachine(daemonId) { it.GetConversation().execute(GetConversationRequest(card_id = cardId, limit = 50)) }
    }

    /** The first synced card matching [predicate] (board cards and chats). */
    fun awaitCard(container: DieterContainer, timeout: Duration = 30.seconds, predicate: (Card) -> Boolean): Card = runBlocking {
        withTimeout(timeout) {
            container.core.workspace.state.first { view -> view.allItems.any(predicate) }.allItems.first(predicate)
        }
    }

    /** Stops wanting a connection, so the next test starts from a quiet app. */
    fun disconnect(container: DieterContainer) = runBlocking { container.core.setConnected(false) }
}
