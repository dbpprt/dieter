package com.dbpprt.dieter.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.api.v1.ReadFileRequest
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.ScheduleDraft
import com.dbpprt.dieter.api.v1.Settings
import com.dbpprt.dieter.api.v1.ToolOutput
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.board.DropAnchors
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.composition.ConversationDraft
import com.dbpprt.dieter.core.composition.ConversationDraftEditor
import com.dbpprt.dieter.core.composition.Creation
import com.dbpprt.dieter.core.composition.CreationInput
import com.dbpprt.dieter.core.composition.DraftKey
import com.dbpprt.dieter.core.composition.TaskDraftEditor
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.composition.ready
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.core.connection.Availability
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.connection.ConnectionPrompt
import com.dbpprt.dieter.core.conversation.ConversationSession
import com.dbpprt.dieter.core.conversation.ConversationView
import com.dbpprt.dieter.core.files.Files
import com.dbpprt.dieter.core.files.FilesTarget
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.navigation.BoardSelection
import com.dbpprt.dieter.core.navigation.BoardSelections
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.presentation.ConversationPresentation
import com.dbpprt.dieter.core.presentation.ConversationPresenter
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.core.terminals.NewTerminal
import com.dbpprt.dieter.core.terminals.TerminalScope
import com.dbpprt.dieter.core.terminals.TerminalScopeKind
import com.dbpprt.dieter.core.terminals.Terminals
import com.dbpprt.dieter.core.workspace.ChangeSection
import com.dbpprt.dieter.core.workspace.DiffLine
import com.dbpprt.dieter.core.workspace.MergeStrategy
import com.dbpprt.dieter.core.workspace.ProjectChanges
import com.dbpprt.dieter.core.workspace.ProjectWorkspaceSettings
import com.dbpprt.dieter.core.workspace.ValidationCommandDraft
import com.dbpprt.dieter.core.workspace.WorkspaceReview
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.DieterPalette
import com.dbpprt.dieter.sharedcore.ConnectionPolicy
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Platform services the view model needs from the app. */
interface AppHost {
    fun openUrl(url: String)
}

/**
 * The Android presentation of the shared core. Every decision about
 * connectivity, sync, delivery, conversations, and features is the core's;
 * this class maps core state into [DieterUiState] and keeps UI-local state
 * (destination, open surfaces, selection, the connection sheet).
 */
