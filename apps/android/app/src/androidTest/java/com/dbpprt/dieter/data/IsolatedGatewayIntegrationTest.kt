package com.dbpprt.dieter.data

import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.CreateProjectRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.StartCardRequest
import com.dbpprt.dieter.v1.SyncFrame
import com.dbpprt.dieter.v1.UpdateProjectWorkspaceSettingsRequest
import com.dbpprt.dieter.v1.ValidationCommand
import com.google.protobuf.ByteString
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import kotlin.system.measureTimeMillis

/**
 * Explicitly gated real-emulator coverage for an isolated gateway. It is not
 * part of the normal connected suite because it starts an actual local agent.
 */
@RunWith(AndroidJUnit4::class)
class IsolatedGatewayIntegrationTest {
    @Test
    fun machineScopedProjectCreationAndWorkspaceAdministrationRoundTrip() = runBlocking {
        val origin = isolatedOrigin()
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcDieterRepository(context)
        var projectId: String? = null
        var cardId: String? = null
        try {
            val endpoint = connect(repository, origin, token)
            repository.prepareDaemon()
            val activeBefore = repository.activeEndpoint
            val legacyDaemon = repository.daemons().daemonsList.first { it.apiVersion != DIETER_API_VERSION }
            val legacyEndpoint = origin.copy(
                id = "${origin.credentialId}#${legacyDaemon.id}",
                label = legacyDaemon.name,
                daemonId = legacyDaemon.id,
                apiVersion = legacyDaemon.apiVersion,
            )
            repository.replaceEndpoints(listOf(endpoint, legacyEndpoint))
            val incompatible = runCatching { repository.listDirectoriesOn(legacyEndpoint.id) }.exceptionOrNull()
            assertTrue(incompatible?.message.orEmpty().contains("incompatible", ignoreCase = true))
            val root = repository.listDirectoriesOn(endpoint.id)
            assertEquals(activeBefore, repository.activeEndpoint)
            assertTrue(root.path.isNotBlank() || root.locationsCount > 0 || root.entriesCount > 0)
            val fixtureState = repository.state()
            val fixtureBoard = fixtureState.boardsList.first { board ->
                board.lanesList.any { lane -> lane.id == "todo" }
            }
            val fixtureProject = fixtureState.projectsList.first { it.id == fixtureBoard.projectId }

            val nonce = UUID.randomUUID().toString().take(8)
            val validation = ValidationCommand.newBuilder()
                .setName("Read-only check")
                .setExecutable("git")
                .addArguments("status")
                .addArguments("--short")
                .setTimeoutSeconds(30)
                .build()
            val created = repository.createProjectOn(
                endpoint.id,
                CreateProjectRequest.newBuilder()
                    .setMode("create")
                    .setPath("/tmp/dieter-android-project-$nonce")
                    .setName("Android project E2E $nonce")
                    .setBoardName("Main")
                    .setWorkflow("review")
                    .setBaseRemote("origin")
                    .setBaseBranch("main")
                    .addValidationCommands(validation)
                    .setRemotePublishMode("manual")
                    .build(),
            )
            projectId = created.project.id
            assertEquals(activeBefore, repository.activeEndpoint)
            assertEquals("main", created.project.baseBranch)
            assertEquals(listOf(validation), created.project.validationCommandsList)

            val updated = repository.updateProjectWorkspaceSettings(
                UpdateProjectWorkspaceSettingsRequest.newBuilder()
                    .setProjectId(created.project.id)
                    .setBaseRemote("upstream")
                    .setBaseBranch("main")
                    .addValidationCommands(validation.toBuilder().setTimeoutSeconds(45))
                    .build(),
            )
            assertEquals("upstream", updated.baseRemote)
            assertEquals("main", updated.baseBranch)
            assertEquals(45, updated.validationCommandsList.single().timeoutSeconds)

            val harness = repository.harnesses().harnessesList.first { it.id == "mock" }
            val card = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(fixtureProject.id)
                    .setBoardId(fixtureBoard.id)
                    .setLane("todo")
                    .setTitle("Android workspace admin E2E")
                    .setPrompt("Deferred workspace lifecycle fixture")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setWorkspaceMode("worktree")
                    .setWorkspaceBaseBranch("main")
                    .build(),
                chat = false,
            )
            cardId = card.id
            val workspace = repository.workspace(card.id)
            assertEquals(card.id, workspace.cardId)
            assertTrue(repository.projectWorkspaces(fixtureProject.id).workspacesList.any { it.cardId == card.id })

            var operation = repository.startGitOperation(card.id, "discard", workspace.revision)
            operation = withTimeout(30_000) {
                while (operation.status in setOf("queued", "running", "waiting_for_resolution")) {
                    delay(250)
                    operation = repository.gitOperation(operation.id)
                }
                operation
            }
            assertEquals(operation.error, "succeeded", operation.status)
            assertFalse(repository.projectWorkspaces(fixtureProject.id).workspacesList.any { it.cardId == card.id })
        } finally {
            cardId?.let { runCatching { repository.archiveCard(it, true) } }
            projectId?.let { runCatching { repository.archiveProject(it, true) } }
            repository.close()
        }
    }

    @Test
    fun queuedMessageRemovalReturnsAnEditableDraftEndToEnd() = runBlocking {
        val origin = isolatedOrigin()
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcDieterRepository(context)
        var cardId: String? = null
        try {
            connect(repository, origin, token)
            repository.prepareDaemon()
            val state = repository.state()
            val board = state.boardsList.first { it.lanesList.any { lane -> lane.id == "todo" } }
            val harness = repository.harnesses().harnessesList.first { it.id == "mock" }
            val card = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(board.projectId)
                    .setBoardId(board.id)
                    .setLane("todo")
                    .setTitle("Android queue edit E2E")
                    .setPrompt("mock-queue-hold")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setWorkspaceMode("project")
                    .build(),
                chat = false,
            )
            cardId = card.id
            repository.startCard(
                StartCardRequest.newBuilder()
                    .setCardId(card.id)
                    .setClientId("android-queue-e2e")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
            )
            withTimeout(15_000) {
                repository.watchConversation(card.id, 8).first { snapshot ->
                    snapshot.conversation.status == "running" || snapshot.detail.card.runtime == "running"
                }
            }

            val attachment = MessagePart.newBuilder()
                .setType("file")
                .setFilename("queued.txt")
                .setMediaType("text/plain")
                .setData(ByteString.copyFromUtf8("queued attachment"))
                .build()
            val messageId = "msg_android_queue_${UUID.randomUUID().toString().replace("-", "").take(12)}"
            val response = repository.sendMessage(
                SendMessageRequest.newBuilder()
                    .setCardId(card.id)
                    .addAllParts(
                        listOf(
                    MessagePart.newBuilder().setType("text").setText("Edit this queued follow-up").build(),
                    attachment,
                        ),
                    )
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setEffort(card.effort)
                    .putAllProviderOptions(card.providerOptionsMap)
                    .setClientId("android-queue-e2e")
                    .setCommandId(UUID.randomUUID().toString())
                    .setMessageId(messageId)
                    .build(),
            )
            assertTrue("The follow-up must be admitted to the running turn's queue", response.queued)
            assertEquals(messageId, response.messageId)
            val queued = withTimeout(10_000) {
                repository.watchConversation(card.id, 8).first { snapshot ->
                    snapshot.conversation.queueList.any { it.id == response.messageId }
                }.conversation.queueList.first { it.id == response.messageId }
            }
            val removed = repository.removeQueuedMessage(card.id, queued.id)
            assertEquals("Edit this queued follow-up", removed.partsList.first { it.type == "text" }.text)
            assertEquals("queued.txt", removed.partsList.first { it.type == "file" }.filename)
            assertEquals(harness.defaultModel, removed.selection.model)
            assertTrue(repository.conversation(card.id).conversation.queueList.none { it.id == queued.id })
        } finally {
            cardId?.let { id ->
                runCatching { repository.cancelCard(id) }
                runCatching { repository.archiveCard(id, true) }
            }
            repository.close()
        }
    }

    @Test
    fun disconnectedCardStartPersistsAndDrainsThroughTheRealGateway() = runBlocking {
        val origin = isolatedOrigin()
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcDieterRepository(context)
        val application = context.applicationContext as DieterApplication
        val manager = application.container.connectionManager
        var cardId: String? = null
        try {
            connect(repository, origin, token)
            repository.prepareDaemon()
            val state = repository.state()
            val board = state.boardsList.first { candidate ->
                candidate.lanesList.any { it.id.equals("todo", ignoreCase = true) } &&
                    candidate.lanesList.any { lane -> lane.id.equals("running", true) || lane.name.equals("running", true) }
            }
            val harness = repository.harnesses().harnessesList.first()
            val card = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(board.projectId)
                    .setBoardId(board.id)
                    .setLane("todo")
                    .setTitle("Android durable offline start ${UUID.randomUUID().toString().take(8)}")
                    .setPrompt("Reply with OFFLINE_START_OK.")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setWorkspaceMode("project")
                    .setClientId("android-offline-start-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = false,
            )
            cardId = card.id

            manager.repository.setAccessToken(origin, token)
            manager.updateEndpoints(listOf(origin))
            manager.connect()
            manager.onAppForegrounded(card.projectId)
            withTimeout(30_000) {
                manager.state.first { current ->
                    current.phase == ConnectionPhase.CONNECTED && current.cards.any { it.id == card.id }
                }
            }

            manager.disconnect()
            withTimeout(5_000) { manager.state.first { it.phase == ConnectionPhase.STOPPED } }
            val optimistic = manager.enqueueCardStart(card.id)
            assertEquals("starting", optimistic.runtime)
            assertTrue(card.id in manager.state.value.pendingCardIds)
            val durableEntry = DieterSyncStore(context).loadOutbox().single { it.optimisticId == card.id }
            assertEquals(OutboxKind.START_CARD, durableEntry.kind)
            assertEquals(card.id, StartCardRequest.parseFrom(durableEntry.request).cardId)

            manager.connect()
            manager.onAppForegrounded(card.projectId)
            val synchronized = withTimeout(30_000) {
                manager.state.first { current ->
                    current.cards.any { it.id == card.id && it.initialPromptSentAt.isNotBlank() } &&
                        card.id !in current.pendingCardIds
                }
            }
            assertTrue(synchronized.cards.first { it.id == card.id }.initialPromptSentAt.isNotBlank())
            assertTrue(DieterSyncStore(context).loadOutbox().none { it.optimisticId == card.id })
        } finally {
            cardId?.let { id ->
                runCatching { repository.cancelCard(id) }
                runCatching { repository.archiveCard(id, true) }
            }
            repository.close()
        }
    }

    @Test
    fun startAdmissionRoundTripsAndPreparesVisibleFixture() = runBlocking {
        val origin = isolatedOrigin()
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcDieterRepository(context)
        var transportCardId: String? = null
        try {
            val endpoint = connect(repository, origin, token)
            assertEquals("Gateway relay", repository.prepareDaemon())
            assertEquals("ok", repository.health().status)

            val frames = Channel<SyncFrame>(Channel.UNLIMITED)
            val syncJob = launch { repository.watchSync(conversationLimit = 0).collect(frames::send) }
            val bootstrap = withTimeout(10_000) {
                while (true) {
                    val frame = frames.receive()
                    if (frame.hasSnapshot()) return@withTimeout frame
                }
                error("unreachable")
            }
            assertEquals(0, bootstrap.snapshot.conversationsCount)

            val state = bootstrap.snapshot.state
            val board = state.boardsList.firstOrNull { candidate ->
                candidate.lanesList.any { it.id.equals("todo", ignoreCase = true) } &&
                    candidate.lanesList.any {
                        it.id.equals("running", ignoreCase = true) || it.name.equals("running", ignoreCase = true)
                    }
            } ?: error("The real workspace must have a board with Todo and Running lanes")
            val runningLane = board.lanesList.first {
                it.id.equals("running", ignoreCase = true) || it.name.equals("running", ignoreCase = true)
            }.id
            val harness = repository.harnesses().harnessesList.firstOrNull()
                ?: error("The real daemon must expose at least one harness")
            val nonce = UUID.randomUUID().toString().take(8)
            val transportCard = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(board.projectId)
                    .setBoardId(board.id)
                    .setLane("todo")
                    .setTitle("Android isolated start transport $nonce")
                    .setPrompt("Automated transport verification. Read only: do not edit files. Reply with E2E_OK.")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setWorkspaceMode("project")
                    .setClientId("android-isolated-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = false,
            )
            transportCardId = transportCard.id

            val createdDelta = withTimeout(10_000) {
                while (true) {
                    val frame = frames.receive()
                    if (frame.hasDelta() && frame.delta.cardsList.any { it.id == transportCard.id }) {
                        return@withTimeout frame
                    }
                }
                error("unreachable")
            }
            assertFalse(createdDelta.hasSnapshot())

            val commandId = UUID.randomUUID().toString()
            val request = StartCardRequest.newBuilder()
                .setCardId(transportCard.id)
                .setClientId("android-isolated-test")
                .setCommandId(commandId)
                .build()
            lateinit var response: com.dbpprt.dieter.v1.StartCardResponse
            val acknowledgementMillis = measureTimeMillis { response = repository.startCard(request) }
            assertTrue("Start acknowledgement took ${acknowledgementMillis}ms", acknowledgementMillis < 5_000)
            assertTrue(response.accepted)
            assertEquals(commandId, response.commandId)
            assertEquals(runningLane, response.card.lane)
            assertTrue(response.card.initialPromptSentAt.isNotBlank())

            val replay = repository.startCard(request)
            assertTrue(replay.replayed)
            assertEquals(response.card.id, replay.card.id)
            val conversation = withTimeout(10_000) { repository.watchConversation(transportCard.id, 8).first() }
            assertEquals(transportCard.id, conversation.detail.card.id)
            syncJob.cancel()

            runCatching { repository.cancelCard(transportCard.id) }
            repository.archiveCard(transportCard.id, true)
            transportCardId = null

            val fixture = repository.createConversation(
                CreateConversationRequest.newBuilder()
                    .setProjectId(board.projectId)
                    .setBoardId(board.id)
                    .setLane("todo")
                    .setTitle("Android start feedback E2E $nonce")
                    .setPrompt("Visible Android start-feedback verification. Read only: do not edit files. Reply with E2E_UI_OK.")
                    .setProvider(harness.id)
                    .setModel(harness.defaultModel)
                    .setDeferStart(true)
                    .setWorkspaceMode("project")
                    .setClientId("android-isolated-test")
                    .setCommandId(UUID.randomUUID().toString())
                    .build(),
                chat = false,
            )

            val application = context.applicationContext as DieterApplication
            val manager = application.container.connectionManager
            manager.repository.setAccessToken(origin, token)
            manager.updateEndpoints(listOf(origin))
            manager.connect()
            manager.onAppForegrounded(fixture.projectId)
            withTimeout(30_000) {
                manager.state.first { current ->
                    current.phase == ConnectionPhase.CONNECTED && current.cards.any { it.id == fixture.id }
                }
            }
            println(
                "DIETER_UI_FIXTURE card=${fixture.id} project=${fixture.projectId} " +
                    "board=${fixture.boardId} daemon=${endpoint.daemonId}",
            )
        } finally {
            transportCardId?.let { id ->
                runCatching { repository.cancelCard(id) }
                runCatching { repository.archiveCard(id, true) }
            }
            repository.close()
        }
    }

    @Test
    fun archiveVisibleFixtureAndRestoreProductionGateway() = runBlocking {
        val fixtureCardId = argument("fixtureCardId")
        val token = argument("isolatedGatewayToken")
        if (fixtureCardId.isNotBlank() && token.isNotBlank()) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val repository = GrpcDieterRepository(context)
            try {
                connect(repository, isolatedOrigin(), token)
                repository.prepareDaemon()
                runCatching { repository.cancelCard(fixtureCardId) }
                repository.archiveCard(fixtureCardId, true)
            } finally {
                repository.close()
            }
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val application = context.applicationContext as DieterApplication
        val manager = application.container.connectionManager
        manager.updateEndpoints(DIETER_ENDPOINTS)
        manager.connect()
        delay(1_000)
    }

    private suspend fun connect(
        repository: GrpcDieterRepository,
        origin: DieterEndpoint,
        token: String,
    ): DieterEndpoint {
        repository.setAccessToken(origin, token)
        repository.replaceEndpoints(listOf(origin))
        repository.selectEndpoint(origin)
        val daemon = repository.daemons().daemonsList.first { it.apiVersion == DIETER_API_VERSION }
        val endpoint = origin.copy(
            id = "${origin.credentialId}#${daemon.id}",
            label = daemon.name.ifBlank { daemon.id },
            daemonId = daemon.id,
            apiVersion = daemon.apiVersion,
        )
        repository.replaceEndpoints(listOf(endpoint))
        repository.selectEndpoint(endpoint)
        return endpoint
    }

    private fun isolatedOrigin(): DieterEndpoint = DieterEndpoint(
        id = "isolated_gateway_e2e",
        label = "Isolated Gateway E2E",
        host = argument("isolatedGatewayHost").ifBlank { "10.0.2.2" },
        port = argument("isolatedGatewayPort").toIntOrNull() ?: 14243,
        secure = false,
    )

    private fun argument(name: String): String =
        InstrumentationRegistry.getArguments().getString(name).orEmpty()
}
