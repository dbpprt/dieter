package com.dbpprt.dieter.data

import android.Manifest
import android.app.NotificationManager
import android.os.Build
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.CreateTerminalRequest
import com.dbpprt.dieter.v1.MessagePart
import com.google.protobuf.ByteString
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.connection.DieterSyncService
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.NavigationStyle
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
import java.io.ByteArrayOutputStream
import java.util.UUID

/** Real transport verification through the configured gateway and an enrolled daemon. */
@RunWith(AndroidJUnit4::class)
class RealDieterIntegrationTest {
    @Test
    fun terminalSurvivesAndroidTransportLossThroughTheRealGateway() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var repository = GrpcDieterRepository(context)
        var terminalId: String? = null
        try {
            connectToEnrolledDaemon(repository)
            val project = repository.state().projectsList.first()
            val nonce = UUID.randomUUID().toString().take(8)
            val terminal = repository.createTerminal(
                CreateTerminalRequest.newBuilder()
                    .setProjectId(project.id)
                    .setName("android-transport-$nonce")
                    .setShell("sh")
                    .setWorkingDirectory(project.path)
                    .setColumns(92)
                    .setRows(26)
                    .build(),
            )
            terminalId = terminal.id
            assertEquals("running", terminal.status)

            val firstMarker = "ANDROID_TERMINAL_ONE_$nonce"
            repository.writeTerminal(terminal.id, "printf '$firstMarker\\n'\n".encodeToByteArray())
            val firstSequence = awaitTerminalText(repository, terminal.id, 0, firstMarker)

            // Closing the Android channel must not close the daemon-owned PTY.
            repository.close()
            repository = GrpcDieterRepository(context)
            connectToEnrolledDaemon(repository)
            val resumed = repository.terminals().terminalsList.single { it.id == terminal.id }
            assertEquals("running", resumed.status)

            val secondMarker = "ANDROID_TERMINAL_TWO_$nonce"
            repository.writeTerminal(terminal.id, "printf '$secondMarker\\n'\n".encodeToByteArray())
            val resumedSequence = awaitTerminalText(repository, terminal.id, firstSequence, secondMarker)
            assertTrue(resumedSequence > firstSequence)
        } finally {
            terminalId?.let { runCatching { repository.closeTerminal(it) } }
            repository.close()
        }
    }

    @Test
    fun cardAttachmentDraftRoundTripsThroughTheRealGateway() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcDieterRepository(context)
        var cardId: String? = null
        try {
            val gateway = repository.activeEndpoint
            val daemons = repository.daemons().daemonsList
            val daemon = daemons.firstOrNull { it.id == gateway.daemonId } ?: daemons.firstOrNull()
                ?: error("The authenticated account must have an enrolled Dieter daemon")
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
        val repository = GrpcDieterRepository(context)
        try {
            val gateway = repository.activeEndpoint
            val daemons = repository.daemons().daemonsList
            val daemon = daemons.firstOrNull { it.id == gateway.daemonId } ?: daemons.firstOrNull()
                ?: error("The authenticated account must have an enrolled Dieter daemon")
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
            assertEquals(DIETER_API_VERSION, health.version)

            val runtime = repository.runtimeStatus()
            assertTrue(runtime.ready)
            assertEquals("local-host", runtime.mode)
            assertFalse(runtime.sandboxed)

            val state = repository.watchState().first()
            assertTrue("The real Dieter instance must have a registered project", state.projectsCount > 0)
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
        val application = context.applicationContext as DieterApplication
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
            DieterSyncService.start(context)
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
                while (notificationManager.activeNotifications.none { it.id == DieterSyncService.CONNECTION_NOTIFICATION_ID }) {
                    delay(100)
                }
            }
            val notification = notificationManager.activeNotifications.single { it.id == DieterSyncService.CONNECTION_NOTIFICATION_ID }
            assertTrue(notification.notification.flags and android.app.Notification.FLAG_ONGOING_EVENT != 0)
            val runningChatChannel = notificationManager.getNotificationChannel(DieterSyncService.RUNNING_CHAT_CHANNEL_ID)
            assertEquals(NotificationManager.IMPORTANCE_LOW, runningChatChannel.importance)
            assertEquals(null, runningChatChannel.sound)
            val agentResultsChannel = notificationManager.getNotificationChannel(DieterSyncService.AGENT_RESULTS_CHANNEL_ID)
            assertEquals(NotificationManager.IMPORTANCE_DEFAULT, agentResultsChannel.importance)
        } finally {
            manager.connect()
            manager.setBackgroundSyncEnabled(true)
        }
    }

    @Test
    fun appSettingsPersistVisualStyleAndOrderedConnections() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val application = context.applicationContext as DieterApplication
        val manager = application.container.connectionManager
        val originalEndpoints = manager.state.value.configuredConnections.map {
            dieterEndpointFromAddress(it.id, it.label, it.address)
        }
        val preferences = AppPreferences(context)
        val originalStyle = preferences.navigationStyle.value
        val originalShowReasoning = preferences.showReasoningTraces.value
        try {
            assertTrue(originalEndpoints.isNotEmpty())
            val saved = listOf(DieterEndpoint("saved_local", "Saved localhost", DIETER_LOCAL_HOST, DIETER_LOCAL_PORT))
            manager.updateEndpoints(saved)
            preferences.setNavigationStyle(NavigationStyle.GLASS)
            preferences.setShowReasoningTraces(true)

            val restoredRepository = GrpcDieterRepository(context)
            val restoredManager = DieterConnectionManager(context, restoredRepository)
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

    private suspend fun connectToEnrolledDaemon(repository: GrpcDieterRepository) {
        val gateway = repository.activeEndpoint
        val daemons = repository.daemons().daemonsList
        val daemon = daemons.firstOrNull { it.id == gateway.daemonId } ?: daemons.firstOrNull()
            ?: error("The authenticated account must have an enrolled Dieter daemon")
        val endpoint = gateway.copy(
            id = "${gateway.credentialId}#${daemon.id}",
            label = daemon.name.ifBlank { daemon.id },
            daemonId = daemon.id,
        )
        repository.replaceEndpoints(listOf(endpoint))
        repository.selectEndpoint(endpoint)
        repository.prepareDaemon()
    }

    private suspend fun awaitTerminalText(
        repository: GrpcDieterRepository,
        terminalId: String,
        afterSequence: Long,
        marker: String,
    ): Long {
        val output = ByteArrayOutputStream()
        return withTimeout(15_000) {
            repository.watchTerminal(terminalId, afterSequence).first { frame ->
                output.write(frame.data.toByteArray())
                output.toString(Charsets.UTF_8.name()).contains(marker)
            }.sequence
        }
    }
}
