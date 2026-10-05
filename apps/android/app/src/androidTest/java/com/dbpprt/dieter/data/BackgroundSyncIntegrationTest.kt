package com.dbpprt.dieter.data

import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.e2e.IsolatedCore
import com.dbpprt.dieter.ui.DieterViewModel
import com.dbpprt.dieter.core.navigation.Destination
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Turns reach the device through every machine's change stream without
 * opening their conversations, and Live mode keeps opened conversations warm
 * across backgrounding, against the isolated gateway the e2e runner reverses
 * to the device's loopback.
 */
@RunWith(AndroidJUnit4::class)
class BackgroundSyncIntegrationTest {
    private val container get() = (InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as DieterApplication).container

    @Test
    fun turnsArriveThroughTheMachinesStreamWithoutOpeningTheChat() = runBlocking {
        val core = container.core
        val workspace = IsolatedCore.connect(container)
        val project = workspace.projects.first()
        var chatId: String? = null
        try {
            val chat = IsolatedCore.createConversation(
                container,
                CreateConversationRequest(project_id = project.id, title = "Background sync E2E ${UUID.randomUUID().toString().take(8)}", prompt = "Reply with BG_SYNC_OK.", provider = "mock", model = "mock", defer_start = true, workspace_mode = "project"),
                chat = true,
            )
            chatId = chat.id
            // The chat is never opened: its reply arrives with its machine's change stream.
            core.sendMessage(chat.id, listOf(MessagePart(type = "text", text = "Background delta please")), HarnessSelection("mock", "mock"))
            withTimeout(30_000) {
                core.workspace.state.first { view -> (view.card(chat.id)?.response_seq ?: 0L) > 0L }
            }
            assertTrue("No transcript session was opened", core.onCore { core.conversations.session(chat.id) } == null)
        } finally {
            chatId?.let { id ->
                runCatching { core.onBoard { cancel(id) } }
                runCatching { core.onBoard { archive(id) } }
            }
            IsolatedCore.disconnect(container)
        }
    }

