package com.dbpprt.dieter.data

import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.settings.SharedKV
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.CreateProjectRequest
import com.dbpprt.dieter.v1.CreateTerminalRequest
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlin.system.measureTimeMillis

/**
 * Explicitly gated real-emulator coverage for an isolated gateway. It is not
 * part of the normal connected suite because it starts an actual local agent.
 */
@RunWith(AndroidJUnit4::class)
class IsolatedGatewayIntegrationTest {
    private var previousForceTURN: String? = null

    @org.junit.Before fun setFixtureTransportPolicy() {
        previousForceTURN = System.getProperty("dieter.test.forceTURN")
        System.setProperty("dieter.test.forceTURN", (argument("forceTURN") == "1").toString())
    }

    @org.junit.After fun restoreFixtureTransportPolicy() {
        previousForceTURN?.let { System.setProperty("dieter.test.forceTURN", it) }
            ?: System.clearProperty("dieter.test.forceTURN")
    }

    @Test
    fun webRTCControlCarriesRPCAndReportsICEPath() = runBlocking {
        assumeTrue("Requires the WebRTC fixture", argument("isolatedControlWebRTC") == "1")
        val token = argument("isolatedGatewayToken")
        assumeTrue(token.isNotBlank())
        val repository = GrpcDieterRepository(InstrumentationRegistry.getInstrumentation().targetContext)
        val expectedRoute = if (argument("forceTURN") == "1") "WebRTC · TURN" else "WebRTC · Direct"
        try {
            val endpoint = connect(repository, isolatedOrigin(), token)
            assertEquals(expectedRoute, repository.prepareDaemon())
            assertEquals(expectedRoute, repository.dataRoute())
            assertTrue(repository.state().projectsCount > 0)
            assertTrue(repository.relayState(endpoint).projectsCount > 0)
            // First cancels the watch. The next RPC must retain its transport.
            withTimeout(10_000) { repository.watchState().first() }
            assertTrue(repository.state().projectsCount > 0)
            exerciseSharedNavigation(repository)
            assertEquals(expectedRoute, repository.prepareDaemon())
            assertTrue(repository.state().projectsCount > 0)
        } finally { repository.close() }
    }

    @Test
    fun sharedNavigationCachesOfflineEditsAndDrainsThroughRealGateway() = runBlocking {
        val token = argument("isolatedGatewayToken")
        assumeTrue("Requires disposable gateway credentials", token.isNotBlank())
        val repository = GrpcDieterRepository(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            connect(repository, isolatedOrigin(), token)
            exerciseSharedNavigation(repository)
        } finally { repository.close() }
    }

    private suspend fun exerciseSharedNavigation(repository: GrpcDieterRepository) {
        val info = repository.listKV(com.dbpprt.dieter.v1.KVListRequest.newBuilder().setNamespace("navigation").build())
        val ref = com.dbpprt.dieter.v1.KVRef.newBuilder().setNamespace("navigation")
            .setKey("projects-folder.native-android.name").setAccount(info.account).build()
        val put = com.dbpprt.dieter.v1.KVPutRequest.newBuilder().setRef(ref)
            .setValueJson(ByteString.copyFromUtf8("\"Android RTC folder\""))
            .setDaemonId(info.daemonId).setOperationId(UUID.randomUUID().toString()).build()
        val written = repository.putKV(put)
        assertEquals(written.revision, repository.putKV(put).revision)
        val frame = withTimeout(10_000) {
            repository.watchKV(com.dbpprt.dieter.v1.KVWatchRequest.newBuilder().setNamespace("navigation").setAccount(info.account).build())
                .first { it.entriesList.any { entry -> entry.key == ref.key } }
        }
        assertEquals(written.revision, frame.entriesList.first { it.key == ref.key }.revision)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cacheA = "shared-kv-a-${UUID.randomUUID()}"
        val cacheB = "shared-kv-b-${UUID.randomUUID()}"
        val one = withContext(Dispatchers.Main) { SharedKV(context.getSharedPreferences(cacheA, 0)) }
        val two = withContext(Dispatchers.Main) { SharedKV(context.getSharedPreferences(cacheB, 0)) }
        var restored: SharedKV? = null
        try {
            withContext(Dispatchers.Main) { one.bind(repository); two.bind(repository) }
            withTimeout(10_000) {
                one.values.first { it[ref.key] == "\"Android RTC folder\"" }
                two.values.first { it[ref.key] == "\"Android RTC folder\"" }
            }
            val expansionKey = "projects-folder.native-android.expanded"
            withContext(Dispatchers.Main) { one.put(expansionKey, false) }
            withTimeout(10_000) {
                two.values.first { it[expansionKey] == "false" }
                one.status.first { it.pending == 0 }
            }
            withContext(Dispatchers.Main) { one.bind(null); one.put(expansionKey, true) }
            one.awaitPendingWrites()
            val restarted = withContext(Dispatchers.Main) { SharedKV(context.getSharedPreferences(cacheA, 0)) }
            restored = restarted
            restarted.awaitPendingWrites()
            assertEquals(1, restarted.status.value.pending)
            assertEquals("true", restarted.values.value[expansionKey])
            withContext(Dispatchers.Main) { restarted.bind(repository) }
            withTimeout(10_000) {
                two.values.first { it[expansionKey] == "true" }
                restarted.status.first { it.pending == 0 }
            }
            if (argument("sharedNavigationCrossClient") == "1") {
                assertEquals("\"Native shared navigation\"", two.values.value["projects-folder.native-shared.name"])
                assertEquals("false", two.values.value["projects-folder.native-shared.expanded"])
            }
        } finally {
            one.close(); two.close(); restored?.close()
            context.deleteSharedPreferences(cacheA)
            context.deleteSharedPreferences(cacheB)
        }
        if (argument("sharedNavigationCrossClient") == "1") {
            val sharedRef = ref.toBuilder().setKey("projects-folder.native-shared.name").build()
            val shared = repository.getKV(sharedRef)
            assertEquals("\"Native shared navigation\"", shared.valueJson.toStringUtf8())
            val expandedRef = ref.toBuilder().setKey("projects-folder.native-shared.expanded").build()
            val collapsed = repository.getKV(expandedRef)
            assertEquals("false", collapsed.valueJson.toStringUtf8())
            val updated = repository.putKV(com.dbpprt.dieter.v1.KVPutRequest.newBuilder().setRef(expandedRef)
                .setValueJson(ByteString.copyFromUtf8("true")).setExpectedRevision(collapsed.revision)
                .setDaemonId(info.daemonId).setOperationId(UUID.randomUUID().toString()).build())
            assertEquals("true", updated.valueJson.toStringUtf8())
        }
    }