class DieterViewModel internal constructor(
    internal val core: CoreRuntime,
    private val appPreferences: AppPreferences,
    private val policy: ConnectionPolicy,
    private val host: AppHost,
    internal val taskCaptures: TaskCaptureStore? = null,
) : ViewModel(), FolderEditor {
    private val _state = MutableStateFlow(DieterUiState())
    val state: StateFlow<DieterUiState> = _state.asStateFlow()

    private val terminals: Terminals = core.terminals()
    private val review: WorkspaceReview = core.workspaceReview()
    private val projectChangesController: ProjectChanges = core.projectChanges()
    private val files: Files = core.files()

    private var foreground = false
    private var session: ConversationSession? = null
    private var conversationJob: Job? = null

    /** The open conversation's draft; the composer types into it directly, never waiting on the core. */
    private var composer: ConversationDraftEditor? = null
    private var machineListJob: Job? = null
    private var connectionDialogJob: Job? = null
    private val connectionPrompt = ConnectionPrompt()
    private var layout = NavigationLayout(emptyMap())
    private var pendingProjectCreation: String? = null

    internal var captureChooserVisible by mutableStateOf(false)

    /** The task draft being written: a share or capture, or the open board's quick task and editor. */
    internal var activeCapture by mutableStateOf<TaskDraftEditor?>(null)
    internal var quickTaskOpen by mutableStateOf(false)

    init {
        collect(appPreferences.palette) { palette -> copy(palette = palette) }
        collect(appPreferences.showReasoningTraces) { copy(showReasoningTraces = it) }
        collect(appPreferences.chatsPaneLeadingFraction) { copy(chatsPaneLeadingFraction = it) }
        collect(appPreferences.activityPaneLeadingFraction) { copy(activityPaneLeadingFraction = it) }
        collect(appPreferences.projectsPaneLeadingFraction) { copy(projectsPaneLeadingFraction = it) }
        collect(appPreferences.boardPaneLeadingFraction) { copy(boardPaneLeadingFraction = it) }
        collect(policy.mode) { copy(backgroundSyncMode = it) }
        collect(core.accounts.state) { accounts ->
            copy(
                gateways = accounts.gateways,
                activeGatewayId = accounts.active.origin,
                endpoint = accounts.active.httpBase,
                desiredConnected = accounts.wantsConnection,
                signedIn = core.credentials.token(accounts.active) != null,
            )
        }
        viewModelScope.launch {
            core.connection.state.collect { connection ->
                val previous = _state.value.connectionPhase
                connectionPrompt.phaseChanged(previous, connection.phase, Clock.System.now())
                _state.update {
                    it.copy(
                        connectionPhase = connection.phase,
                        connectionError = connection.error,
                        signedIn = core.credentials.token(core.accounts.state.value.active) != null,
                    )
                }
                reconcileConnectionDialog()
                if (connection.phase == ConnectionPhase.CONNECTED && previous != ConnectionPhase.CONNECTED) onConnected()
            }
        }
        collect(core.connection.feedStatus) { feed -> copy(lastConnectedAtMillis = feed.lastAppliedAt?.toEpochMilliseconds()) }
        viewModelScope.launch {
            combine(core.connection.machines, core.sessions.routes, core.connection.state, core.workspace.state, core.connection.freshness) { machines, routes, connection, workspace, freshness ->
                val now = machines.evaluatedAt
                val endpoints = machines.all.map { machine -> MachineRows.of(machine, machine.online(now), routes[machine.id], connection.attachedMachineId) }
                val byId = endpoints.associateBy { it.id }
                val replicas = workspace.projectReplicas.mapValues { (_, daemonId) ->
                    val machine = byId[daemonId]
                    ProjectReplica(daemonId, daemonId, machine?.label ?: daemonId, machine?.online == true)
                }
                val warnings = MachineRows.syncWarnings(endpoints, freshness, connection.phase == ConnectionPhase.CONNECTED, Clock.System.now())
                Triple(endpoints, replicas, warnings)
            }.collect { (endpoints, replicas, warnings) ->
                _state.update { it.copy(endpointConnections = endpoints, projectReplicas = replicas, peerSyncWarnings = warnings) }
                refreshHarnesses()
            }
        }
        viewModelScope.launch {
            combine(core.workspace.state, core.navigationLayout()) { view, layout -> view to layout }.collect { (view, layout) ->
                this@DieterViewModel.layout = layout
                _state.update { current ->
                    val projects = layout.orderedProjects(view.projects)
                    val selection = BoardSelections.resolve(
                        projects, view.boards, view.retiredBoards,
                        BoardSelection(current.selectedProjectId, current.selectedBoardId, current.selectedLane),
                    )
                    val projectId = selection.projectId
                    val boards = view.boards[projectId].orEmpty()
                    current.copy(
                        projects = projects,
                        spaceBoards = view.boards.values.flatten(),
                        spaceCards = view.cards.values.flatten(),
                        chats = view.chats,
                        retiredBoards = view.retiredBoards,
                        boards = boards,
                        cards = view.cards[projectId].orEmpty(),
                        selectedProjectId = projectId,
                        selectedBoardId = selection.boardId,
                        selectedLane = selection.lane,
                        loading = Availability.loading(current.desiredConnected, view.loaded, current.connectionPhase),
                        pinnedProjectOrder = layout.pinnedProjects(projects.map(Project::id)),
                        projectFolders = layout.folders(FolderScope.PROJECTS),
                        chatFolders = layout.folders(FolderScope.CHATS),
                        collapsedChatProjectIds = projects.map(Project::id).filterTo(mutableSetOf(), layout::chatSectionCollapsed),
                        expandedChatProjectIds = projects.map(Project::id).filterTo(mutableSetOf(), layout::chatsShowAll),
                        pinnedChatOrder = layout.pinnedChats(view.chats.filter(Card::pinned)).map(Card::id),
                        navigationLayout = layout,
                    )
                }
            }
        }
        collect(core.navigationKv.status) { status ->
            copy(navigationPendingCount = status.pending, navigationSyncError = status.localError ?: status.deliveryError ?: status.watchError)
        }
        viewModelScope.launch {
            core.outbox.view.collect { outbox ->
                val selected = _state.value.selectedCardId
                val resolved = selected?.let(outbox::resolve)
                _state.update {
                    it.copy(
                        pendingCardIds = outbox.pendingCardIds,
                        pendingMessageIds = outbox.pendingMessageIds,
                        acceptedOutboxIds = outbox.acceptedIds,
                        failedOutboxIds = outbox.failedIds,
                        machineOutboxSummaries = outbox.machines,
                        selectedCardId = resolved ?: it.selectedCardId,
                    )
                }
            }
        }
        collect(core.board.view) { board ->
            copy(cardOperations = board.operations, cardOperationErrors = board.errors, pendingCardMoves = board.moves)
        }
        collect(core.quotas.view) { quotas ->
            copy(
                providerQuotaGroups = quotas.groups,
                providerQuotasLoading = quotas.loading,
                providerQuotaError = quotas.error,
                providerQuotaMutatingAccounts = quotas.mutating,
            )
        }
        viewModelScope.launch { core.activity().collect { items -> _state.update { it.copy(activityItems = items) } } }
        viewModelScope.launch { core.metadata.machines.collect { refreshHarnesses() } }
        collect(core.schedules.view) { copy(scheduleWorkspace = it) }
        collect(terminals.view) { copy(terminalWorkspace = it) }
        collect(review.view) { copy(workspaceReview = it) }
        collect(projectChangesController.view) { copy(projectChanges = it) }
        collect(core.projectWorkspaces.view) { workspaces ->
            copy(
                projectWorkspaces = workspaces.workspaces,
                projectWorkspacesLoading = workspaces.loading,
                projectWorkspaceOperations = workspaces.pending,
                projectWorkspaceErrors = workspaces.errors,
            )
        }
        viewModelScope.launch {
            files.view.collect { view ->
                _state.update { current ->
                    current.copy(
                        filePath = view.directory,
                        files = view.entries,
                        showHiddenFiles = view.showHidden,
                        fileDocument = view.document,
                        fileDraft = view.draft,
                        fileDirty = view.dirty,
                        fileConflict = view.conflict,
                        error = view.listingError ?: view.documentError ?: current.error,
                    )
                }
            }
        }
        collect(core.telemetry.view) { telemetry ->
            copy(
                machineSnapshots = telemetry.machines,
                machineOperationInFlight = telemetry.operationPending,
                machineOperationMessage = telemetry.operationResult ?: machineOperationMessage,
            )
        }
        _state.update { it.copy(notificationSettings = NotificationSettings.load(core.platform.settings)) }
        _state.update { it.copy(notificationBoardIds = it.notificationSettings.boardIds) }
    }

    private fun <T> collect(flow: StateFlow<T>, apply: DieterUiState.(T) -> DieterUiState) {
        viewModelScope.launch { flow.collect { value -> _state.update { it.apply(value) } } }
    }

    // --- Core calls ---------------------------------------------------------------------

    /** Runs [block] on the core dispatcher; failures surface as the screen error. */
    private fun launchCore(report: Boolean = true, block: suspend CoroutineScope.() -> Unit): Job = viewModelScope.launch {
        try {
            core.onCore(block)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            if (report) _state.update { it.copy(error = Failures.message(error)) }
        }
    }

    /** A user action: shows progress, serializes nothing, and reports its failure. */
    private fun action(onFinished: () -> Unit = {}, block: suspend CoroutineScope.() -> Unit): Job = viewModelScope.launch {
        _state.update { it.copy(working = true, error = null) }
        try {
            core.onCore(block)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            _state.update { it.copy(error = Failures.message(error)) }
        } finally {
            _state.update { it.copy(working = false) }
            onFinished()
        }
    }

    // --- Lifecycle ------------------------------------------------------------------------

    fun start() {
        if (foreground) return
        foreground = true
        policy.setForeground(true)
        launchCore(report = false) {
            core.quotas.load(refresh = false)
            terminals.setActive(_state.value.destination == Destination.TERMINALS)
            review.setActive(_state.value.selectedCardId != null)
            projectChangesController.setActive(_state.value.destination == Destination.FILES && _state.value.projectFilesMode == "changes")
        }
        when (_state.value.destination) {
            Destination.TERMINALS -> loadTerminals()
            Destination.MACHINES -> {
                refreshMachines()
                _state.value.selectedMachineId?.let { launchCore { core.telemetry.select(it, active = true) } }
            }
            else -> Unit
        }
        reconcileConnectionDialog()
    }

    fun stop() {
        taskCaptures?.flushAll()
        foreground = false
        policy.setForeground(false)
        machineListJob?.cancel()
        connectionDialogJob?.cancel()
        launchCore(report = false) {
            core.drafts.flush()
            terminals.setActive(false)
            review.setActive(false)
            projectChangesController.setActive(false)
            core.telemetry.select(core.telemetry.view.value.daemonId, active = false)
            // Quotas belong to the app-scoped core. Its connection lifecycle
            // pauses them; leaving this screen must not pause a widget refresh.
        }
    }

    private fun onConnected() {
        launchCore(report = false) { core.quotas.load(refresh = false) }
        when (_state.value.destination) {
            Destination.TERMINALS -> if (_state.value.terminals.isEmpty()) loadTerminals()
            Destination.FILES -> if (_state.value.projectFilesMode == "changes") loadProjectChanges() else loadFiles()
            Destination.SCHEDULES -> refreshSchedules()
            Destination.MACHINES -> refreshMachines()
            else -> Unit
        }
    }

    override fun onCleared() {
        conversationJob?.cancel()
        session?.cardId?.let { id -> viewModelScope.launch { runCatching { core.closeConversation(id) } } }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    // --- Connection and gateways ---------------------------------------------------------

    fun refresh() {
        if (_state.value.desiredConnected) launchCore { core.connection.restart() } else connect()
    }

    fun connect() {
        connectionPrompt.connecting()
        launchCore { core.setConnected(true) }
    }

    fun signIn() = action {
        val url = core.beginSignIn(core.accounts.state.value.active)
        host.openUrl(url)
    }

    fun signOut() = action { core.signOut() }

    fun disconnect() {
        connectionDialogJob?.cancel()
        connectionPrompt.disconnected()
        closeDetail()
        launchCore { core.setConnected(false) }
        _state.update { it.copy(connectionDialogVisible = true, desiredConnected = false, loading = false) }
    }

    fun setBackgroundSyncMode(mode: BackgroundMode) = policy.setMode(mode)

    fun setPalette(palette: DieterPalette) = appPreferences.setPalette(palette)

    fun setShowReasoningTraces(show: Boolean) = appPreferences.setShowReasoningTraces(show)

    private fun updateNotificationSettings(change: (NotificationSettings) -> NotificationSettings) {
        val next = change(_state.value.notificationSettings)
        next.save(core.platform.settings)
        _state.update { it.copy(notificationSettings = next, notificationBoardIds = next.boardIds) }
    }

    fun setSelectedBoardNotificationsEnabled(enabled: Boolean) = setNotificationBoardEnabled(_state.value.selectedBoardId, enabled)

    fun setNotificationBoardEnabled(boardId: String, enabled: Boolean) {
        if (boardId.isBlank()) return
        updateNotificationSettings { it.copy(boardIds = if (enabled) it.boardIds + boardId else it.boardIds - boardId) }
    }

    fun setNotificationBoardIds(boardIds: Set<String>) = updateNotificationSettings { it.copy(boardIds = boardIds.filterTo(mutableSetOf(), String::isNotBlank)) }

    fun setNotificationSettings(settings: NotificationSettings) = updateNotificationSettings { settings.copy(boardIds = it.boardIds) }

    /** Replaces the gateway list; plaintext is only allowed on loopback. */
    fun updateConnectionTargets(gateways: List<Gateway>, activeGatewayId: String) = action {
        core.setGateways(gateways, activeGatewayId)
    }

    fun resetConnectionTargets() = action { core.setGateways(listOf(Gateway.DEFAULT), Gateway.DEFAULT.origin) }

    fun selectGateway(origin: String) = launchCore { core.selectGateway(origin) }

    fun cleanSync() = action { core.resync() }

    fun showConnectionDialog() {
        connectionPrompt.show()
        _state.update { it.copy(connectionDialogVisible = true) }
    }

    fun showConnectionDialogIfNeeded() {
        val current = _state.value
        connectionPrompt.showIfNeeded(current.desiredConnected, current.connectionPhase, current.hasCachedWorkspace)
        _state.update { it.copy(connectionDialogVisible = connectionPrompt.visible) }
    }

    fun openAppSettingsFromConnection() {
        connectionPrompt.leaveForSettings(_state.value.connectionPhase)
        _state.update { it.copy(appSurface = AppSurface.APP_SETTINGS, connectionDialogVisible = false, error = null) }
    }

    fun dismissConnectionDialog() {
        connectionPrompt.dismiss(_state.value.desiredConnected, _state.value.connectionPhase)
        _state.update { it.copy(connectionDialogVisible = false) }
    }

    private fun reconcileConnectionDialog() {
        connectionDialogJob?.cancel()
        val current = _state.value
        val wait = connectionPrompt.reconcile(current.desiredConnected, current.connectionPhase, current.hasCachedWorkspace, foreground, Clock.System.now())
        _state.update { it.copy(connectionDialogVisible = connectionPrompt.visible) }
        if (wait != null) {
            connectionDialogJob = viewModelScope.launch {
                delay(wait)
                reconcileConnectionDialog()
            }
        }
    }

    // --- Machines ------------------------------------------------------------------------

    /** Reads every online machine's information for the machine list, four at a time. */
    fun refreshMachines() {
        val machineIds = _state.value.presentedEndpointConnections.filter { it.unavailableMessage == null }.map(MachineRow::id)
        machineListJob?.cancel()
        if (machineIds.isEmpty()) return
        machineListJob = launchCore(report = false) { core.telemetry.refreshAll(machineIds) }
    }

    /** Why [machineId] cannot be read or operated now, or null. */
    private fun machineUnavailable(machineId: String): String? {
        val machine = _state.value.presentedEndpointConnections.firstOrNull { it.id == machineId } ?: return "This machine is no longer enrolled."
        return machine.unavailableMessage
    }

    fun selectMachine(machineId: String) {
        if (_state.value.presentedEndpointConnections.none { it.id == machineId }) return
        val unavailable = machineUnavailable(machineId)
        _state.update { it.copy(selectedMachineId = machineId, machineOperationMessage = null) }
        launchCore {
            core.telemetry.select(machineId, active = foreground && unavailable == null)
            if (unavailable != null) core.telemetry.unavailable(machineId, unavailable)
        }
    }

    fun closeMachine() {
        _state.update { it.copy(selectedMachineId = null, machineOperationMessage = null) }
        launchCore(report = false) { core.telemetry.select(null, active = false) }
    }

    fun refreshSelectedMachineInformation() {
        val machineId = _state.value.selectedMachineId ?: return
        val unavailable = machineUnavailable(machineId)
        launchCore(report = false) {
            if (unavailable != null) core.telemetry.unavailable(machineId, unavailable) else core.telemetry.refreshAll(listOf(machineId))
        }
    }

    fun performMachineOperation(action: MachineOperationAction) {
        if (_state.value.selectedMachineId == null || _state.value.machineOperationInFlight) return
        _state.update { it.copy(machineOperationMessage = null) }
        launchCore {
            val response = core.telemetry.perform(action)
            _state.update { it.copy(machineOperationMessage = response?.message?.ifBlank { null } ?: "Machine operation accepted.") }
        }
    }

    fun dismissMachineOperationMessage() = _state.update { it.copy(machineOperationMessage = null) }

    fun renameMachine(daemonId: String, name: String) = action { core.renameMachine(daemonId, name) }

    fun revokeMachine(daemonId: String) = action { core.revokeMachine(daemonId) }

    fun openMachineTerminals(machineId: String) {
        machineUnavailable(machineId)?.let { unavailable ->
            _state.update { it.copy(machineOperationMessage = unavailable) }
            return
        }
        navigate(Destination.TERMINALS, terminalMachine = machineId)
    }

    // --- Navigation and selection ------------------------------------------------------------

    private var terminalMachineId: String? = null

    fun navigate(destination: Destination) = navigate(destination, terminalMachine = null)

    private fun navigate(destination: Destination, terminalMachine: String?) {
        closeConversation()
        if (destination != Destination.MACHINES) {
            machineListJob?.cancel()
            launchCore(report = false) { core.telemetry.select(null, active = false) }
        }
        _state.update {
            it.copy(
                destination = destination,
                appSurface = null,
                editingScheduleId = null,
                selectedMachineId = if (destination == Destination.MACHINES) it.selectedMachineId else null,
                projectFilesMode = if (destination == Destination.FILES) "browse" else it.projectFilesMode,
                boardOverviewVisible = if (destination == Destination.BOARD) true else it.boardOverviewVisible,
            )
        }
        launchCore(report = false) { terminals.setActive(foreground && destination == Destination.TERMINALS) }
        when (destination) {
            Destination.FILES -> loadFiles()
            Destination.SCHEDULES -> refreshSchedules()
            Destination.MACHINES -> refreshMachines()
            Destination.TERMINALS -> {
                if (terminalMachine != null) terminalMachineId = terminalMachine
                loadTerminals()
            }
            else -> Unit
        }
    }

    fun selectProject(id: String) {
        closeConversation()
        _state.update {
            it.copy(
                selectedProjectId = id,
                creationCheckoutId = it.creationCheckoutId.takeIf { selected ->
                    it.projects.firstOrNull { p -> p.id == id }?.checkouts?.any { c -> c.id == selected && !c.detached } == true
                }.orEmpty(),
                selectedBoardId = "",
                selectedLane = "",
                boards = emptyList(),
                cards = emptyList(),
                fileDocument = null,
                projectFilesMode = "browse",
            )
        }
        reselectFromWorkspace()
        when (_state.value.destination) {
            Destination.FILES -> loadFiles("")
            Destination.SCHEDULES -> refreshSchedules()
            else -> Unit
        }
        refreshHarnesses()
    }

    /** Recomputes the selected project's boards, cards, board, and lane from the workspace. */
    private fun reselectFromWorkspace() {
        val view = core.workspace.state.value
        _state.update { current ->
            val boards = view.boards[current.selectedProjectId].orEmpty()
            val boardId = current.selectedBoardId.takeIf { id -> boards.any { it.id == id } } ?: boards.firstOrNull()?.id.orEmpty()
            val lane = current.selectedLane.takeIf { id -> boards.firstOrNull { it.id == boardId }?.lanes?.any { it.id == id } == true }
                ?: boards.firstOrNull { it.id == boardId }?.lanes?.firstOrNull()?.id.orEmpty()
            current.copy(boards = boards, cards = view.cards[current.selectedProjectId].orEmpty(), selectedBoardId = boardId, selectedLane = lane)
        }
    }

    fun selectBoard(id: String) {
        closeConversation()
        val board = _state.value.boards.firstOrNull { it.id == id }
        _state.update { it.copy(selectedBoardId = id, selectedLane = board?.lanes?.firstOrNull()?.id.orEmpty()) }
    }

    fun openBoard(projectId: String, boardId: String) {
        closeConversation()
        if (projectId != _state.value.selectedProjectId) selectProject(projectId)
        val board = _state.value.spaceBoards.firstOrNull { it.id == boardId }
        _state.update {
            it.copy(
                destination = Destination.BOARD,
                boardOverviewVisible = false,
                selectedBoardId = boardId,
                selectedLane = board?.lanes?.firstOrNull()?.id.orEmpty(),
            )
        }
    }

    fun openNewBoard(projectId: String) {
        if (projectId != _state.value.selectedProjectId) selectProject(projectId)
        openSurface(AppSurface.NEW_BOARD)
    }

    fun showBoardOverview() {
        closeConversation()
        _state.update { it.copy(destination = Destination.BOARD, boardOverviewVisible = true) }
    }

    /** Board and activity data is live from the core; this only clears a stale error. */
    fun refreshSpaces() = _state.update { it.copy(spacesLoading = false) }

    fun selectLane(id: String) = _state.update { it.copy(selectedLane = id) }

    fun selectDetailTab(index: Int) = _state.update { it.copy(detailTab = index) }

    fun openSurface(surface: AppSurface, schedule: Schedule? = null) {
        launchCore(report = false) { core.schedules.closeEditor() }
        if (schedule != null) {
            action {
                val detail = core.schedules.details(schedule.id)
                _state.update { it.copy(appSurface = surface, editingScheduleId = detail.id) }
            }
            return
        }
        if (surface == AppSurface.NEW_CARD) {
            withCaptures {
                boardTask()
                showSurface(surface)
            }
            return
        }
        showSurface(surface)
    }

    private fun showSurface(surface: AppSurface) {
        _state.update { it.copy(appSurface = surface, editingScheduleId = null, error = null) }
        if (surface == AppSurface.WORKSPACE) loadAdministration()
    }

    fun closeSurface() {
        taskCaptures?.flushAll()
        launchCore(report = false) { core.schedules.closeEditor() }
        _state.update { it.copy(appSurface = null, editingScheduleId = null) }
    }

    // --- Folders and ordering (shared navigation) -------------------------------------------

    private fun editNavigation(block: com.dbpprt.dieter.core.navigation.NavigationEditor.() -> Unit) =
        launchCore { core.editNavigation(block) }

    fun toggleLaneSort(boardId: String, laneId: String) = editNavigation {
        setLaneDescending(boardId, laneId, !layout.laneDescending(boardId, laneId))
    }

    fun moveProject(projectId: String, targetProjectId: String) {
        val displayed = _state.value.projects.map(Project::id)
        editNavigation { moveProject(projectId, targetProjectId, displayed) }
    }

    fun setProjectPinned(projectId: String, pinned: Boolean) {
        if (projectId.isNotBlank()) editNavigation { pinProject(projectId, pinned) }
    }

    fun toggleChatProjectCollapsed(projectId: String) = editNavigation {
        setChatSectionCollapsed(projectId, !layout.chatSectionCollapsed(projectId))
    }

    fun toggleChatProjectExpanded(projectId: String) = editNavigation {
        setChatsShowAll(projectId, !layout.chatsShowAll(projectId))
    }

    fun movePinnedChat(chatId: String, targetChatId: String) {
        val displayed = _state.value.pinnedChatOrder
        editNavigation { movePinnedChat(chatId, targetChatId, displayed) }
    }

    override fun createFolder(scope: FolderScope, name: String, itemId: String?) {
        editNavigation {
            val id = createFolder(scope, name)
            if (itemId != null) moveToFolder(scope, itemId, id)
        }
    }

    override fun renameFolder(scope: FolderScope, id: String, name: String) { editNavigation { renameFolder(scope, id, name) } }

    override fun deleteFolder(scope: FolderScope, id: String) { editNavigation { deleteFolder(scope, id) } }

    override fun setFolderExpanded(scope: FolderScope, id: String, expanded: Boolean) { editNavigation { setFolderExpanded(scope, id, expanded) } }

    override fun moveToFolder(scope: FolderScope, itemId: String, folderId: String?) { editNavigation { moveToFolder(scope, itemId, folderId) } }

    fun reorderFolders(scope: FolderScope, order: List<String>) = editNavigation { reorderFolders(scope, order) }

    fun reorderFolderItems(scope: FolderScope, folderId: String, order: List<String>) = editNavigation { reorderFolderItems(scope, folderId, order) }

    fun setChatsPaneLeadingFraction(fraction: Float) = appPreferences.setChatsPaneLeadingFraction(fraction)
    fun setActivityPaneLeadingFraction(fraction: Float) = appPreferences.setActivityPaneLeadingFraction(fraction)
    fun setProjectsPaneLeadingFraction(fraction: Float) = appPreferences.setProjectsPaneLeadingFraction(fraction)
    fun setBoardPaneLeadingFraction(fraction: Float) = appPreferences.setBoardPaneLeadingFraction(fraction)

    // --- Outbox -----------------------------------------------------------------------------

    fun isPendingCard(id: String): Boolean = id in _state.value.pendingCardIds
    fun isPendingMessage(id: String): Boolean = id in _state.value.pendingMessageIds
    fun isAcceptedOutboxItem(id: String): Boolean = id in _state.value.acceptedOutboxIds
    fun isFailedOutboxItem(id: String): Boolean = id in _state.value.failedOutboxIds
    fun conversationCreationFailure(id: String): String? = core.outbox.view.value.failure(id)

    fun retryOutboxItem(id: String) {
        _state.update { it.copy(error = null) }
        launchCore { core.retryPending(id) }
    }

    fun retryOutboxForEndpoint(daemonId: String) {
        _state.update { it.copy(error = null) }
        launchCore { core.retryPendingOn(daemonId) }
    }

    fun discardOutboxItem(id: String) {
        launchCore { core.discardPending(id) }
        if (_state.value.selectedCardId == id) closeDetail()
    }

    // --- Card mutations ---------------------------------------------------------------------

    private fun board(block: suspend com.dbpprt.dieter.core.board.BoardOperations.() -> Unit) = launchCore { core.onBoard(block) }

    fun moveBoardCard(cardId: String, lane: String, afterCardId: String = "", beforeCardId: String = "") =
        board { move(cardId, lane, DropAnchors(afterCardId, beforeCardId)) }

    fun startBoardCard(cardId: String) = launchCore { core.startCard(cardId) }

    fun startSelectedCard() {
        val id = _state.value.selectedCardId ?: return
        launchCore { core.startCard(id, hasDraftAttachments = _state.value.composerDraft.attachments.isNotEmpty()) }
    }

    fun markDone() {
        val id = _state.value.selectedCardId ?: return
        board { finish(id) }
    }

    fun setSelectedCardLabels(labelIds: List<String>) {
        val id = _state.value.selectedCardId ?: return
        board { setLabels(id, labelIds) }
    }

    fun assignLabelToBoardCard(cardId: String, labelId: String) = board { addLabel(cardId, labelId) }

    fun cancelSelected() {
        val id = _state.value.selectedCardId ?: return
        board { cancel(id) }
    }

    fun renameSelected(title: String) {
        val id = _state.value.selectedCardId ?: return
        board { rename(id, title) }
    }

    fun forkSelected(messageId: String = "") {
        val id = _state.value.selectedCardId ?: return
        action {
            val fork = core.board.fork(id, messageId)
            viewModelScope.launch { openCard(fork, Destination.CHATS) }
        }
    }

    fun editBoardCard(cardId: String, title: String, initialPrompt: String) = board { updateDraft(cardId, title, initialPrompt) }

    fun archiveSelected() {
        val card = _state.value.selectedCard ?: return
        if (card.archived) board { restore(card) } else board { archive(card.id) }
        closeDetail()
    }

    fun archiveBoardCard(cardId: String) = board { archive(cardId) }

    fun archiveConversation(card: Card) {
        board { archive(card.id) }
        if (_state.value.selectedCardId == card.id) closeDetail()
    }

    fun renameConversation(card: Card, title: String) = board { rename(card.id, title) }

    fun togglePin(card: Card) = board { setPinned(card.id, !card.pinned) }

    fun restoreCard(card: Card) = action {
        core.board.restore(card)
        loadAdministrationNow()
    }

    // --- Conversation -----------------------------------------------------------------------

    fun openCard(card: Card, destination: Destination = _state.value.destination) {
        val cardId = core.outbox.view.value.resolve(card.id)
        if (_state.value.selectedCardId == cardId && session != null) {
            _state.update { it.copy(destination = destination, boardOverviewVisible = if (destination == Destination.BOARD) false else it.boardOverviewVisible) }
            return
        }
        closeConversation()
        val projectId = card.project_id.ifBlank { _state.value.selectedProjectId }
        if (projectId != _state.value.selectedProjectId && projectId.isNotBlank()) {
            _state.update { it.copy(selectedProjectId = projectId) }
            reselectFromWorkspace()
        }
        _state.update {
            it.copy(
                destination = destination,
                boardOverviewVisible = if (destination == Destination.BOARD) false else it.boardOverviewVisible,
                selectedCardId = cardId,
                conversation = core.workspace.state.value.conversations[cardId],
                conversationScrollRequest = it.conversationScrollRequest + 1,
                conversationSyncing = OutboxPolicy.isServerBacked(cardId),
                detailTab = 0,
                error = core.outbox.view.value.failure(cardId),
            )
        }
        conversationJob = viewModelScope.launch {
            val opened = core.openConversation(cardId)
            session = opened
            core.onCore { core.visibleConversationId = opened.cardId }
            // The draft follows the card from its local to its server ID.
            opened.view.map { view -> view.daemonId?.let { DraftKey(it, view.cardId) } }.distinctUntilChanged().collectLatest { key ->
                val editor = key?.let { core.onCore { core.drafts.editor(it) } }
                composer = editor
                try {
                    combine(opened.view, editor?.state ?: flowOf(ConversationDraft())) { view, _ -> view }.collect { applyConversation(it) }
                } finally {
                    if (composer === editor) composer = null
                    if (editor != null) withContext(NonCancellable) { core.onCore { core.drafts.release(editor) } }
                }
            }
        }
    }

    private fun applyConversation(view: ConversationView) {
        // The editor's latest, never an older value the flow captured before a keystroke.
        val draft = composer?.state?.value ?: ConversationDraft()
        _state.update { current ->
            if (current.selectedCardId != view.cardId && core.outbox.view.value.resolve(current.selectedCardId.orEmpty()) != view.cardId) return@update current
            current.copy(
                selectedCardId = view.cardId,
                conversation = view.presented ?: current.conversation,
                conversationView = view,
                historyStart = view.transcript.history.start,
                historyTotal = view.transcript.history.total,
                historyHasMore = view.transcript.history.hasMore,
                historyLoading = view.transcript.history.loading,
                conversationSyncing = view.syncing || (view.loading && OutboxPolicy.isServerBacked(view.cardId)),
                conversationRefreshing = view.loading && view.presented == null,
                conversationLastRefreshedAtMillis = view.refreshedAt?.toEpochMilliseconds() ?: current.conversationLastRefreshedAtMillis,
                composerDraft = draft,
                error = view.error ?: current.error,
            )
        }
        val daemonId = view.daemonId
        val cardId = view.cardId
        if (daemonId != null && _state.value.workspaceReview.cardId != cardId) {
            launchCore(report = false) {
                review.bind(cardId, daemonId)
                review.setActive(foreground)
            }
        }
    }

    fun openNotificationCard(cardId: String) {
        val card = (_state.value.chats + _state.value.cards + _state.value.spaceCards).firstOrNull { it.id == cardId } ?: return
        openCard(card, if (card.scope == "chat") Destination.CHATS else Destination.BOARD)
    }

    private fun closeConversation() {
        conversationJob?.cancel()
        conversationJob = null
        val closing = session
        session = null
        launchCore(report = false) {
            core.visibleConversationId = null
            review.bind(null, null)
            closing?.let { core.closeConversation(it.cardId) }
        }
        _state.update {
            it.copy(
                selectedCardId = null,
                composerDraft = ConversationDraft(),
                conversation = null,
                conversationView = null,
                historyStart = 0,
                historyTotal = 0,
                historyHasMore = false,
                historyLoading = false,
                conversationLastRefreshedAtMillis = null,
                conversationSyncing = false,
                conversationRefreshing = false,
            )
        }
    }

    fun closeDetail() = closeConversation()

    private fun conversation(block: suspend ConversationSession.() -> Unit) {
        val current = session ?: return
        launchCore { current.block() }
    }

    private fun draftKey(): DraftKey? {
        val daemonId = session?.view?.value?.daemonId ?: return null
        return DraftKey(daemonId, session?.cardId ?: return null)
    }

    fun forceRefreshConversation() = conversation { refresh() }

    fun loadOlderMessages() = conversation { loadEarlier() }

    fun returnToLatest() = conversation { returnToLatest() }

    suspend fun loadToolOutput(messageId: String, part: MessagePart): ToolOutput {
        val current = session ?: error("No conversation is selected")
        return core.onConversation(current) { toolOutput(messageId, part.tool_call_id, part.payload_revision) }
    }

    /** An image a message links to, read from the conversation's workspace. */
    suspend fun readConversationImage(destination: String): FileDocument? {
        val current = session?.view?.value ?: return null
        val daemonId = current.daemonId ?: return null
        val card = current.card ?: return null
        return core.onMachine(daemonId) {
            it.ReadFile().execute(ReadFileRequest(project_id = card.project_id, path = destination, card_id = card.id))
        }
    }

    /** The open conversation as the screen shows it; computed by the core from the latest view and outbox. */
    fun presentConversation(state: DieterUiState): ConversationPresentation? {
        val cardId = state.selectedCardId ?: return null
        val view = state.conversationView ?: ConversationView(cardId)
        val card = view.card ?: state.selectedCard
        return ConversationPresenter.present(
            view,
            core.outbox.view.value,
            card?.let { core.workspace.state.value.board(it.board_id) } ?: state.board,
            card?.id?.let(state.cardOperations::get),
            state.showReasoningTraces,
            fallbackCard = state.selectedCard,
        )
    }

    /** Sends the composer draft; the core clears exactly what was sent. */
    fun sendDraft() = conversation { sendDraft() }

    /** Sends [text] outside the composer draft, e.g. from the subagents tab. */
    fun sendMessage(text: String, selection: HarnessSelection) {
        if (text.isBlank()) return
        conversation { send(listOf(textPart(text.trim())), selection) }
    }

    private fun updateDraft(change: com.dbpprt.dieter.core.composition.ConversationDrafts.(DraftKey) -> Unit) {
        launchCore { draftKey()?.let { core.drafts.change(it) } }
    }

    fun updateComposerText(value: String) {
        val editor = composer ?: return
        editor.setText(value)
        _state.update { it.copy(composerDraft = editor.state.value) }
    }

    fun updateComposerSelection(value: HarnessSelection) = updateDraft { setSelection(it, value) }

    fun addComposerAttachments(values: List<MessagePart>) {
        if (values.isEmpty()) return
        launchCore { draftKey()?.let { core.drafts.addAttachments(it, values).getOrThrow() } }
    }

    fun removeComposerAttachment(index: Int) = updateDraft { removeAttachment(it, index) }

    fun removeQueuedMessage(message: QueuedMessage, edit: Boolean) = conversation { removeQueued(message.id, edit) }

    fun steerQueuedMessage(message: QueuedMessage) = conversation { steer(message.id) }

    fun retryFailedTurn() = conversation { retryFailedTurn() }

    suspend fun markResponseSeen(cardId: String) {
        val current = session ?: return
        if (current.cardId != cardId) return
        runCatching { core.onConversation(current) { markReadIfVisible() } }
    }

    // --- Creation and capture ---------------------------------------------------------------

    private fun withCaptures(block: suspend TaskCaptureStore.() -> Unit) {
        val store = taskCaptures ?: return
        viewModelScope.launch {
            try {
                store.block()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                _state.update { it.copy(error = Failures.message(failure)) }
            }
        }
    }

    /** Opens the capture chooser for [editor], else for an empty or new draft. */
    internal fun beginCapture(editor: TaskDraftEditor? = null) = withCaptures {
        activeCapture = editor ?: begin()
        captureChooserVisible = true
    }

    internal fun captureProject(id: String) {
        activeCapture?.edit { TaskDrafts.project(it, id) }
        selectProject(id)
        val boards = _state.value.spaceBoards.filter { it.project_id == id && !it.retired }
        if (boards.size == 1) openCaptureBoard(boards.single().id)
    }

    internal fun openCaptureBoard(id: String) {
        val editor = activeCapture ?: return
        val board = _state.value.spaceBoards.firstOrNull { it.id == id } ?: return
        selectBoard(id)
        val draft = editor.edit { TaskDrafts.board(it, board) }
        if (draft.checkout_id.isNotBlank()) _state.update { it.copy(creationCheckoutId = draft.checkout_id) }
        captureChooserVisible = false
        showSurface(AppSurface.NEW_CARD)
    }

    /** The open board's task draft (quick task and full editor), unless a capture for it is already open. */
    private suspend fun TaskCaptureStore.boardTask(): TaskDraftEditor {
        val current = _state.value
        activeCapture?.takeIf { it.state.value.project_id == current.selectedProjectId && it.state.value.board_id == current.selectedBoardId }
            ?.let { return it }
        return forBoard(current.selectedProjectId, current.selectedBoardId).also { activeCapture = it }
    }

    internal fun openQuickTask() = withCaptures {
        boardTask()
        quickTaskOpen = true
    }

    internal fun closeQuickTask() {
        quickTaskOpen = false
    }

    internal fun openTaskOptions() {
        quickTaskOpen = false
        openSurface(AppSurface.NEW_CARD)
    }

    /** Applies the remembered agent, workspace, and lane once; never over the user's edits. */
    internal fun initializeTask(editor: TaskDraftEditor, quick: Boolean) {
        val current = _state.value
        val harnesses = current.creationCatalog(chat = false).orEmpty()
        val lane = (if (quick) "" else current.selectedLane).ifBlank { Creation.defaultLane(current.board) }
        editor.edit { TaskDrafts.initialize(it, core.creation.selection(harnesses), core.creation.workspaceMode, lane, harnesses) }
    }

    /** A new chat's defaults: the remembered agent and workspace, when the destination's catalog is live. */
    internal fun initializeChat(editor: TaskDraftEditor) {
        val harnesses = _state.value.creationCatalog(chat = true) ?: return
        editor.edit { TaskDrafts.initialize(it, core.creation.selection(harnesses), core.creation.workspaceMode, Lanes.TODO, harnesses) }
    }

    internal fun discardTaskDraft(editor: TaskDraftEditor) {
        quickTaskOpen = false
        if (activeCapture?.id == editor.id) activeCapture = null
        taskCaptures?.discard(editor.id)
        closeSurface()
    }

    internal fun returnToQuickTask() {
        val draft = activeCapture?.state?.value
        closeSurface()
        if (draft != null) openBoard(draft.project_id, draft.board_id)
        quickTaskOpen = true
    }

    fun selectCreationCheckout(id: String) {
        val checkout = _state.value.projects.flatMap { it.checkouts }.firstOrNull { it.id == id } ?: return
        _state.update { it.copy(creationCheckoutId = id, fileDocument = null) }
        activeCapture?.takeIf { it.state.value.project_id == checkout.project_id }?.edit { TaskDrafts.checkout(it, id) }
        refreshHarnesses()
        if (_state.value.destination == Destination.FILES) loadFiles("")
    }

    fun prepareCreationCheckout(id: String) = selectCreationCheckout(id)

    /** Loads the agent catalog of the machine a new conversation would run on. */
    private fun refreshHarnesses() {
        val current = _state.value
        val daemonId = Creation.catalogMachine(
            current.creationCheckout,
            current.projectReplicas[current.selectedProjectId]?.daemonId,
            core.connection.state.value.attachedMachineId,
        ) ?: return
        val metadata = core.metadata.machines.value[daemonId]
        _state.update { it.copy(harnesses = metadata?.harnesses?.harnesses.orEmpty(), harnessesEndpointId = daemonId.takeIf { metadata?.loaded == true }) }
        if (metadata == null) launchCore(report = false) { core.metadata.ensure(daemonId) }
    }

    internal fun creationProblem(draft: CaptureDraft, chat: Boolean): String? = _state.value.creationProblem(draft, chat)

    internal fun canSubmitTask(draft: CaptureDraft): Boolean = _state.value.canSubmitTask(draft)

    /** Queues the task in [editor]; its capture is submitted at most once, even across retries and restarts. */
    internal fun submitTask(editor: TaskDraftEditor, onCreated: () -> Unit = {}) = create(editor.state.value, chat = false, editor, onCreated)

    /** Starts a chat; its editor belongs to the chat screen and is not journaled. */
    internal fun createChat(draft: CaptureDraft) = create(draft, chat = true, editor = null)

    private fun create(draft: CaptureDraft, chat: Boolean, editor: TaskDraftEditor?, onCreated: () -> Unit = {}) {
        val current = _state.value
        if (current.working) return
        val project = current.project ?: return _state.update { it.copy(error = "Select a project before creating a conversation.") }
        current.creationProblem(draft, chat)?.let { problem -> return _state.update { it.copy(error = problem) } }
        val input = current.creationInput(draft, project, chat)
        action {
            val request = Creation.request(input)
            core.creation.remember(input.selection, input.workspaceMode, project.id, input.board?.id)
            val card = if (editor != null) core.submitCapture(editor.id, request, chat) else core.createConversation(request, chat)
            viewModelScope.launch {
                if (editor != null && activeCapture?.id == editor.id) activeCapture = null
                quickTaskOpen = false
                onCreated()
                _state.update { it.copy(appSurface = null, editingScheduleId = null) }
                if (Creation.opensAfterCreate(chat, input.lane)) openCard(card, if (chat) Destination.CHATS else Destination.BOARD)
            }
        }
    }

    // --- Schedules --------------------------------------------------------------------------

    private fun schedules(block: suspend com.dbpprt.dieter.core.schedules.Schedules.() -> Unit) = launchCore { core.schedules.block() }

    fun refreshSchedules() {
        val projectId = _state.value.selectedProjectId.ifBlank { return }
        schedules {
            bind(projectId)
            load()
        }
    }

    fun loadMoreSchedules() = schedules { loadMore() }

    fun previewSchedule(cron: String, timezone: String) = schedules { preview(cron, timezone) }

    fun selectSchedule(schedule: Schedule?) {
        if (schedule != null) schedules { select(schedule.id) }
    }

    fun loadMoreScheduleRuns() = schedules { loadMoreRuns() }

    fun saveSchedule(scheduleId: String, draft: ScheduleDraft) = action {
        core.schedules.save(draft, scheduleId.ifBlank { null }, _state.value.creationCheckout?.id)
        viewModelScope.launch { closeSurface() }
    }

    fun toggleSchedule(schedule: Schedule) = schedules { setEnabled(schedule.id, !schedule.enabled) }

    fun runSchedule(schedule: Schedule) = schedules { runNow(schedule.id) }

    fun deleteSchedule(schedule: Schedule) = schedules { delete(schedule.id) }

    // --- Terminals --------------------------------------------------------------------------

    fun selectTerminalMachine(daemonId: String) {
        if (_state.value.presentedEndpointConnections.none { it.daemonId == daemonId && it.online && it.isCompatible }) return
        terminalMachineId = daemonId
        loadTerminals()
    }

    fun loadTerminals() {
        if (!foreground) return
        val daemonId = terminalMachineId ?: core.connection.state.value.attachedMachineId ?: return
        // Route/presence refreshes must not silently move this surface to another machine.
        terminalMachineId = daemonId
        launchCore {
            terminals.bind(TerminalScope(daemonId, TerminalScopeKind.MACHINE))
            terminals.setActive(foreground && _state.value.destination == Destination.TERMINALS)
            terminals.load()
        }
    }

    fun showTerminalCreate() = _state.update { it.copy(terminalCreateVisible = true) }

    fun dismissTerminalCreate() = _state.update { it.copy(terminalCreateVisible = false) }

    fun selectTerminal(terminalId: String) = launchCore { terminals.select(terminalId) }

    fun sendTerminalInput(data: ByteArray) = launchCore { terminals.input(data) }

    fun resizeTerminal(columns: Int, rows: Int) = launchCore(report = false) { terminals.gridChanged(columns, rows) }

    fun renameTerminal(terminalId: String, name: String) = launchCore { terminals.rename(terminalId, name) }

    fun closeTerminal(terminalId: String) = launchCore { terminals.close(terminalId) }

    fun createTerminal(form: NewTerminal, onCreated: () -> Unit = {}) = action {
        val machine = terminalMachineId ?: core.connection.state.value.attachedMachineId ?: error("No machine is attached.")
        val scope = TerminalScope.forCreation(machine, _state.value.projects.firstOrNull { it.id == form.projectId })
        if (terminals.view.value.scope != scope) {
            terminals.bind(scope)
            terminals.load()
        }
        terminals.create(name = form.name, shell = form.shell, workingDirectory = form.workingDirectory.ifBlank { null }, columns = PHONE_COLUMNS, rows = PHONE_ROWS)
        _state.update { it.copy(terminalCreateVisible = false) }
        viewModelScope.launch { onCreated() }
    }

    // --- Files ------------------------------------------------------------------------------

    private fun filesTarget(): FilesTarget? {
        val current = _state.value
        val project = current.project ?: return null
        val checkout = current.creationCheckout ?: return null
        return FilesTarget(checkout.daemon_id, project.id, checkout.id)
    }

    private fun loadFiles(path: String? = null) {
        val target = filesTarget() ?: return
        launchCore {
            files.bind(target)
            if (path != null) files.navigate(path) else files.load()
        }
    }

    fun openDirectory(path: String) = launchCore { files.navigate(path) }

    fun openParentDirectory() = launchCore { files.parent() }

    fun setShowHiddenFiles(show: Boolean) = launchCore { files.setShowHidden(show) }

    fun openFile(path: String) = launchCore { files.open(path) }

    fun updateFileDraft(content: String) = files.edit(content)

    fun saveFile() = action { files.save() }

    /** Replaces the draft with the version on disk after a save conflict. */
    fun reloadFile() = launchCore { files.reload() }

    /** Creates [name] in the open folder. */
    fun createFile(name: String, directory: Boolean) = action { files.create(name, directory) }

    fun moveFile(source: String, destination: String) = action { files.move(source, destination) }

    fun deleteFile(path: String, recursive: Boolean) = action { files.delete(path, recursive) }

    fun closeFile(force: Boolean = false): Boolean {
        if (_state.value.fileDirty && !force) return false
        launchCore(report = false) { files.close() }
        return true
    }

    fun setProjectFilesMode(mode: String) {
        _state.update { it.copy(projectFilesMode = mode) }
        if (mode == "changes") loadProjectChanges() else launchCore(report = false) { projectChangesController.setActive(false) }
    }

    // --- Project changes --------------------------------------------------------------------

    fun openProjectChanges() {
        _state.update { it.copy(destination = Destination.FILES, projectFilesMode = "changes") }
        loadProjectChanges()
    }

    fun loadProjectChanges() {
        val current = _state.value
        val checkout = current.creationCheckout ?: return
        launchCore {
            projectChangesController.bind(current.selectedProjectId, checkout.id, checkout.daemon_id)
            projectChangesController.setActive(foreground)
            projectChangesController.refresh()
        }
    }

    fun selectProjectChange(path: String, section: ChangeSection) = launchCore { projectChangesController.select(path, section) }

    fun loadMoreProjectDiff() = launchCore { projectChangesController.loadMoreDiff() }

    /** Runs a checkout operation; [path] narrows stage, unstage, and discard to one file. */
    fun startProjectGitOperation(kind: String, path: String = "", parameters: Map<String, String> = emptyMap()) = launchCore {
        projectChangesController.run(kind, if (path.isBlank()) parameters else parameters + ("path" to path))
    }

    fun closeProjectDiff() = launchCore { projectChangesController.deselect() }

    fun clearProjectChangesError() = launchCore { projectChangesController.dismissMessages() }

    // --- Workspace review -------------------------------------------------------------------

    private fun review(block: suspend WorkspaceReview.() -> Unit) = launchCore { review.block() }

    fun loadWorkspaceSurface() = review { refresh() }

    fun selectWorkspaceChange(path: String?, commitSha: String? = null) = review { select(path, commitSha) }

    fun loadMoreWorkspaceDiff() = review { loadMoreDiff() }

    fun startWorkspaceGitOperation(kind: String, parameters: Map<String, String> = emptyMap()) = review { start(kind, parameters) }

    fun cancelWorkspaceGitOperation() = review { cancelOperation() }

    fun addWorkspaceChangeComment(line: DiffLine, body: String) = review { addComment(line, body, "Android") }

    fun updateConversationWorkspace(mode: WorkspaceMode, branch: String, baseBranch: String) = review { updateSettings(mode, branch, baseBranch) }

    fun runWorkspaceMergeFlow(strategy: MergeStrategy, subject: String, body: String, validate: Boolean, removeWorkspace: Boolean, moveCardToDone: Boolean) =
        review { mergeFlow(strategy, subject, body, validate, removeWorkspace, moveCardToDone) }

    fun clearWorkspaceToast() = review { clearToast() }

    fun clearWorkspaceError() = review { clearError() }

    fun sendWorkspaceHandOffMessage(text: String) {
        val current = session ?: return
        action { current.send(listOf(textPart(text))) }
    }

    // --- Administration ---------------------------------------------------------------------

    fun loadAdministration() = launchCore { loadAdministrationNow() }

    private suspend fun loadAdministrationNow() {
        val current = _state.value
        val projectId = current.selectedProjectId.ifBlank { return }
        val (projects, cards) = core.admin.archives(projectId, current.selectedBoardId.ifBlank { null })
        val settings = runCatching { core.admin.settings(projectId) }.getOrNull()
        val options = runCatching { core.admin.settingsOptions(projectId) }.getOrNull()
        _state.update { it.copy(administration = AdministrationState(settings, options, projects, cards)) }
    }

    fun clearDirectoryListing() = _state.update { it.copy(directoryListing = null, directoryListingEndpointId = "", directoryListingLoading = false) }

    fun listDirectories(daemonId: String, path: String = "") {
        _state.update { it.copy(directoryListingEndpointId = daemonId, directoryListingLoading = true) }
        viewModelScope.launch {
            try {
                val listing = core.onCore { core.admin.directories(daemonId, path) }
                _state.update { if (it.directoryListingEndpointId == daemonId) it.copy(directoryListing = listing, directoryListingLoading = false) else it }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                _state.update { it.copy(directoryListingLoading = false, error = Failures.message(error)) }
            }
        }
    }

    fun attachCheckout(projectId: String, daemonId: String, path: String, name: String) = action {
        core.admin.attachCheckout(daemonId, projectId, path, name)
    }

    fun detachCheckout(id: String) = action {
        val checkout = _state.value.projects.flatMap { it.checkouts }.first { it.id == id }
        core.admin.detachCheckout(checkout.project_id, id)
        _state.update { it.copy(creationCheckoutId = "") }
    }

    fun consolidateProject(destination: String) = action {
        core.admin.consolidate(_state.value.selectedProjectId, destination)
        viewModelScope.launch { selectProject(destination) }
    }

    fun createProject(
        daemonId: String,
        create: Boolean,
        path: String,
        name: String,
        summary: String,
        prompt: String,
        boardName: String,
        workflow: String,
        baseRemote: String,
        baseBranch: String,
        validationCommands: List<ValidationCommand>,
    ) = action {
        val response = core.admin.createProject(daemonId, path, name, create, boardName, workflow, baseRemote, baseBranch, validationCommands)
        val project = response.project ?: return@action
        if (summary.isNotBlank() || prompt.isNotBlank()) core.admin.updateProject(project.id, summary = summary, prompt = prompt)
        pendingProjectCreation = null
        viewModelScope.launch {
            selectProject(project.id)
            closeSurface()
        }
    }

    fun updateProject(name: String, summary: String, prompt: String, baseRemote: String, baseBranch: String, validationCommands: List<ValidationCommandDraft>?) = action {
        val project = _state.value.project ?: return@action
        ProjectWorkspaceSettings.update(core.sessions, core.workspace, project, baseRemote, baseBranch, _state.value.creationCheckout?.id, validationCommands)
        core.admin.updateProject(project.id, name = name, summary = summary, prompt = prompt)
    }

    fun loadProjectWorkspaces() {
        val projectId = _state.value.selectedProjectId.ifBlank { return }
        launchCore { core.projectWorkspaces.load(projectId) }
    }

    fun removeProjectWorkspace(workspace: Workspace, discard: Boolean) = launchCore { core.projectWorkspaces.remove(workspace, discard) }

    fun archiveCurrentProject() = action {
        core.admin.setProjectArchived(_state.value.selectedProjectId, true)
    }

    fun restoreProject(project: Project) = action {
        core.admin.setProjectArchived(project.id, false)
        loadAdministrationNow()
    }

    fun createBoard(name: String, workflow: String, description: String, openAfterCreate: Boolean = false, baseRemote: String = "", remotePublishMode: String = "manual") = action {
        val projectId = _state.value.selectedProjectId
        val board = core.admin.createBoard(projectId, name, workflow, description, baseRemote = baseRemote, publishMode = remotePublishMode)
        viewModelScope.launch {
            closeSurface()
            if (openAfterCreate) openBoard(projectId, board.id)
        }
    }

    fun restoreBoard(id: String) = action { core.admin.setBoardRetired(id, false) }

    fun retireBoard(id: String) = action { core.admin.setBoardRetired(id, true) }

    fun setBoardArchivePolicy(policy: String) = action { core.admin.setArchivePolicy(_state.value.selectedBoardId, policy) }

    fun updateBoardGitSettings(baseRemote: String, remotePublishMode: String) = action {
        core.admin.setGitSettings(_state.value.selectedBoardId, baseRemote, remotePublishMode)
    }

    fun createBoardLabel(name: String, color: String) = action { core.admin.createLabel(_state.value.selectedBoardId, name, color) }

    fun deleteBoardLabel(labelId: String) = action { core.admin.deleteLabel(_state.value.selectedBoardId, labelId) }

    fun updateSettings(settings: Settings) = action {
        val updated = core.admin.updateSettings(_state.value.selectedProjectId, settings)
        _state.update { it.copy(administration = it.administration.copy(settings = updated)) }
    }

    fun loadSharedConflicts(keys: List<String>) = launchCore {
        val projectId = _state.value.selectedProjectId
        val records = keys.mapNotNull { key -> core.admin.conflict(projectId, key) }
        _state.update { it.copy(sharedConflicts = records) }
    }

    fun dismissSharedConflicts() = _state.update { it.copy(sharedConflicts = emptyList()) }

    fun resolveSharedConflict(record: PeerRecord, version: PeerVersion) = action {
        core.admin.resolve(_state.value.selectedProjectId, record, version.value_json.takeUnless { version.deleted }, version.deleted)
        _state.update { current -> current.copy(sharedConflicts = current.sharedConflicts.filterNot { it.id == record.id && it.kind == record.kind }) }
    }

    // --- Quotas -----------------------------------------------------------------------------

    fun refreshProviderQuotas(requestRefresh: Boolean = true) = launchCore(report = false) { core.quotas.load(requestRefresh) }

    fun setProviderQuotaSummaryInclusion(provider: ProviderQuotaProvider, accountKey: String, included: Boolean) =
        launchCore(report = false) { core.quotas.setIncluded(provider, accountKey, included) }

    fun consumeProviderQuotaReset(accountKey: String) = launchCore(report = false) { core.quotas.consumeReset(accountKey) }

    // --- Factory ----------------------------------------------------------------------------

    internal class Factory(
        private val core: CoreRuntime,
        private val appPreferences: AppPreferences,
        private val policy: ConnectionPolicy,
        private val host: AppHost,
        private val taskCaptures: TaskCaptureStore? = null,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            DieterViewModel(core, appPreferences, policy, host, taskCaptures) as T
    }

    companion object {
        fun textPart(text: String): MessagePart = MessagePart(type = "text", text = text)

        /** A new terminal's first grid on a phone; the view reports its real size once shown. */
        private const val PHONE_COLUMNS = 80
        private const val PHONE_ROWS = 28

    }
}