    @Test
    fun liveSyncKeepsTranscriptsWarmInBackground() = runBlocking {
        val container = container
        val core = container.core
        val policy = container.policy
        val originalMode = policy.mode.value
        val chatIds = mutableListOf<String>()
        var model: DieterViewModel? = null
        var phaseObserver: kotlinx.coroutines.Job? = null
        val lostConnection = AtomicBoolean(false)
        try {
            withContext(kotlinx.coroutines.Dispatchers.Main) { policy.setMode(BackgroundMode.LIVE) }
            val workspace = IsolatedCore.connect(container)
            val project = workspace.projects.first()
            val daemonId = IsolatedCore.machineId
            val chat = IsolatedCore.createConversation(
                container,
                CreateConversationRequest(project_id = project.id, title = "Warm cache E2E ${UUID.randomUUID().toString().take(8)}", prompt = "Reply with WARM_OK.", provider = "mock", model = "mock", workspace_mode = "project"),
                chat = true,
            )
            val secondChat = IsolatedCore.createConversation(
                container,
                CreateConversationRequest(project_id = project.id, title = "Second warm cache E2E", prompt = "Reply with SECOND_WARM_OK.", provider = "mock", model = "mock", workspace_mode = "project"),
                chat = true,
            )
            chatIds += listOf(chat.id, secondChat.id)

            model = withContext(kotlinx.coroutines.Dispatchers.Main) {
                DieterViewModel(core, container.appPreferences, policy, container, container.taskCaptures).also { it.start() }
            }
            withTimeout(5_000) { model.state.first { state -> chatIds.all { id -> state.chats.any { it.id == id } } } }
            // The first open reads each transcript from its machine and caches it.
            for (selected in listOf(chat, secondChat)) {
                val openedAt = SystemClock.elapsedRealtime()
                withContext(kotlinx.coroutines.Dispatchers.Main) { model.openCard(selected, Destination.CHATS) }
                withTimeout(15_000) {
                    model.state.first { state -> state.selectedCardId == selected.id && state.conversation?.detail?.card?.id == selected.id }
                }
                Log.i("DieterPerformance", "liveChatFirstOpen ms=${SystemClock.elapsedRealtime() - openedAt}")
            }

            phaseObserver = launch {
                core.connection.state.collect {
                    if (it.phase != ConnectionPhase.CONNECTED) lostConnection.set(true)
                }
            }
            val switchTimes = mutableListOf<Long>()
            repeat(25) {
                withContext(kotlinx.coroutines.Dispatchers.Main) { policy.setForeground(false) }
                delay(150)
                withContext(kotlinx.coroutines.Dispatchers.Main) { policy.setForeground(true) }
                for (selected in listOf(secondChat, chat)) {
                    val switchedAt = SystemClock.elapsedRealtime()
                    withContext(kotlinx.coroutines.Dispatchers.Main) { model.openCard(selected, Destination.CHATS) }
                    val switched = withTimeout(1_000) {
                        model.state.first { it.selectedCardId == selected.id && it.conversation?.detail?.card?.id == selected.id }
                    }
                    switchTimes += SystemClock.elapsedRealtime() - switchedAt
                    assertFalse("Switching warmed chats must keep the workspace live", switched.conversationSyncing)
                }
            }
            val sortedSwitches = switchTimes.sorted()
            val switchP95 = sortedSwitches[(sortedSwitches.size * 0.95).toInt().coerceAtMost(sortedSwitches.lastIndex)]
            Log.i("DieterPerformance", "liveChatOpen switches=${switchTimes.size} p95Ms=$switchP95 maxMs=${sortedSwitches.last()}")
            assertTrue("Warm chat-switch p95 was ${switchP95}ms", switchP95 < 250)

            // Require both replies and terminal state before measuring idle;
            // worker startup and streaming belong to active cost.
            withTimeout(60_000) {
                core.workspace.state.first { view ->
                    chatIds.all { id -> view.card(id)?.let { card -> card.runtime == "idle" && card.response_seq > 0L } == true }
                }
            }
            delay(2_000)
            val idleSampleMillis = argument("idleSampleMillis").toLongOrNull()?.coerceIn(6_000, 60_000) ?: 6_000
            repeat(argument("idleSampleWindows").toIntOrNull()?.coerceIn(1, 2) ?: 1) { window ->
                val beforeThreads = threadCpuTicks()
                val idleCpuStarted = Process.getElapsedCpuTime()
                val idleStarted = SystemClock.elapsedRealtime()
                delay(idleSampleMillis)
                val cpuMillis = Process.getElapsedCpuTime() - idleCpuStarted
                val wallMillis = SystemClock.elapsedRealtime() - idleStarted
                val ticksPerSecond = android.system.Os.sysconf(android.system.OsConstants._SC_CLK_TCK)
                val threadCosts = threadCpuTicks().mapNotNull { (id, current) ->
                    val previous = beforeThreads[id] ?: return@mapNotNull null
                    current.first to (current.second - previous.second) * 1000 / ticksPerSecond
                }.sortedByDescending { it.second }.take(8)
                Log.i("DieterPerformance", "liveIdle window=${window + 1} cpuMs=$cpuMillis wallMs=$wallMillis threads=$threadCosts")
            }
            assertFalse(model.state.value.conversationSyncing)
            assertEquals(ConnectionPhase.CONNECTED, core.connection.state.value.phase)
            assertEquals(daemonId, core.choice.checkout(project.id))
            assertFalse("Activation and chat switches must preserve the shared connection", lostConnection.get())
        } finally {
            phaseObserver?.cancel()
            model?.let { withContext(kotlinx.coroutines.Dispatchers.Main) { it.stop() } }
            chatIds.forEach { id ->
                runCatching { core.onBoard { cancel(id) } }
                runCatching { core.onBoard { archive(id) } }
            }
            withContext(kotlinx.coroutines.Dispatchers.Main) { policy.setMode(originalMode) }
            IsolatedCore.disconnect(container)
        }
    }

    private fun threadCpuTicks(): Map<String, Pair<String, Long>> =
        java.io.File("/proc/self/task").listFiles().orEmpty().mapNotNull { directory ->
            runCatching {
                val stat = java.io.File(directory, "stat").readText()
                val name = stat.substringAfter('(').substringBeforeLast(')')
                val fields = stat.substringAfterLast(") ").split(' ')
                directory.name to (name to (fields[11].toLong() + fields[12].toLong()))
            }.getOrNull()
        }.toMap()

    private fun argument(name: String): String = InstrumentationRegistry.getArguments().getString(name).orEmpty()
}