    @Test
    fun terminalEditingControlBytesRoundTripThroughTheIsolatedGateway() = runBlocking {
        val origin = isolatedOrigin()
        val token = argument("isolatedGatewayToken")
        assumeTrue("Pass isolatedGatewayToken to run the isolated gateway test", token.isNotBlank())

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = GrpcDieterRepository(context)
        var terminalId: String? = null
        try {
            connect(repository, origin, token)
            repository.prepareDaemon()
            val project = repository.state().projectsList.first()
            val terminal = repository.createTerminal(
                CreateTerminalRequest.newBuilder()
                    .setProjectId(project.id)
                    .setName("android-control-input")
                    .setShell("sh")
                    .setWorkingDirectory(project.path)
                    .setColumns(92)
                    .setRows(26)
                    .build(),
            )
            terminalId = terminal.id

            repository.writeTerminal(
                terminal.id,
                "stty -echo; printf 'ANDROID_RAW_CONTROL_READY\\n'\n".encodeToByteArray(),
            )
            val ready = awaitTerminalOutput(repository, terminal.id, 0, "ANDROID_RAW_CONTROL_READY\r\n")
            val input = "printf '%s\\n' ANDROID_RAW_CONTROL_OKx".encodeToByteArray() +
                byteArrayOf(0x7f) + byteArrayOf('\n'.code.toByte())
            repository.writeTerminal(terminal.id, input)

            val output = awaitTerminalOutput(
                repository,
                terminal.id,
                ready.first,
                "ANDROID_RAW_CONTROL_OK\r\n",
            ).second
            assertFalse("DEL was rendered as visible text: $output", output.contains("^?"))
            assertFalse("DEL did not erase the preceding byte: $output", output.contains("ANDROID_RAW_CONTROL_OKx"))
        } finally {
            terminalId?.let { runCatching { repository.closeTerminal(it) } }
            repository.close()
        }
    }

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
            val incompatibleDaemon = repository.daemons().daemonsList.first { it.apiVersion != DIETER_API_VERSION }
            val incompatibleEndpoint = origin.copy(
                id = "${origin.credentialId}#${incompatibleDaemon.id}",
                label = incompatibleDaemon.name,
                daemonId = incompatibleDaemon.id,
                apiVersion = incompatibleDaemon.apiVersion,
            )
            repository.replaceEndpoints(listOf(endpoint, incompatibleEndpoint))
            val incompatible = runCatching { repository.listDirectoriesOn(incompatibleEndpoint.id) }.exceptionOrNull()
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
                    .setCheckoutId(created.project.checkoutsList.single().id)
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
        val originalConnection = SavedConnectionConfiguration(manager)
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
            originalConnection.restore()
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
        assumeTrue("Pass an explicit isolated fixture to clean up", fixtureCardId.isNotBlank() && token.isNotBlank())
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

    private suspend fun awaitTerminalOutput(
        repository: GrpcDieterRepository,
        terminalId: String,
        afterSequence: Long,
        marker: String,
    ): Pair<Long, String> {
        val output = ByteArrayOutputStream()
        val frame = withTimeout(15_000) {
            repository.watchTerminal(terminalId, afterSequence).first { frame ->
                output.write(frame.data.toByteArray())
                output.toString(Charsets.UTF_8.name()).contains(marker)
            }
        }
        return frame.sequence to output.toString(Charsets.UTF_8.name())
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
