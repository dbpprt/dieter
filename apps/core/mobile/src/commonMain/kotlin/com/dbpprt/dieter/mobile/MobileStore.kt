package com.dbpprt.dieter.mobile

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientSubscription
import com.dbpprt.dieter.core.client.Keyed
import com.dbpprt.dieter.core.terminals.TerminalScreen
import com.dbpprt.dieter.settings.DieterPalette
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The same typed core contract on Android/JVM and through the Apple byte bridge. */
interface MobileCore {
    suspend fun dispatch(command: Command): Result

    fun observe(slice: Slice, scope: String, receive: (Update) -> Unit): ClientSubscription
}

class RuntimeMobileCore(private val api: ClientApi) : MobileCore {
    override suspend fun dispatch(command: Command) = api.dispatch(command)

    override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
        api.observe(slice, scope, receive)
}

enum class MobileTab {
    BOARD,
    CHATS,
    MACHINES,
    INBOX,
    PROJECTS,
    TOOLS,
    FILES,
    SCHEDULES,
    TERMINALS,
    SCREENS,
    USAGE,
    SETTINGS,
    PROJECT_CHANGES,
}

class MobilePreferences(
    val read: (String) -> String? = { null },
    val write: (String, String) -> Unit = { _, _ -> },
)

data class MobileFileBuffer(val original: String, val text: String)

