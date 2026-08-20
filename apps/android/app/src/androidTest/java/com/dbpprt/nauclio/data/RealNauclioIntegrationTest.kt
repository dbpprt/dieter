package com.dbpprt.nauclio.data

import android.Manifest
import android.app.NotificationManager
import android.os.Build
import com.dbpprt.nauclio.v1.CreateConversationRequest
import com.dbpprt.nauclio.v1.MessagePart
import com.google.protobuf.ByteString
import com.dbpprt.nauclio.NauclioApplication
import com.dbpprt.nauclio.connection.NauclioSyncService
import com.dbpprt.nauclio.connection.ConnectionPhase
import com.dbpprt.nauclio.connection.NauclioConnectionManager
import com.dbpprt.nauclio.settings.AppPreferences
import com.dbpprt.nauclio.settings.NavigationStyle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real transport verification through the configured gateway and an enrolled daemon. */
@RunWith(AndroidJUnit4::class)
class RealNauclioIntegrationTest {
    @Test
    fun cardAttachmentDraftRoundTripsThroughTheRealGateway() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcNauclioRepository(context)
        var cardId: String? = null
        try {
            val gateway = repository.activeEndpoint
            val daemons = repository.daemons().daemonsList
            val daemon = daemons.firstOrNull { it.id == gateway.daemonId } ?: daemons.firstOrNull()
                ?: error("The authenticated account must have an enrolled Nauclio daemon")
            val endpoint = gateway.copy(
                id = "${gateway.credentialId}#${daemon.id}",
                label = daemon.name.ifBlank { daemon.id },
                daemonId = daemon.id,
            )
            repository.replaceEndpoints(listOf(endpoint))
            repository.selectEndpoint(endpoint)
            repository.prepareDaemon()

            val state = repository.watchState().first { snapshot ->
                snapshot.projectsCount > 0 && snapshot.boardsList.any { board ->
                    board.lanesList.any { it.id == "todo" }
                }
            }
            val board = state.boardsList.first { value -> value.lanesList.any { it.id == "todo" } }
            val harness = repository.harnesses().harnessesList.first()
            val bytes = "android attachment fixture".encodeToByteArray()
            val request = CreateConversationRequest.newBuilder()
                .setProjectId(board.projectId)
                .setBoardId(board.id)
                .setLane("todo")
                .setTitle("Android attachment transport fixture")
                .setPrompt("Keep this deferred; verify the attached bytes only.")
                .setProvider(harness.id)
                .setModel(harness.defaultModel)
                .setDeferStart(true)
                .addAttachments(
                    MessagePart.newBuilder()
                        .setType("file")
                        .setMediaType("text/plain")
                        .setFilename("android-fixture.txt")
                        .setData(ByteString.copyFrom(bytes)),
                )
                .build()
            val card = repository.createConversation(request, chat = false)
            cardId = card.id
            val snapshot = repository.conversation(card.id)
            val attachment = snapshot.conversation.draftAttachmentsList.single()
            assertEquals("android-fixture.txt", attachment.filename)
            assertEquals("text/plain", attachment.mediaType)
            assertEquals(ByteString.copyFrom(bytes), attachment.data)
        } finally {
            cardId?.let { runCatching { repository.archiveCard(it, true) } }
            repository.close()
        }
    }

    @Test
    fun completeNativeGrpcPathReadsTheLocalWorkspace() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcNauclioRepository(context)
        try {
            val gateway = repository.activeEndpoint
            val daemons = repository.daemons().daemonsList
            val daemon = daemons.firstOrNull { it.id == gateway.daemonId } ?: daemons.firstOrNull()
                ?: error("The authenticated account must have an enrolled Nauclio daemon")
            val endpoint = gateway.copy(
                id = "${gateway.credentialId}#${daemon.id}",
                label = daemon.name.ifBlank { daemon.id },
                daemonId = daemon.id,
            )
            repository.replaceEndpoints(listOf(endpoint))
            repository.selectEndpoint(endpoint)
            val route = repository.prepareDaemon()
            assertTrue(route.startsWith("Direct") || route == "Gateway relay")

            val health = repository.health()
            assertEquals("ok", health.status)
            assertEquals(NAUCLIO_API_VERSION, health.version)

            val runtime = repository.runtimeStatus()
            assertTrue(runtime.ready)
            assertEquals("local-host", runtime.mode)
            assertFalse(runtime.sandboxed)

            val state = repository.watchState().first()
            assertTrue("The real Nauclio instance must have a registered project", state.projectsCount > 0)
            val projectId = state.project.id.ifBlank { state.projectsList.first().id }
            assertTrue(repository.harnesses().harnessesCount > 0)
            assertTrue(repository.files(projectId).entriesCount > 0)

            val preview = repository.previewSchedule("0 9 * * 1-5", "Europe/Berlin", 5)
            assertEquals(5, preview.timesCount)
        } finally {
            repository.close()
        }
    }

    @Test
    fun foregroundConnectionKeepsRealWorkspaceSynchronizedInBackground() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val application = context.applicationContext as NauclioApplication
        val manager = application.container.connectionManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                instrumentation.uiAutomation.grantRuntimePermission(
                    context.packageName,
                    Manifest.permission.POST_NOTIFICATIONS,
                )
            }
            manager.setBackgroundSyncEnabled(true)
            manager.connect()
            NauclioSyncService.start(context)
            manager.onAppBackgrounded()

            val connected = withTimeout(20_000) {
                manager.state.filter {
                    it.phase == ConnectionPhase.CONNECTED &&
                        it.projects.isNotEmpty() &&
                        it.boards.isNotEmpty() &&
                        it.projects.all { project ->
                            it.projectHosts[project.id]?.daemonId?.isNotBlank() == true
                        }
                }.first()
            }
            assertTrue(connected.endpointConnections.any { it.daemonId != null && it.online })
            assertTrue(connected.projects.all { project ->
                connected.projectHosts[project.id]?.daemonId?.isNotBlank() == true
            })
            assertTrue(connected.chats.all { it.scope == "chat" && it.boardId.isBlank() })

            val notificationManager = context.getSystemService(NotificationManager::class.java)
            withTimeout(10_000) {
                while (notificationManager.activeNotifications.none { it.id == NauclioSyncService.CONNECTION_NOTIFICATION_ID }) {
                    delay(100)
                }
            }
            val notification = notificationManager.activeNotifications.single { it.id == NauclioSyncService.CONNECTION_NOTIFICATION_ID }
            assertTrue(notification.notification.flags and android.app.Notification.FLAG_ONGOING_EVENT != 0)
            val runningChatChannel = notificationManager.getNotificationChannel(NauclioSyncService.RUNNING_CHAT_CHANNEL_ID)
            assertEquals(NotificationManager.IMPORTANCE_LOW, runningChatChannel.importance)
            assertEquals(null, runningChatChannel.sound)
            val agentResultsChannel = notificationManager.getNotificationChannel(NauclioSyncService.AGENT_RESULTS_CHANNEL_ID)
            assertEquals(NotificationManager.IMPORTANCE_DEFAULT, agentResultsChannel.importance)
        } finally {
            manager.connect()
            manager.setBackgroundSyncEnabled(true)
        }
    }

    @Test
    fun appSettingsPersistVisualStyleAndOrderedConnections() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val application = context.applicationContext as NauclioApplication
        val manager = application.container.connectionManager
        val originalEndpoints = manager.state.value.configuredConnections.map {
            nauclioEndpointFromAddress(it.id, it.label, it.address)
        }
        val preferences = AppPreferences(context)
        val originalStyle = preferences.navigationStyle.value
        val originalShowReasoning = preferences.showReasoningTraces.value
        try {
            assertTrue(originalEndpoints.isNotEmpty())
            val saved = listOf(NauclioEndpoint("saved_local", "Saved localhost", NAUCLIO_LOCAL_HOST, NAUCLIO_LOCAL_PORT))
            manager.updateEndpoints(saved)
            preferences.setNavigationStyle(NavigationStyle.GLASS)
            preferences.setShowReasoningTraces(true)

            val restoredRepository = GrpcNauclioRepository(context)
            val restoredManager = NauclioConnectionManager(context, restoredRepository)
            try {
                assertEquals(saved, restoredRepository.endpoints)
                assertEquals(NavigationStyle.GLASS, AppPreferences(context).navigationStyle.value)
                assertTrue(AppPreferences(context).showReasoningTraces.value)
            } finally {
                restoredManager.close()
            }
        } finally {
            manager.updateEndpoints(originalEndpoints)
            preferences.setNavigationStyle(originalStyle)
            preferences.setShowReasoningTraces(originalShowReasoning)
        }
    }
}
