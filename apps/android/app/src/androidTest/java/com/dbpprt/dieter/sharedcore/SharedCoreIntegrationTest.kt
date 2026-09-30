package com.dbpprt.dieter.sharedcore

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.DieterContainer
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.data.DieterCredentialStore
import com.dbpprt.dieter.e2e.IsolatedCore
import java.util.UUID
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The shared core on a real device: Android's OkHttp/BouncyCastle transport,
 * keystore-backed credentials, and private file storage against the isolated
 * gateway. Protocol behavior is covered by the core's JVM end-to-end tests;
 * these prove the Android bindings carry it.
 */
@RunWith(AndroidJUnit4::class)
class SharedCoreIntegrationTest {
    private val container: DieterContainer
        get() = (InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as DieterApplication).container

    @After fun disconnect() = IsolatedCore.disconnect(container)

    @Test
    fun relaySignInSyncsTheFixtureAndReachesItsMachine() = runBlocking {
        val workspace = IsolatedCore.connect(container)
        assertTrue(workspace.projects.isNotEmpty())
        val daemonId = IsolatedCore.daemonId(container)
        val information = container.core.onMachine(daemonId) { it.GetMachineInformation().execute(Unit) }
        assertTrue(information.hostname.isNotBlank())
        // The session token is kept in the keystore-backed store, keyed by the gateway's origin.
        val stored = DieterCredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).get(IsolatedCore.gateway.origin)
        assertEquals(IsolatedCore.token, stored)
    }

    @Test
    fun offlineNavigationEditDrainsAfterReconnect() = runBlocking {
        IsolatedCore.connect(container)
        val core = container.core
        core.setConnected(false)
        withTimeout(30.seconds) { core.connection.state.first { it.phase == ConnectionPhase.DISCONNECTED } }
        val name = "Offline ${UUID.randomUUID().toString().take(8)}"
        core.editNavigation { createFolder(FolderScope.PROJECTS, name) }
        assertTrue(core.navigationKv.status.value.pending > 0)

        IsolatedCore.connect(container)
        withTimeout(30.seconds) { core.navigationKv.status.first { it.pending == 0 && it.caughtUp } }
        val folder = core.navigationLayout().first().folders(FolderScope.PROJECTS).single { it.name == name }
        core.editNavigation { deleteFolder(FolderScope.PROJECTS, folder.id) }
        withTimeout(30.seconds) { core.navigationKv.status.first { it.pending == 0 } }
    }

    @Test
    fun conversationQueuedOfflineReachesTheDaemonAfterReconnect() = runBlocking {
        val workspace = IsolatedCore.connect(container)
        val core = container.core
        val board = workspace.boards.values.flatten().first { candidate -> candidate.lanes.any { it.id.equals("todo", ignoreCase = true) } }
        core.setConnected(false)
        withTimeout(30.seconds) { core.connection.state.first { it.phase == ConnectionPhase.DISCONNECTED } }
        val title = "Android offline queue ${UUID.randomUUID().toString().take(8)}"
        val local = core.createConversation(
            CreateConversationRequest(
                project_id = board.project_id, board_id = board.id, lane = "todo", title = title, prompt = "Offline Android task",
                provider = "mock", model = "mock", defer_start = true, workspace_mode = "project",
            ),
            chat = false,
        )
        assertTrue(local.id in core.outbox.view.value.pendingCardIds)

        IsolatedCore.connect(container)
        val id = withTimeout(30.seconds) { core.outbox.view.first { local.id in it.resolutions } }.resolve(local.id)
        val synced = withTimeout(30.seconds) { core.workspace.state.first { it.card(id) != null } }.card(id)!!
        assertEquals(title, synced.title)
        core.onBoard { archive(id) }
    }
}