/** View lifetime and navigation only; the existing core decides all task behavior. */
class MobileStore(
    val core: MobileCore,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val preferences: MobilePreferences = MobilePreferences(),
) {
    // Explicit choices use the core's selection validation; null uses its remembered defaults.
    var agentSelection: com.dbpprt.dieter.api.v1.HarnessSelection? = null
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val commands = Mutex()
    private val inputCommands = Channel<Command>(64)
    val session = MutableStateFlow(SessionSlice())
    val workspace = MutableStateFlow(WorkspaceSlice())
    val outbox = MutableStateFlow(OutboxSlice())
    val board = MutableStateFlow(BoardViewSlice())
    val conversation = MutableStateFlow(ConversationSlice())
    val activity = MutableStateFlow(ActivitySlice())
    val navigation = MutableStateFlow(NavigationSlice())
    val chats = MutableStateFlow(ChatsSlice())
    val creationDefaults = MutableStateFlow(CreationSlice())
    val creationPreview = MutableStateFlow(CreationPreview())
    val selectedCheckout = MutableStateFlow("")
    val creationIntent = MutableStateFlow(CreationIntent())
    val files = MutableStateFlow(FilesSlice())
    val fileBuffers = MutableStateFlow<Map<String, MobileFileBuffer>>(emptyMap())
    val schedules = MutableStateFlow(SchedulesSlice())
    val review = MutableStateFlow(ReviewSlice())
    val projectChanges = MutableStateFlow(ProjectChangesSlice())
    val processes = MutableStateFlow(ProcessesSlice())
    val telemetry = MutableStateFlow(TelemetrySlice())
    val quotas = MutableStateFlow(QuotasSlice())
    val terminals = MutableStateFlow(TerminalOverviewSlice())
    val cardTerminals = MutableStateFlow(TerminalsSlice())
    val visibleTerminal = MutableStateFlow("")
    val terminalAcceptsInput = MutableStateFlow(false)
    internal val terminalKeys = MutableSharedFlow<TerminalKey>(extraBufferCapacity = 8)
    val terminalScreens = MutableStateFlow<Map<String, TerminalScreen>>(emptyMap())
    val screen = MutableStateFlow(ScreenSlice())
    internal val canvasActions = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val selectedScreen = MutableStateFlow("")
    val draftTexts = MutableStateFlow<Map<String, String>>(emptyMap())
    val palette = MutableStateFlow(DieterPalette.resolve(preferences.read("palette")))
    val appearance = MutableStateFlow(preferences.read("appearance") ?: "system")
    val tab = MutableStateFlow(MobileTab.INBOX)
    val creatingChat = MutableStateFlow(false)
    val detailTab = MutableStateFlow("Conversation")
    val selectedProject = MutableStateFlow("")
    val boardFilter = MutableStateFlow(BoardViewTarget())
    val selectedCard = MutableStateFlow("")
    val selectedBoard = MutableStateFlow("")
    val creating = MutableStateFlow(false)
    val signInUrl = MutableStateFlow("")
    val busy = MutableStateFlow(false)
    val error = MutableStateFlow("")
    private val subscriptions = mutableListOf<ClientSubscription>()
    private var conversationSubscription: ClientSubscription? = null
    private var conversationScope = ""
    private val resolvedScopes = mutableMapOf<String, String>()
    private var generation = 0
    private var closed = false
    private var previewJob: Job? = null
    private val pendingAgentChoices = mutableListOf<AgentChoice>()
    private val draftJobs = mutableMapOf<String, Job>()
    private val draftDaemons = mutableMapOf<String, String>()

    init {
        scope.launch {
            for (input in inputCommands) {
                try {
                    core.dispatch(input)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    error.value = failure.message ?: "Could not send input."
                }
            }
        }
        subscriptions +=
            observe(Slice.SLICE_SESSION, "") { update ->
                update.session?.let { session.value = it }
            }
        subscriptions +=
            observe(Slice.SLICE_WORKSPACE, "") { update ->
                update.workspace?.let { workspace.value = it }
                update.workspace_delta?.let { workspace.value = fold(workspace.value, it) }
            }
        subscriptions +=
            observe(Slice.SLICE_OUTBOX, "") { update ->
                update.outbox?.let { next ->
                    outbox.value = next
                    resolvedScopes.keys.retainAll(next.resolutions.values.toSet())
                    next.resolutions[selectedCard.value]?.let { resolved ->
                        // The core keeps the open local-ID scope alive as its server ID arrives.
                        // Reopening here lets asynchronous release of the old scope close that
                        // same resolved session. Update navigation and keep its observation.
                        if (resolved != selectedCard.value) {
                            resolvedScopes[resolved] = conversationScope
                            selectedCard.value = resolved
                        }
                    }
                    next.storage_error.takeIf { it.isNotEmpty() }?.let { error.value = it }
                    next.failures.values.firstOrNull()?.let { error.value = it }
                }
            }
        subscriptions +=
            observe(Slice.SLICE_BOARD_VIEW, BOARD_SCOPE) { update ->
                update.board_view?.let { board.value = it }
            }
        subscriptions +=
            observe(Slice.SLICE_ACTIVITY, "") {
                it.activity?.let { value -> activity.value = value }
            }
        subscriptions +=
            observe(Slice.SLICE_NAVIGATION, "") {
                it.navigation?.let { value -> navigation.value = value }
            }
        subscriptions +=
            observe(Slice.SLICE_CHATS, CHATS_SCOPE) {
                it.chats?.let { value -> chats.value = value }
            }
        subscriptions +=
            observe(Slice.SLICE_CREATION, "") {
                it.creation?.let { value ->
                    creationDefaults.value = value
                    if (tab.value == MobileTab.FILES && selectedCard.value.isEmpty()) bindFiles()
                    if (tab.value == MobileTab.PROJECT_CHANGES) bindProjectChanges()
                }
            }
        subscriptions +=
            observe(
                Slice.SLICE_CREATION_PREVIEW,
                FORM_SCOPE,
            ) {} // Responses are applied by the latest request below.
        subscriptions +=
            observe(Slice.SLICE_FILES, FILES_SCOPE) {
                it.files?.let { value ->
                    files.value =
                        if (value.document_unchanged) value.copy(document = files.value.document)
                        else value
                }
            }
        subscriptions +=
            observe(Slice.SLICE_SCHEDULES, SCHEDULES_SCOPE) {
                it.schedules?.let { value -> schedules.value = value }
            }
        subscriptions +=
            observe(Slice.SLICE_PROJECT_CHANGES, PROJECT_CHANGES_SCOPE) {
                it.project_changes?.let { value ->
                    projectChanges.value =
                        if (value.diff_unchanged)
                            value.copy(display_rows = projectChanges.value.display_rows)
                        else value
                }
            }
        subscriptions +=
            observe(Slice.SLICE_PROCESSES, PROCESSES_SCOPE) {
                it.processes?.let { value -> processes.value = value }
            }
        subscriptions +=
            observe(Slice.SLICE_REVIEW, REVIEW_SCOPE) {
                it.review?.let { value ->
                    review.value =
                        if (value.diff_unchanged)
                            value.copy(display_rows = review.value.display_rows)
                        else value
                }
            }
        subscriptions +=
            observe(Slice.SLICE_TELEMETRY, "") {
                it.telemetry?.let { value -> telemetry.value = value }
            }
        subscriptions +=
            observe(Slice.SLICE_QUOTAS, "") { it.quotas?.let { value -> quotas.value = value } }
        subscriptions +=
            observe(Slice.SLICE_TERMINALS, TERMINAL_SCOPE) { update ->
                update.terminals?.let { value ->
                    if (selectedCard.value.isNotEmpty() && detailTab.value == "Terminal") {
                        retainTerminalOutput(value.output, value.terminals.map { it.id })
                        visibleTerminal.value = value.selected_id
                        terminalAcceptsInput.value =
                            value.rows.firstOrNull { it.id == value.selected_id }?.accepts_input ==
                                true
                    }
                    cardTerminals.value = value.copy(output = emptyList())
                }
            }
        subscriptions +=
            observe(Slice.SLICE_TERMINAL_OVERVIEW, TERMINAL_SCOPE) { update ->
                update.terminal_overview?.let { value ->
                    if (selectedCard.value.isEmpty() || detailTab.value != "Terminal") {
                        // Reduce every output delta before publishing conflatable snapshots.
                        val next = terminalScreens.value.toMutableMap()
                        value.terminals?.output.orEmpty().forEach { output ->
                            val key =
                                value.entries
                                    .firstOrNull { it.terminal?.id == output.terminal_id }
                                    ?.id ?: output.terminal_id
                            val previous = next[key] ?: TerminalScreen.EMPTY
                            next[key] =
                                if (output.reset) previous.reset(output.data_)
                                else previous.append(output.data_)
                        }
                        next.keys.retainAll(value.entries.map { it.id }.toSet())
                        terminalScreens.value = next
                        visibleTerminal.value = value.selected_id
                        terminalAcceptsInput.value =
                            value.entries
                                .firstOrNull { it.id == value.selected_id }
                                ?.row
                                ?.accepts_input == true
                    }
                    terminals.value =
                        value.copy(terminals = value.terminals?.copy(output = emptyList()))
                }
            }
        subscriptions +=
            observe(Slice.SLICE_SCREEN, SCREEN_SCOPE) {
                it.screen?.let { value ->
                    screen.value =
                        if (value.cursor_image_unchanged)
                            value.copy(cursor_image = screen.value.cursor_image)
                        else value
                }
            }
        action {
            val loaded = core.dispatch(Command(list_drafts = ListDrafts())).drafts?.drafts.orEmpty()
            loaded.forEach {
                if (it.card_id !in draftDaemons) draftDaemons[it.card_id] = it.daemon_id
            }
            draftTexts.value = loaded.associate { it.card_id to it.text } + draftTexts.value
        }
    }

    fun setPalette(value: DieterPalette) {
        palette.value = value
        preferences.write("palette", value.slug)
    }

    fun setAppearance(value: String) {
        appearance.value = value
        preferences.write("appearance", value)
    }

    private fun retainTerminalOutput(output: List<TerminalOutput>, ids: List<String>) {
        val next = terminalScreens.value.toMutableMap()
        output.forEach { event ->
            val old = next[event.terminal_id] ?: TerminalScreen.EMPTY
            next[event.terminal_id] =
                if (event.reset) old.reset(event.data_) else old.append(event.data_)
        }
        next.keys.retainAll(ids.toSet())
        terminalScreens.value = next
    }

    fun syncFileBuffer(key: String, content: String) {
        if (key.isEmpty()) return
        val previous = fileBuffers.value[key]
        if (previous == null && fileBuffers.value.size >= 32) {
            val discard =
                fileBuffers.value.entries.firstOrNull { it.value.original == it.value.text }?.key
            if (discard != null) discardFileBuffer(discard)
            else {
                error.value = "Save or discard an open file before editing another."
                return
            }
        }
        if (previous == null || previous.original == previous.text) savedFileBuffer(key, content)
    }

    fun editFileBuffer(key: String, original: String, text: String) {
        if (key.isEmpty()) return
        val previous = fileBuffers.value[key]
        if (previous == null && fileBuffers.value.size >= 32) {
            error.value = "Save or discard an open file before editing another."
            return
        }
        fileBuffers.value =
            (fileBuffers.value + (key to MobileFileBuffer(previous?.original ?: original, text)))
    }

    fun savedFileBuffer(key: String, text: String) {
        fileBuffers.value = fileBuffers.value + (key to MobileFileBuffer(text, text))
    }

    fun discardFileBuffer(key: String) {
        fileBuffers.value = fileBuffers.value - key
    }

    fun setForeground(active: Boolean) = action {
        if (!active) flushDrafts()
        core.dispatch(Command(set_foreground = SetForeground(active)))
        if (selectedScreen.value.isNotEmpty())
            core.dispatch(
                Command(
                    screen =
                        ScreenCommand(
                            scope = SCREEN_SCOPE,
                            resume = if (active) Step() else null,
                            sleep = if (!active) Step() else null,
                        )
                )
            )
        if (
            tab.value == MobileTab.TERMINALS ||
                (selectedCard.value.isNotEmpty() && detailTab.value == "Terminal")
        )
            core.dispatch(
                Command(
                    terminals = TerminalsCommand(scope = TERMINAL_SCOPE, active = Toggle(active))
                )
            )
    }

    fun inputCommand(command: Command) {
        if (!closed && inputCommands.trySend(command).isFailure)
            error.value =
                "Input is arriving too quickly. Some input could not be sent; wait and try again."
    }

    fun terminalInput(data: ByteArray) =
        inputCommand(
            Command(
                terminals =
                    TerminalsCommand(
                        scope = TERMINAL_SCOPE,
                        input = TerminalInput(okio.ByteString.of(*data)),
                    )
            )
        )

    fun terminalGrid(columns: Int, rows: Int) =
        inputCommand(
            Command(
                terminals =
                    TerminalsCommand(scope = TERMINAL_SCOPE, grid = TerminalGrid(columns, rows))
            )
        )

    fun openNativeScreen(id: String) {
        selectedScreen.value = id
    }

    fun closeScreen() {
        command(Command(screen = ScreenCommand(scope = SCREEN_SCOPE, disconnect = Step())))
        selectedScreen.value = ""
    }

    fun navigate(value: MobileTab) {
        back()
        tab.value = value
        when (value) {
            MobileTab.FILES -> bindFiles()
            MobileTab.PROJECT_CHANGES -> bindProjectChanges()
            MobileTab.SCHEDULES -> {
                val projectId = currentProjectId()
                action {
                    core.dispatch(
                        Command(
                            schedules =
                                SchedulesCommand(
                                    scope = SCHEDULES_SCOPE,
                                    bind = ScheduleProject(projectId),
                                )
                        )
                    )
                    core.dispatch(
                        Command(
                            schedules = SchedulesCommand(scope = SCHEDULES_SCOPE, load = Step())
                        )
                    )
                }
            }
            MobileTab.TERMINALS ->
                command(
                    Command(
                        terminal_overview =
                            TerminalOverviewCommand(
                                scope = TERMINAL_SCOPE,
                                load = TerminalOverviewLoad(),
                            )
                    )
                )
            MobileTab.USAGE,
            MobileTab.INBOX -> command(Command(quotas = QuotasCommand(load = QuotasLoad())))
            else -> Unit
        }
    }

    fun currentProjectId() =
        selectedProject.value.ifEmpty {
            workspace.value.boards.firstOrNull { it.id == selectedBoard.value }?.project_id
                ?: workspace.value.projects.firstOrNull()?.id.orEmpty()
        }

    fun filterBoard(target: BoardViewTarget) {
        boardFilter.value = target
        command(Command(board_view = BoardViewCommand(scope = BOARD_SCOPE, bind = target)))
    }

    fun newConversation(chat: Boolean = false) {
        pendingAgentChoices.clear()
        creatingChat.value = chat
        creating.value = true
        preview(
            CreationIntent(
                project_id = currentProjectId(),
                board_id = selectedBoard.value,
                selection = agentSelection,
            )
        )
    }

    fun preview(intent: CreationIntent, choice: AgentChoice? = null) {
        choice?.let { pendingAgentChoices += it }
        creationIntent.value = intent
        previewJob?.cancel()
        previewJob = scope.launch {
            delay(100)
            try {
                val choices = pendingAgentChoices.toList()
                var resolvedIntent = intent
                var response: CreationPreview? = null
                for (agentChoice in if (choices.isEmpty()) listOf(null) else choices) {
                    response =
                        core
                            .dispatch(
                                Command(
                                    creation_preview =
                                        CreationPreviewCommand(
                                            scope = FORM_SCOPE,
                                            intent = resolvedIntent,
                                            chat = creatingChat.value,
                                            choice = agentChoice,
                                        )
                                )
                            )
                            .creation_preview
                    ensureActive()
                    resolvedIntent = response?.intent ?: resolvedIntent
                }
                ensureActive()
                if (response != null) {
                    creationPreview.value = response
                    creationIntent.value = response.intent ?: intent
                    repeat(choices.size) {
                        if (pendingAgentChoices.isNotEmpty()) pendingAgentChoices.removeAt(0)
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                error.value = failure.message ?: "Unable to preview the task."
            }
        }
    }

    suspend fun submitCreation(intent: CreationIntent): String =
        core
            .dispatch(
                Command(
                    create_conversation =
                        CreateConversation(chat = creatingChat.value, intent = intent)
                )
            )
            .card
            ?.id ?: error("The core returned no conversation.")

    fun command(command: Command) = action { core.dispatch(command) }

    fun saveDraft(id: String, text: String) {
        draftTexts.value = draftTexts.value + (id to text)
        val daemon = conversation.value.daemon_id
        draftDaemons[id] = daemon
        draftJobs.remove(id)?.cancel()
        draftJobs[id] = scope.launch {
            delay(300)
            try {
                core.dispatch(
                    Command(
                        set_draft_text = SetDraftText(daemon_id = daemon, card_id = id, text = text)
                    )
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                error.value = failure.message ?: "Unable to save the draft."
            }
        }
    }

    fun bindProjectChanges() {
        val project = workspace.value.projects.firstOrNull { it.id == currentProjectId() } ?: return
        val checkout =
            project.checkouts.firstOrNull {
                it.id ==
                    selectedCheckout.value.ifEmpty {
                        creationDefaults.value.checkouts[project.id].orEmpty()
                    }
            } ?: project.checkouts.singleOrNull() ?: return
        action {
            core.dispatch(
                Command(
                    project_changes =
                        ProjectChangesCommand(
                            scope = PROJECT_CHANGES_SCOPE,
                            bind =
                                ProjectChangesTarget(
                                    project.id,
                                    checkout.id,
                                    checkout.daemon_id,
                                    true,
                                ),
                        )
                )
            )
            core.dispatch(
                Command(
                    project_changes =
                        ProjectChangesCommand(scope = PROJECT_CHANGES_SCOPE, active = Toggle(true))
                )
            )
        }
    }

    fun bindFiles(card: Boolean = false) {
        val project = workspace.value.projects.firstOrNull { it.id == currentProjectId() }
        val checkout =
            project?.checkouts?.firstOrNull {
                it.id ==
                    selectedCheckout.value.ifEmpty {
                        creationDefaults.value.checkouts[project.id].orEmpty()
                    }
            } ?: project?.checkouts?.singleOrNull()
        if (!card && checkout == null) return
        val target =
            FilesTarget(
                daemon_id =
                    if (card) conversation.value.daemon_id else checkout?.daemon_id.orEmpty(),
                project_id =
                    if (card) conversation.value.card?.project_id.orEmpty()
                    else project?.id.orEmpty(),
                checkout_id = if (card) "" else checkout?.id.orEmpty(),
                card_id = if (card) selectedCard.value else "",
            )
        action {
            core.dispatch(Command(files = FilesCommand(scope = FILES_SCOPE, bind = target)))
            core.dispatch(Command(files = FilesCommand(scope = FILES_SCOPE, load = FilesPath())))
        }
    }

    fun selectDetail(value: String) {
        detailTab.value = value
        if (value == "Processes")
            command(
                Command(
                    processes =
                        ProcessesCommand(
                            scope = PROCESSES_SCOPE,
                            bind =
                                ProcessesTarget(
                                    conversation.value.daemon_id,
                                    currentProjectId(),
                                    selectedCard.value,
                                    true,
                                ),
                        )
                )
            )
        if (value == "Changes")
            command(
                Command(
                    review =
                        ReviewCommand(
                            scope = REVIEW_SCOPE,
                            bind =
                                ReviewTarget(
                                    card_id = selectedCard.value,
                                    daemon_id = conversation.value.daemon_id,
                                ),
                        )
                )
            )
        if (value == "Files") bindFiles(card = true)
        if (value == "Terminal")
            command(
                Command(
                    terminals =
                        TerminalsCommand(
                            scope = TERMINAL_SCOPE,
                            bind =
                                TerminalTarget(
                                    daemon_id = conversation.value.daemon_id,
                                    kind = TerminalTarget.Kind.KIND_CARD,
                                    project_id = conversation.value.card?.project_id.orEmpty(),
                                    card_id = selectedCard.value,
                                ),
                        )
                )
            )
    }

    private fun observe(slice: Slice, key: String, receive: (Update) -> Unit) =
        core.observe(slice, key) { update ->
            scope.launch {
                if (!closed) {
                    update.failure?.let { error.value = it.message }
                    receive(update)
                }
            }
        }

    fun chooseBoard(id: String) {
        selectedBoard.value = id
        val project = workspace.value.boards.firstOrNull { it.id == id }?.project_id.orEmpty()
        if (project != selectedProject.value) selectedCheckout.value = ""
        selectedProject.value = project
        filterBoard(BoardViewTarget(board_id = id))
    }

    fun openCard(requested: String) {
        val id = outbox.value.resolutions[requested] ?: requested
        if (id == selectedCard.value) return
        generation += 1
        val current = generation
        conversationSubscription?.close()
        conversation.value = ConversationSlice(card_id = id, loading = true)
        selectedCard.value = id
        conversationScope = resolvedScopes[id] ?: id
        creating.value = false
        detailTab.value = "Conversation"
        conversationSubscription =
            observe(Slice.SLICE_CONVERSATION, conversationScope) { update ->
                if (current == generation && !closed) {
                    update.conversation?.let { conversation.value = it }
                    update.conversation_delta?.let {
                        conversation.value = fold(conversation.value, it)
                    }
                    update.failure?.let { error.value = it.message }
                }
            }
        action {
            core.dispatch(Command(set_visible_conversation = SetVisibleConversation(card_id = id)))
        }
    }

    fun back() {
        generation += 1
        conversationSubscription?.close()
        conversationSubscription = null
        selectedCard.value = ""
        creating.value = false
        action { core.dispatch(Command(set_visible_conversation = SetVisibleConversation())) }
    }

    suspend fun create(title: String, prompt: String, run: Boolean): String {
        val destination =
            workspace.value.boards.firstOrNull { it.id == selectedBoard.value }
                ?: workspace.value.boards.firstOrNull()
                ?: error("Choose a board first.")
        val result =
            core.dispatch(
                Command(
                    create_conversation =
                        CreateConversation(
                            intent =
                                CreationIntent(
                                    project_id = destination.project_id,
                                    board_id = destination.id,
                                    title = title,
                                    prompt = prompt,
                                    selection = agentSelection,
                                    lane = if (run) "running" else "todo",
                                    workspace_mode = "project",
                                )
                        )
                )
            )
        return result.card?.id ?: error("The core returned no task.")
    }

    suspend fun send(
        text: String,
        cardId: String = selectedCard.value,
        parts: List<MessagePart> = emptyList(),
    ) {
        core.dispatch(
            Command(send_message = SendMessage(card_id = cardId, text = text, parts = parts))
        )
        saveDraft(cardId, "")
    }

    fun move(lane: String) {
        val id = selectedCard.value
        action { core.dispatch(Command(move_card = MoveCard(card_id = id, lane = lane))) }
    }

    fun stop() {
        val id = selectedCard.value
        action { core.dispatch(Command(cancel_card = CancelCard(card_id = id))) }
    }

    fun start() {
        val id = selectedCard.value
        action { core.dispatch(Command(start_card = StartCard(card_id = id))) }
    }

    fun signIn(url: String) = action {
        signInUrl.value =
            core
                .dispatch(Command(begin_sign_in = BeginSignIn(url)))
                .sign_in_started
                ?.authorize_url
                .orEmpty()
    }

    fun completeSignIn(url: String) = action {
        core.dispatch(Command(complete_sign_in = CompleteSignIn(url)))
    }

    fun retry() = action { core.dispatch(Command(reconnect = Reconnect())) }

    fun loadEarlier() {
        val id = selectedCard.value
        action { core.dispatch(Command(load_earlier_messages = LoadEarlierMessages(card_id = id))) }
    }

    fun retryTurn() {
        val id = selectedCard.value
        action { core.dispatch(Command(retry_failed_turn = RetryFailedTurn(card_id = id))) }
    }

    fun action(block: suspend () -> Unit) {
        if (closed) return
        scope.launch {
            commands.withLock {
                busy.value = true
                error.value = ""
                try {
                    block()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    error.value = failure.message ?: "The action failed."
                } finally {
                    busy.value = false
                }
            }
        }
    }

    suspend fun flushDrafts() {
        draftJobs.values.forEach { it.cancel() }
        draftJobs.clear()
        draftTexts.value.forEach { (id, text) ->
            val daemon = draftDaemons[id].orEmpty()
            if (daemon.isNotEmpty())
                core.dispatch(Command(set_draft_text = SetDraftText(daemon, id, text)))
        }
    }

    fun close() {
        if (closed) return
        closed = true
        generation += 1
        conversationSubscription?.close()
        subscriptions.forEach(ClientSubscription::close)
        inputCommands.close()
        scope.cancel()
    }

    companion object {
        const val BOARD_SCOPE = "compose-mobile-board"
        const val CHATS_SCOPE = "compose-mobile-chats"
        const val FORM_SCOPE = "compose-mobile-creation"
        const val FILES_SCOPE = "compose-mobile-files"
        const val SCHEDULES_SCOPE = "compose-mobile-schedules"
        const val REVIEW_SCOPE = "compose-mobile-review"
        const val TERMINAL_SCOPE = "compose-mobile-terminals"
        const val PROJECT_CHANGES_SCOPE = "compose-mobile-project-changes"
        const val PROCESSES_SCOPE = "compose-mobile-processes"
        const val SCREEN_SCOPE = "compose-mobile-screen"
    }
}

// Snapshot folding is UI protocol plumbing. No ordering or business policy lives here.
private fun fold(base: WorkspaceSlice, delta: WorkspaceDelta) =
    base.copy(
        projects = delta.projects,
        boards = delta.boards,
        cards =
            Keyed.apply(
                base.cards,
                delta.upserted_cards,
                delta.removed_card_ids,
                delta.card_order.takeIf { delta.order_changed },
                Card::id,
            ),
        pending_card_ids = delta.pending_card_ids,
        loaded = delta.loaded,
        retired_boards = delta.retired_boards,
        board_attention = delta.board_attention,
        project_hosts = delta.project_hosts,
    )

private fun fold(base: ConversationSlice, delta: ConversationDelta) =
    base.copy(
        card = delta.card,
        conversation = delta.conversation,
        messages =
            Keyed.apply(
                base.messages,
                delta.upserted_messages,
                delta.removed_message_ids,
                delta.message_order.takeIf { delta.order_changed },
                UiMessage::id,
            ),
        loading = delta.loading,
        syncing = delta.syncing,
        error = delta.error,
        pending = delta.pending,
        has_earlier = delta.has_earlier,
        loading_earlier = delta.loading_earlier,
        browsing_earlier = delta.browsing_earlier,
        retrying = delta.retrying,
        refreshed_at_millis = delta.refreshed_at_millis,
        turn_failure = delta.turn_failure,
        project = delta.project,
        board = delta.board,
        page = delta.page,
        card_id = delta.card_id.ifEmpty { base.card_id },
        daemon_id = delta.daemon_id,
        earlier_count = delta.earlier_count,
        state = delta.state,
        timeline =
            Keyed.apply(
                base.timeline,
                delta.upserted_timeline,
                delta.removed_timeline_ids,
                delta.timeline_order.takeIf { delta.timeline_order_changed },
                TimelineItem::id,
            ),
        unattached_plan_ids = delta.unattached_plan_ids,
    )
