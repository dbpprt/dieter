package com.dbpprt.dieter.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.connection.DieterConnectionState
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.connection.EndpointPhase
import com.dbpprt.dieter.connection.ProjectHost
import com.dbpprt.dieter.connection.isServerConversationId
import com.dbpprt.dieter.connection.resolveConversationId
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DIETER_LOCAL_ENDPOINT
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.NavigationStyle
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CreateBoardRequest
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.CreateProjectRequest
import com.dbpprt.dieter.v1.CreateTerminalRequest
import com.dbpprt.dieter.v1.DirectoryListing
import com.dbpprt.dieter.v1.FileDocument
import com.dbpprt.dieter.v1.FileEntry
import com.dbpprt.dieter.v1.GetStateRequest
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.RuntimeStatus
import com.dbpprt.dieter.v1.SaveScheduleRequest
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.ScheduleDraft
import com.dbpprt.dieter.v1.ScheduleRun
import com.dbpprt.dieter.v1.Settings
import com.dbpprt.dieter.v1.SettingsOptions
import com.dbpprt.dieter.v1.State
import com.dbpprt.dieter.v1.UiMessage
import com.dbpprt.dieter.v1.UpdateProjectRequest
import com.dbpprt.dieter.v1.ToolOutput
import com.dbpprt.dieter.v1.Terminal
import com.dbpprt.dieter.v1.TerminalFrame
import io.grpc.Status
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.retryWhen
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.time.ZoneId

private const val CONVERSATION_PAGE_SIZE = 30
private const val HEDGE_FETCH_TIMEOUT_MS = 3_500L
private const val FIRST_FRAME_DEADLINE_MS = 4_500L
internal const val CONNECTION_DIALOG_GRACE_MS = 60_000L

internal fun connectionDialogDelayMs(
    desiredConnected: Boolean,
    phase: ConnectionPhase,
    interruptedAtMs: Long?,
    nowMs: Long,
): Long? {
    if (!desiredConnected || phase == ConnectionPhase.CONNECTED || phase == ConnectionPhase.STOPPED) return null
    val elapsed = (nowMs - (interruptedAtMs ?: nowMs)).coerceAtLeast(0L)
    return (CONNECTION_DIALOG_GRACE_MS - elapsed).coerceAtLeast(0L)
}

enum class Destination { CHATS, BOARD, TERMINALS, FILES, SCHEDULES }

enum class AppSurface { NEW_CHAT, NEW_CARD, NEW_BOARD, SCHEDULE_EDITOR, WORKSPACE, NEW_PROJECT, APP_SETTINGS }

enum class CardOperation { STARTING, MOVING, CANCELLING }

data class DieterUiState(
    val destination: Destination = Destination.BOARD,
    val appSurface: AppSurface? = null,
    val editingScheduleId: String? = null,
    val endpoint: String = DIETER_LOCAL_ENDPOINT,
    val connectionPhase: ConnectionPhase = ConnectionPhase.STOPPED,
    val connectionDialogVisible: Boolean = false,
    val connectionError: String? = null,
    val desiredConnected: Boolean = true,
    val backgroundSyncEnabled: Boolean = true,
    val navigationStyle: NavigationStyle = NavigationStyle.CLASSIC,
    val showReasoningTraces: Boolean = false,
    val notificationBoardIds: Set<String> = emptySet(),
    val endpointConnections: List<EndpointConnection> = DIETER_ENDPOINTS.map {
        EndpointConnection(it.id, it.label, it.address)
    },
    val configuredConnections: List<EndpointConnection> = DIETER_ENDPOINTS.map {
        EndpointConnection(it.id, it.label, it.address)
    },
    val activeGatewayId: String = DIETER_ENDPOINTS.first().id,
    val loading: Boolean = true,
    val working: Boolean = false,
    val error: String? = null,
    val runtimeStatus: RuntimeStatus? = null,
    val harnesses: List<Harness> = emptyList(),
    val projects: List<Project> = emptyList(),
    val projectOrder: List<String> = emptyList(),
    val projectHosts: Map<String, ProjectHost> = emptyMap(),
    val boards: List<Board> = emptyList(),
    val cards: List<Card> = emptyList(),
    val spaceBoards: List<Board> = emptyList(),
    val spaceCards: List<Card> = emptyList(),
    val spacesLoading: Boolean = false,
    val boardOverviewVisible: Boolean = true,
    val chats: List<Card> = emptyList(),
    val selectedProjectId: String = "",
    val selectedBoardId: String = "",
    val selectedLane: String = "",
    val selectedCardId: String? = null,
    val conversation: ConversationSnapshot? = null,
    val olderMessages: List<UiMessage> = emptyList(),
    val historyStart: Int = 0,
    val historyTotal: Int = 0,
    val historyHasMore: Boolean = false,
    val historyLoading: Boolean = false,
    val conversationRefreshing: Boolean = false,
    /** True while the open transcript is served from cache pending a live frame. */
    val conversationSyncing: Boolean = false,
    val conversationScrollRequest: Long = 0,
    val detailTab: Int = 0,
    val filePath: String = "",
    val files: List<FileEntry> = emptyList(),
    val showHiddenFiles: Boolean = false,
    val fileDocument: FileDocument? = null,
    val fileDraft: String = "",
    val fileDirty: Boolean = false,
    val terminals: List<Terminal> = emptyList(),
    val selectedTerminalId: String? = null,
    val terminalScreens: Map<String, TerminalScreenState> = emptyMap(),
    val terminalLoading: Boolean = false,
    val terminalStreamConnected: Boolean = false,
    val terminalCreateVisible: Boolean = false,
    val schedules: List<Schedule> = emptyList(),
    val selectedScheduleId: String? = null,
    val scheduleRuns: List<ScheduleRun> = emptyList(),
    val schedulePreview: List<String> = emptyList(),
    val settings: Settings? = null,
    val settingsOptions: SettingsOptions? = null,
    val archivedProjects: List<Project> = emptyList(),
    val archivedCards: List<Card> = emptyList(),
    val directoryListing: DirectoryListing? = null,
    val pendingCardIds: Set<String> = emptySet(),
    val pendingMessageIds: Set<String> = emptySet(),
    val acceptedOutboxIds: Set<String> = emptySet(),
    val failedOutboxIds: Set<String> = emptySet(),
    val cardOperations: Map<String, CardOperation> = emptyMap(),
    val cardOperationErrors: Map<String, String> = emptyMap(),
) {
    val connected: Boolean get() = connectionPhase == ConnectionPhase.CONNECTED
    val project: Project? get() = projects.firstOrNull { it.id == selectedProjectId }
    val board: Board? get() = boards.firstOrNull { it.id == selectedBoardId } ?: boards.firstOrNull()
    val boardNotificationsEnabled: Boolean get() = selectedBoardId in notificationBoardIds
    val selectedCard: Card?
        get() = conversation?.detail?.card
            ?: cards.firstOrNull { it.id == selectedCardId }
            ?: chats.firstOrNull { it.id == selectedCardId }
    val selectedSchedule: Schedule? get() = schedules.firstOrNull { it.id == selectedScheduleId }
    val selectedTerminal: Terminal? get() = terminals.firstOrNull { it.id == selectedTerminalId }
    val conversationMessages: List<UiMessage>
        get() {
            val live = conversation?.conversation?.messagesList.orEmpty()
            val liveIds = live.mapNotNullTo(mutableSetOf()) { it.id.takeIf(String::isNotBlank) }
            val seen = mutableSetOf<String>()
            val history = olderMessages.filter { it.id.isBlank() || it.id !in liveIds }
            return (history + live).filter { message ->
                val key = message.id.ifBlank { "anonymous:${message.hashCode()}" }
                seen.add(key)
            }
        }
}

internal fun conversationStreamNeedsRestart(activeCardId: String?, selectedCardId: String?): Boolean =
    selectedCardId != null && activeCardId != selectedCardId

class DieterViewModel(
    private val connectionManager: DieterConnectionManager,
    private val appPreferences: AppPreferences,
) : ViewModel() {
    private val repository: DieterRepository = connectionManager.repository
    private val _state = MutableStateFlow(DieterUiState())
    val state: StateFlow<DieterUiState> = _state.asStateFlow()

    private val mutationMutex = Mutex()
    private var foreground = false
    private var stateJob: Job? = null
    private var conversationJob: Job? = null
    private var terminalWatchJob: Job? = null
    private var conversationStreamCardId: String? = null
    private var terminalEndpointId: String? = null
    private val terminalSequences = mutableMapOf<String, Long>()
    private val terminalPendingInput = mutableMapOf<String, ByteArray>()
    private val terminalInputJobs = mutableMapOf<String, Job>()
    private val terminalResizeJobs = mutableMapOf<String, Job>()
    private var conversationHistoryRequestGeneration = 0L
    private var spacesJob: Job? = null
    private var connectionDialogGraceJob: Job? = null
    private var connectionDialogManuallyRequested = false
    private var lastRemoteState: State? = null
    private val conversationCache = ConversationUiCache()

    init {
        viewModelScope.launch {
            appPreferences.navigationStyle.collectLatest { style ->
                _state.update { it.copy(navigationStyle = style) }
            }
        }
        viewModelScope.launch {
            appPreferences.showReasoningTraces.collectLatest { show ->
                _state.update { it.copy(showReasoningTraces = show) }
            }
        }
        viewModelScope.launch {
            appPreferences.notificationBoardIds.collectLatest { boardIds ->
                _state.update { it.copy(notificationBoardIds = boardIds) }
            }
        }
        viewModelScope.launch {
            appPreferences.projectOrder.collectLatest { projectOrder ->
                _state.update {
                    it.copy(
                        projects = orderedProjects(it.projects, projectOrder),
                        projectOrder = projectOrder,
                    )
                }
            }
        }
    }

    fun start() {
        if (foreground) return
        foreground = true
        stateJob?.cancel()
        stateJob = viewModelScope.launch {
            connectionManager.state.collectLatest(::applyConnectionState)
        }
        connectionManager.onAppForegrounded(_state.value.selectedProjectId)
        startStateStream()
        if (_state.value.destination == Destination.TERMINALS) loadTerminals()
    }

    fun stop() {
        rememberConversation()
        foreground = false
        stateJob?.cancel()
        cancelConversationStream()
        stopTerminalWatch()
        spacesJob?.cancel()
        connectionDialogGraceJob?.cancel()
        connectionDialogGraceJob = null
        connectionManager.onAppBackgrounded()
        _state.update { it.copy(loading = false, spacesLoading = false) }
    }

    fun refresh() {
        if (connectionManager.state.value.desiredConnected) connectionManager.reconnect() else connectionManager.connect()
    }

    fun connect() {
        connectionDialogManuallyRequested = false
        connectionManager.connect()
        if (_state.value.backgroundSyncEnabled) connectionManager.requestBatteryOptimizationExemption()
    }

    fun signIn() = connectionManager.signIn()

    fun disconnect() {
        cancelConversationStream()
        connectionDialogGraceJob?.cancel()
        connectionDialogGraceJob = null
        connectionDialogManuallyRequested = false
        connectionManager.disconnect()
        _state.update {
            it.copy(
                connectionDialogVisible = true,
                connectionPhase = ConnectionPhase.STOPPED,
                desiredConnected = false,
                loading = false,
            )
        }
    }

    fun setBackgroundSyncEnabled(enabled: Boolean) {
        connectionManager.setBackgroundSyncEnabled(enabled)
        if (enabled) connectionManager.requestBatteryOptimizationExemption()
    }

    fun setNavigationStyle(style: NavigationStyle) {
        appPreferences.setNavigationStyle(style)
    }

    fun setShowReasoningTraces(show: Boolean) {
        appPreferences.setShowReasoningTraces(show)
    }

    fun setSelectedBoardNotificationsEnabled(enabled: Boolean) {
        appPreferences.setBoardNotificationsEnabled(_state.value.selectedBoardId, enabled)
    }

    fun updateConnectionTargets(endpoints: List<DieterEndpoint>, activeGatewayId: String) {
        try {
            connectionManager.updateEndpoints(endpoints, activeGatewayId)
            _state.update {
                it.copy(
                    configuredConnections = endpoints.map { endpoint ->
                        EndpointConnection(endpoint.id, endpoint.label, endpoint.address)
                    },
                    activeGatewayId = activeGatewayId,
                    error = null,
                )
            }
        } catch (error: IllegalArgumentException) {
            _state.update { it.copy(error = error.message ?: "Invalid connection settings") }
        }
    }

    fun resetConnectionTargets() {
        connectionManager.resetEndpoints()
        _state.update {
            it.copy(
                configuredConnections = DIETER_ENDPOINTS.map { endpoint ->
                    EndpointConnection(endpoint.id, endpoint.label, endpoint.address)
                },
                activeGatewayId = DIETER_ENDPOINTS.first().id,
                error = null,
            )
        }
    }

    fun selectGateway(id: String) = connectionManager.selectGateway(id)

    fun showConnectionDialog() {
        connectionDialogManuallyRequested = true
        _state.update { it.copy(connectionDialogVisible = true) }
    }

    fun showConnectionDialogIfNeeded() {
        val connection = connectionManager.state.value
        val elapsedGrace = connectionDialogDelayMs(
            connection.desiredConnected,
            connection.phase,
            connection.connectionInterruptedAtMs,
            System.currentTimeMillis(),
        ) == 0L
        if (!connection.desiredConnected || elapsedGrace) {
            connectionDialogManuallyRequested = false
            _state.update { it.copy(connectionDialogVisible = true) }
        }
    }

    fun openAppSettingsFromConnection() {
        connectionDialogManuallyRequested = false
        _state.update {
            it.copy(
                appSurface = AppSurface.APP_SETTINGS,
                connectionDialogVisible = false,
                error = null,
            )
        }
    }

    fun dismissConnectionDialog() {
        if (_state.value.connected) {
            connectionDialogManuallyRequested = false
            _state.update { it.copy(connectionDialogVisible = false) }
        }
    }

    private fun startStateStream() {
        if (!foreground) return
        connectionManager.selectProject(_state.value.selectedProjectId)
    }

    private fun applyConnectionState(connection: DieterConnectionState) {
        val connectedEndpointId = connection.endpoint?.id
        val endpointChanged = connectedEndpointId != null && connectedEndpointId != terminalEndpointId
        if (endpointChanged) {
            terminalEndpointId = connectedEndpointId
            stopTerminalWatch()
            cancelTerminalIO()
            terminalSequences.clear()
            _state.update {
                it.copy(
                    terminals = emptyList(),
                    selectedTerminalId = null,
                    terminalScreens = emptyMap(),
                    terminalStreamConnected = false,
                )
            }
        }
        val remote = connection.selectedState
        _state.update { current ->
            val selectedCardId = resolveConversationId(current.selectedCardId, connection.resolvedConversationIds)
            current.copy(
                endpoint = connection.endpoint?.address
                    ?: connection.configuredConnections.firstOrNull { it.id == connection.activeGatewayId }?.address
                    ?: current.endpoint,
                connectionPhase = connection.phase,
                connectionDialogVisible = when {
                    !connection.desiredConnected -> true
                    connection.phase == ConnectionPhase.CONNECTED && !connectionDialogManuallyRequested -> false
                    else -> current.connectionDialogVisible
                },
                connectionError = connection.error,
                desiredConnected = connection.desiredConnected,
                backgroundSyncEnabled = connection.backgroundSyncEnabled,
                configuredConnections = connection.configuredConnections,
                activeGatewayId = connection.activeGatewayId,
                endpointConnections = connection.endpointConnections,
                loading = connection.desiredConnected && remote == null && connection.phase != ConnectionPhase.UNAVAILABLE,
                runtimeStatus = connection.runtimeStatus,
                harnesses = connection.harnesses,
                chats = connection.chats,
                projects = orderedProjects(connection.projects, current.projectOrder),
                projectHosts = connection.projectHosts,
                spaceBoards = connection.boards,
                spaceCards = reconcileCardsDuringOperations(
                    remoteCards = connection.cards,
                    localCards = current.spaceCards + current.cards,
                    operations = current.cardOperations,
                ),
                selectedCardId = selectedCardId,
                conversation = selectedCardId?.let(connection.activeConversations::get) ?: current.conversation,
                schedules = connection.schedules.filter { it.projectId == current.selectedProjectId },
                scheduleRuns = current.selectedScheduleId?.let { id -> connection.scheduleRuns.filter { it.scheduleId == id } }.orEmpty(),
                pendingCardIds = connection.pendingCardIds,
                pendingMessageIds = connection.pendingMessageIds,
                acceptedOutboxIds = connection.acceptedOutboxIds,
                failedOutboxIds = connection.failedOutboxIds,
            )
        }
        val resolvedSelectedCardId = _state.value.selectedCardId
        if (foreground && conversationStreamNeedsRestart(conversationStreamCardId, resolvedSelectedCardId)) {
            startConversationStream(requireNotNull(resolvedSelectedCardId))
        }
        reconcileConnectionDialog(connection)
        if (remote != null && remote !== lastRemoteState) {
            lastRemoteState = remote
            applyRemoteState(remote)
        }
        if (endpointChanged && foreground && connection.phase == ConnectionPhase.CONNECTED &&
            _state.value.destination == Destination.TERMINALS
        ) {
            loadTerminals()
        }
    }

    private fun reconcileConnectionDialog(connection: DieterConnectionState) {
        connectionDialogGraceJob?.cancel()
        connectionDialogGraceJob = null
        when {
            !connection.desiredConnected -> {
                connectionDialogManuallyRequested = false
                _state.update { it.copy(connectionDialogVisible = true) }
            }
            connection.phase == ConnectionPhase.CONNECTED -> {
                if (!connectionDialogManuallyRequested) {
                    _state.update { it.copy(connectionDialogVisible = false) }
                }
            }
            !foreground || connection.phase == ConnectionPhase.STOPPED || _state.value.connectionDialogVisible -> Unit
            else -> {
                val waitMs = connectionDialogDelayMs(
                    connection.desiredConnected,
                    connection.phase,
                    connection.connectionInterruptedAtMs,
                    System.currentTimeMillis(),
                ) ?: return
                connectionDialogGraceJob = viewModelScope.launch {
                    delay(waitMs)
                    val latest = connectionManager.state.value
                    if (
                        foreground &&
                        latest.desiredConnected &&
                        latest.phase != ConnectionPhase.CONNECTED &&
                        latest.phase != ConnectionPhase.STOPPED
                    ) {
                        connectionDialogManuallyRequested = false
                        _state.update {
                            it.copy(
                                connectionDialogVisible = true,
                                connectionError = latest.error,
                            )
                        }
                    }
                }
            }
        }
    }

    private suspend fun retryStream(cause: Throwable, attempt: Long, label: String): Boolean {
        val code = Status.fromThrowable(cause).code
        val transient = foreground && (code == Status.Code.UNAVAILABLE || code == Status.Code.DEADLINE_EXCEEDED)
        if (!transient) return false
        _state.update {
            it.copy(
                connectionPhase = ConnectionPhase.RECONNECTING,
                loading = false,
                conversationSyncing = it.selectedCardId != null,
                connectionError = "$label connection interrupted; reconnecting…",
            )
        }
        delay((500L shl attempt.coerceAtMost(4).toInt()).coerceAtMost(8_000L))
        return true
    }

    private fun applyRemoteState(remote: State) {
        val previous = _state.value
        val projectId = remote.project.id.ifBlank {
            previous.selectedProjectId.takeIf { id -> remote.projectsList.any { it.id == id } }
                ?: remote.projectsList.firstOrNull()?.id.orEmpty()
        }
        val boardId = previous.selectedBoardId.takeIf { id -> remote.boardsList.any { it.id == id } }
            ?: remote.boardsList.firstOrNull()?.id.orEmpty()
        val board = remote.boardsList.firstOrNull { it.id == boardId }
        val lane = previous.selectedLane.takeIf { id -> board?.lanesList?.any { it.id == id } == true }
            ?: board?.lanesList?.firstOrNull()?.id.orEmpty()
        _state.update { current ->
            current.copy(
                connectionPhase = ConnectionPhase.CONNECTED,
                connectionError = null,
                loading = false,
                error = null,
                boards = remote.boardsList,
                cards = reconcileCardsDuringOperations(
                    remoteCards = remote.cardsList,
                    localCards = current.cards,
                    operations = current.cardOperations,
                ),
                selectedProjectId = projectId,
                selectedBoardId = boardId,
                selectedLane = lane,
            )
        }
        when (_state.value.destination) {
            Destination.FILES -> viewModelScope.launch { loadFiles() }
            Destination.SCHEDULES -> viewModelScope.launch { loadSchedules() }
            Destination.TERMINALS -> if (_state.value.terminals.isEmpty()) loadTerminals()
            else -> Unit
        }
    }

    fun navigate(destination: Destination) {
        rememberConversation()
        if (destination != Destination.TERMINALS) stopTerminalWatch()
        _state.update {
            it.copy(
                destination = destination,
                appSurface = null,
                editingScheduleId = null,
                selectedCardId = null,
                conversation = null,
                olderMessages = emptyList(),
                fileDocument = null,
                boardOverviewVisible = if (destination == Destination.BOARD) true else it.boardOverviewVisible,
            )
        }
        cancelConversationStream()
        when (destination) {
            Destination.CHATS -> viewModelScope.launch { loadChats() }
            Destination.FILES -> viewModelScope.launch { loadFiles() }
            Destination.SCHEDULES -> viewModelScope.launch { loadSchedules() }
            Destination.TERMINALS -> loadTerminals()
            Destination.BOARD -> refreshSpaces()
        }
    }

    fun moveProject(projectId: String, targetProjectId: String) {
        var updatedOrder: List<String>? = null
        _state.update { current ->
            val currentOrder = current.projects.map(Project::getId)
            val nextOrder = moveProjectToTarget(currentOrder, projectId, targetProjectId)
            if (nextOrder == currentOrder) {
                current
            } else {
                updatedOrder = nextOrder
                current.copy(
                    projects = orderedProjects(current.projects, nextOrder),
                    projectOrder = nextOrder,
                )
            }
        }
        updatedOrder?.let(appPreferences::setProjectOrder)
    }

    fun selectProject(id: String) {
        rememberConversation()
        cancelConversationStream()
        stopTerminalWatch()
        _state.update {
            it.copy(
                selectedProjectId = id,
                selectedBoardId = "",
                selectedLane = "",
                selectedCardId = null,
                conversation = null,
                olderMessages = emptyList(),
                filePath = "",
                fileDocument = null,
                schedules = emptyList(),
                loading = true,
            )
        }
        startStateStream()
    }

    fun selectBoard(id: String) {
        rememberConversation()
        val board = _state.value.boards.firstOrNull { it.id == id }
        _state.update {
            it.copy(
                selectedBoardId = id,
                selectedLane = board?.lanesList?.firstOrNull()?.id.orEmpty(),
                selectedCardId = null,
                conversation = null,
                olderMessages = emptyList(),
                historyStart = 0,
                historyTotal = 0,
                historyHasMore = false,
                historyLoading = false,
            )
        }
        cancelConversationStream()
    }

    fun openBoard(projectId: String, boardId: String) {
        rememberConversation()
        cancelConversationStream()
        stopTerminalWatch()
        val board = _state.value.spaceBoards.firstOrNull { it.id == boardId }
        val changingProject = projectId != _state.value.selectedProjectId
        _state.update {
            it.copy(
                destination = Destination.BOARD,
                boardOverviewVisible = false,
                selectedProjectId = projectId,
                selectedBoardId = boardId,
                selectedLane = board?.lanesList?.firstOrNull()?.id.orEmpty(),
                selectedCardId = null,
                conversation = null,
                olderMessages = emptyList(),
                historyStart = 0,
                historyTotal = 0,
                historyHasMore = false,
                historyLoading = false,
                filePath = if (changingProject) "" else it.filePath,
                fileDocument = null,
                schedules = if (changingProject) emptyList() else it.schedules,
                loading = changingProject,
            )
        }
        if (changingProject) startStateStream()
    }

    fun showBoardOverview() {
        rememberConversation()
        cancelConversationStream()
        stopTerminalWatch()
        _state.update {
            it.copy(
                destination = Destination.BOARD,
                boardOverviewVisible = true,
                selectedCardId = null,
                conversation = null,
                olderMessages = emptyList(),
            )
        }
        refreshSpaces()
    }

    fun refreshSpaces() {
        if (!foreground) return
        spacesJob?.cancel()
        spacesJob = viewModelScope.launch {
            _state.update { it.copy(spacesLoading = true) }
            val connection = connectionManager.state.value
            _state.update { it.copy(spaceBoards = connection.boards, spaceCards = connection.cards, spacesLoading = false) }
        }
    }

    fun selectLane(id: String) = _state.update { it.copy(selectedLane = id) }

    fun isPendingCard(id: String): Boolean = id in _state.value.pendingCardIds
    fun isPendingMessage(id: String): Boolean = id in _state.value.pendingMessageIds
    fun isAcceptedOutboxItem(id: String): Boolean = id in _state.value.acceptedOutboxIds
    fun isFailedOutboxItem(id: String): Boolean = id in _state.value.failedOutboxIds

    fun retryOutboxItem(id: String) {
        connectionManager.retryOutboxItem(id)
        _state.update { it.copy(error = null) }
    }

    fun discardOutboxItem(id: String) {
        connectionManager.discardOutboxItem(id)
        if (_state.value.selectedCardId == id) closeDetail()
    }

    fun selectDetailTab(index: Int) = _state.update { it.copy(detailTab = index) }

    fun openSurface(surface: AppSurface, schedule: Schedule? = null) {
        _state.update {
            it.copy(
                appSurface = surface,
                editingScheduleId = schedule?.id,
                schedulePreview = emptyList(),
                error = null,
            )
        }
        when (surface) {
            AppSurface.WORKSPACE -> loadAdministration()
            AppSurface.NEW_CHAT -> connectionManager.refreshProjectDirectory()
            else -> Unit
        }
    }

    fun closeSurface() {
        _state.update { it.copy(appSurface = null, editingScheduleId = null, schedulePreview = emptyList()) }
    }

    fun openCard(card: Card, destination: Destination = _state.value.destination) {
        rememberConversation()
        stopTerminalWatch()
        val connection = connectionManager.state.value
        val cardId = resolveConversationId(card.id, connection.resolvedConversationIds) ?: card.id
        val resolvedCard = (connection.cards + connection.chats).firstOrNull { it.id == cardId }
            ?: if (card.id == cardId) card else card.toBuilder().setId(cardId).build()
        val cached = connection.activeConversations[cardId]?.let {
            CachedConversationUi(it, emptyList(), it.page.start, it.page.total, it.page.hasMore)
        } ?: conversationCache[cardId]
        val projectId = resolvedCard.projectId.ifBlank { _state.value.selectedProjectId }
        _state.update {
            it.copy(
                destination = destination,
                boardOverviewVisible = if (destination == Destination.BOARD) false else it.boardOverviewVisible,
                selectedCardId = cardId,
                selectedProjectId = projectId,
                conversation = cached?.snapshot,
                olderMessages = cached?.olderMessages.orEmpty(),
                historyStart = cached?.historyStart ?: 0,
                historyTotal = cached?.historyTotal ?: 0,
                historyHasMore = cached?.historyHasMore ?: false,
                historyLoading = false,
                conversationRefreshing = false,
                conversationSyncing = isServerConversationId(cardId),
                conversationScrollRequest = it.conversationScrollRequest + 1,
                detailTab = 0,
                error = connectionManager.outboxFailure(cardId),
            )
        }
        connectionManager.selectProject(projectId)
        if (isServerConversationId(cardId)) startConversationStream(cardId)
    }

    fun openNotificationCard(cardId: String) {
        val card = (_state.value.chats + _state.value.cards + _state.value.spaceCards).firstOrNull { it.id == cardId } ?: return
        openCard(card, if (card.scope == "chat") Destination.CHATS else Destination.BOARD)
    }

    private fun startConversationStream(cardId: String) {
        if (!foreground) return
        cancelConversationStream()
        conversationStreamCardId = cardId
        conversationJob = viewModelScope.launch {
            val projectId = (_state.value.cards + _state.value.chats + _state.value.spaceCards)
                .firstOrNull { it.id == cardId }
                ?.projectId
                .orEmpty()
            try {
                connectionManager.ensureProjectRoute(projectId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (_state.value.selectedCardId == cardId) {
                    _state.update { it.copy(conversationSyncing = false, error = readableError(error)) }
                }
                return@launch
            }
            var delivered = false
            // Hedged unary fetch: on a healthy link the stream answers first;
            // on a dead-after-idle link this bounds time-to-fresh to seconds.
            val hedge = launch {
                val snapshot = runCatching {
                    withTimeout(HEDGE_FETCH_TIMEOUT_MS) { repository.conversation(cardId, limit = CONVERSATION_PAGE_SIZE) }
                }.getOrNull() ?: return@launch
                if (!delivered) applyLiveConversation(cardId, snapshot)
            }
            // First-frame watchdog: a stream that stays silent this long on an
            // allegedly healthy connection is riding a dead transport; rebuild
            // the channel instead of waiting for keepalive to notice.
            val watchdog = launch {
                delay(FIRST_FRAME_DEADLINE_MS)
                if (!delivered) repository.reconnect()
            }
            try {
                repository.watchConversation(cardId, CONVERSATION_PAGE_SIZE)
                    .retryWhen { cause, attempt -> retryStream(cause, attempt, "Conversation") }
                    .collectLatest { snapshot ->
                        if (_state.value.selectedCardId != cardId) return@collectLatest
                        if (!delivered) {
                            delivered = true
                            hedge.cancel()
                            watchdog.cancel()
                        }
                        applyLiveConversation(cardId, snapshot)
                    }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                hedge.cancel()
                watchdog.cancel()
                if (_state.value.selectedCardId == cardId) {
                    _state.update { it.copy(conversationSyncing = false, error = readableError(error)) }
                }
            }
        }
    }

    private fun applyLiveConversation(cardId: String, snapshot: ConversationSnapshot) {
        if (_state.value.selectedCardId != cardId) return
        val accepted = connectionManager.acceptConversation(snapshot)
        val connection = connectionManager.state.value
        _state.update { current ->
            current.copy(
                conversation = accepted,
                conversationSyncing = false,
                connectionPhase = ConnectionPhase.CONNECTED,
                error = null,
                // A foreground transcript frame is also the durable delivery
                // acknowledgement. Apply its reconciled presentation in the
                // same UI update so a conflated background state emission
                // cannot leave the bubble showing the old local receipt.
                pendingMessageIds = connection.pendingMessageIds,
                acceptedOutboxIds = connection.acceptedOutboxIds,
                failedOutboxIds = connection.failedOutboxIds,
                historyStart = if (current.historyTotal == 0) accepted.page.start else current.historyStart,
                historyTotal = maxOf(current.historyTotal, accepted.page.total),
                historyHasMore = if (current.olderMessages.isEmpty()) accepted.page.hasMore else current.historyHasMore,
            )
        }
        rememberConversation(cardId)
    }

    fun forceRefreshConversation() {
        val cardId = _state.value.selectedCardId ?: return
        viewModelScope.launch {
            mutationMutex.withLock {
                cancelConversationStream()
                _state.update { it.copy(conversationRefreshing = true, error = null) }
                try {
                    connectionManager.ensureProjectRoute(_state.value.selectedProjectId)
                    val snapshot = connectionManager.acceptConversation(
                        repository.conversation(cardId, limit = CONVERSATION_PAGE_SIZE),
                    )
                    val connection = connectionManager.state.value
                    if (_state.value.selectedCardId != cardId) return@withLock
                    _state.update { current ->
                        val liveIds = snapshot.conversation.messagesList.mapTo(mutableSetOf()) { it.id }
                        val older = current.olderMessages.filterNot { it.id in liveIds }
                        current.copy(
                            conversation = snapshot,
                            olderMessages = older,
                            historyStart = if (older.isEmpty()) snapshot.page.start else current.historyStart,
                            historyTotal = snapshot.page.total,
                            historyHasMore = if (older.isEmpty()) snapshot.page.hasMore else current.historyHasMore,
                            conversationRefreshing = false,
                            conversationSyncing = false,
                            pendingMessageIds = connection.pendingMessageIds,
                            acceptedOutboxIds = connection.acceptedOutboxIds,
                            failedOutboxIds = connection.failedOutboxIds,
                            conversationScrollRequest = current.conversationScrollRequest + 1,
                            connectionPhase = ConnectionPhase.CONNECTED,
                            error = null,
                        )
                    }
                    refreshStateOnce()
                    rememberConversation(cardId)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    _state.update { it.copy(error = readableError(error)) }
                } finally {
                    _state.update { it.copy(conversationRefreshing = false) }
                    if (foreground && _state.value.selectedCardId == cardId) startConversationStream(cardId)
                }
            }
        }
    }

    fun loadOlderMessages() {
        val current = _state.value
        val cardId = current.selectedCardId ?: return
        if (!current.historyHasMore || current.historyLoading || current.historyStart <= 0) return
        val requestGeneration = ++conversationHistoryRequestGeneration
        viewModelScope.launch {
            if (_state.value.selectedCardId != cardId) return@launch
            _state.update { it.copy(historyLoading = true) }
            try {
                connectionManager.ensureProjectRoute(_state.value.selectedProjectId)
                val page = repository.conversation(cardId, limit = CONVERSATION_PAGE_SIZE, before = current.historyStart)
                _state.update { latest ->
                    if (conversationHistoryRequestGeneration != requestGeneration ||
                        latest.selectedCardId != cardId ||
                        !latest.historyLoading
                    ) return@update latest
                    val liveIds = latest.conversation?.conversation?.messagesList.orEmpty().mapTo(mutableSetOf()) { it.id }
                    val older = (page.conversation.messagesList + latest.olderMessages)
                        .filterNot { it.id in liveIds }
                        .distinctBy { it.id }
                    latest.copy(
                        olderMessages = older,
                        historyStart = page.page.start,
                        historyTotal = page.page.total,
                        historyHasMore = page.page.hasMore,
                        historyLoading = false,
                    )
                }
                if (conversationHistoryRequestGeneration == requestGeneration) rememberConversation(cardId)
            } catch (error: Throwable) {
                _state.update { latest ->
                    if (conversationHistoryRequestGeneration != requestGeneration || latest.selectedCardId != cardId) latest
                    else latest.copy(historyLoading = false, error = readableError(error))
                }
            }
        }
    }

    suspend fun loadToolOutput(messageId: String, part: MessagePart): ToolOutput {
        val cardId = _state.value.selectedCardId ?: error("No conversation is selected")
        connectionManager.ensureProjectRoute(_state.value.selectedProjectId)
        return repository.toolOutput(cardId, messageId, part.toolCallId, part.payloadRevision)
    }

    fun closeDetail() {
        rememberConversation()
        cancelConversationStream()
        _state.update { it.copy(selectedCardId = null, conversation = null, olderMessages = emptyList()) }
    }

    private fun cancelConversationStream() {
        conversationJob?.cancel()
        conversationJob = null
        conversationStreamCardId = null
    }

    private fun rememberConversation(cardId: String? = _state.value.selectedCardId) {
        val id = cardId ?: return
        val current = _state.value
        val snapshot = current.conversation ?: return
        conversationCache.put(
            id,
            CachedConversationUi(
                snapshot = snapshot,
                olderMessages = current.olderMessages,
                historyStart = current.historyStart,
                historyTotal = current.historyTotal,
                historyHasMore = current.historyHasMore,
            ),
        )
    }

    fun createConversation(
        title: String,
        prompt: String,
        chat: Boolean,
        provider: String,
        model: String,
        effort: String,
        lane: String,
        labelIds: List<String>,
        deferStart: Boolean,
        attachments: List<MessagePart> = emptyList(),
    ) = action {
        val current = _state.value
        check(current.project != null) { "Select a project before creating a conversation." }
        val request = CreateConversationRequest.newBuilder()
            .setProjectId(current.selectedProjectId)
            .setBoardId(if (chat) "" else current.selectedBoardId)
            .setLane(if (chat) "" else lane)
            .setTitle(title)
            .setPrompt(prompt)
            .setProvider(provider)
            .setModel(model)
            .setEffort(effort)
            .addAllLabelIds(if (chat) emptyList() else labelIds)
            .setDeferStart(deferStart)
            .addAllAttachments(attachments)
            .build()
        val card = connectionManager.enqueueConversation(request, chat)
        _state.update { it.copy(appSurface = null, editingScheduleId = null) }
        if (shouldOpenCreatedConversation(chat, lane)) {
            openCard(card, if (chat) Destination.CHATS else Destination.BOARD)
        }
    }

    fun sendMessage(
        text: String,
        attachments: List<MessagePart>,
        provider: String,
        model: String,
        effort: String,
        onSent: () -> Unit = {},
    ) = action {
        val id = _state.value.selectedCardId ?: return@action
        val parts = buildList {
            if (text.isNotBlank()) add(textPart(text))
            addAll(attachments)
        }
        connectionManager.enqueueMessage(id, parts, provider, model, effort)
        onSent()
    }

    fun addComment(text: String) = action {
        val id = _state.value.selectedCardId ?: return@action
        repository.addComment(id, text)
    }

    fun moveCard(lane: String, position: Long? = null) = action {
        val id = _state.value.selectedCardId ?: return@action
        val moved = repository.moveCard(id, lane, position)
        updateCard(moved)
    }

    fun moveBoardCard(cardId: String, lane: String) = action {
        updateCard(repository.moveCard(cardId, lane))
    }

    fun startBoardCard(cardId: String) {
        val current = _state.value
        val card = current.cards.firstOrNull { it.id == cardId } ?: return
        val board = current.board?.takeIf { it.id == card.boardId }
            ?: current.boards.firstOrNull { it.id == card.boardId }
        startCard(card, board)
    }

    fun startSelectedCard() {
        val current = _state.value
        val card = current.selectedCard ?: return
        val board = current.conversation?.detail?.board ?: current.board
        startCard(card, board)
    }

    fun markDone() {
        val doneLane = _state.value.board?.lanesList?.lastOrNull()?.id ?: "done"
        moveCard(doneLane)
    }

    fun setSelectedCardLabels(labelIds: List<String>) = action {
        val id = _state.value.selectedCardId ?: return@action
        updateCard(repository.setCardLabels(id, labelIds))
    }

    fun assignLabelToBoardCard(cardId: String, labelId: String) {
        val snapshot = _state.value
        val board = snapshot.board ?: return
        val card = snapshot.cards.firstOrNull { it.id == cardId && it.boardId == board.id } ?: return
        if (board.labelsList.none { it.id == labelId }) return
        val existingLabelIds = card.labelIdsList
        val labelIds = assignCardLabel(existingLabelIds, labelId)
        if (labelIds === existingLabelIds) return
        action { updateCard(repository.setCardLabels(cardId, labelIds)) }
    }

    fun cancelSelected() {
        val id = _state.value.selectedCardId ?: return
        cardAction(id, CardOperation.CANCELLING) { repository.cancelCard(id) }
    }

    fun renameSelected(title: String) = action {
        val id = _state.value.selectedCardId ?: return@action
        updateCard(repository.renameCard(id, title))
    }

    fun editBoardCard(cardId: String, title: String, initialPrompt: String) = action {
        updateCard(repository.updateCard(cardId, title, initialPrompt))
    }

    fun archiveSelected() = action {
        val card = _state.value.selectedCard ?: return@action
        repository.archiveCard(card.id, !card.archived)
        closeDetail()
        refreshStateOnce()
    }

    fun archiveBoardCard(cardId: String) = action {
        repository.archiveCard(cardId, true)
        _state.update { current -> current.copy(cards = current.cards.filterNot { it.id == cardId }) }
        refreshStateOnce()
    }

    private fun startCard(card: Card, board: Board?) {
        val optimistic = card.optimisticStart(board) ?: return
        cardAction(
            cardId = card.id,
            operation = CardOperation.STARTING,
            prepare = { current ->
                current.replacingCard(optimistic).copy(selectedLane = optimistic.lane)
            },
            rollback = { current ->
                current.replacingCard(card).copy(
                    selectedLane = card.lane.takeIf { current.selectedLane == optimistic.lane }
                        ?: current.selectedLane,
                )
            },
        ) {
            val response = connectionManager.startCard(card.id)
            updateCard(response.card)
        }
    }

    fun togglePin(card: Card) = action {
        updateCard(repository.pinChat(card.id, !card.pinned))
        loadChats()
    }

    private fun updateCard(card: Card) {
        _state.update { it.replacingCard(card) }
    }

    private fun DieterUiState.replacingCard(card: Card): DieterUiState = copy(
        cards = cards.map { if (it.id == card.id) card else it },
        spaceCards = spaceCards.map { if (it.id == card.id) card else it },
        chats = chats.map { if (it.id == card.id) card else it },
        conversation = conversation?.takeIf { it.detail.card.id == card.id }?.toBuilder()
            ?.setDetail(conversation.detail.toBuilder().setCard(card))
            ?.build() ?: conversation,
    )

    private suspend fun loadChats() {
        _state.update { it.copy(chats = connectionManager.state.value.chats, error = null) }
    }

    fun openDirectory(path: String) = action { loadFiles(path) }

    fun openParentDirectory() {
        val path = _state.value.filePath.substringBeforeLast('/', "")
        openDirectory(path)
    }

    fun setShowHiddenFiles(show: Boolean) {
        _state.update { it.copy(showHiddenFiles = show) }
        viewModelScope.launch { loadFiles() }
    }

    private suspend fun loadFiles(path: String = _state.value.filePath) {
        val projectId = _state.value.selectedProjectId
        if (projectId.isBlank()) return
        connectionManager.ensureProjectRoute(projectId)
        val list = repository.files(projectId, path, _state.value.showHiddenFiles)
        _state.update { it.copy(filePath = list.path, files = list.entriesList, fileDocument = null, fileDraft = "", fileDirty = false) }
    }

    fun openFile(path: String) = action {
        val document = repository.readFile(_state.value.selectedProjectId, path)
        _state.update { it.copy(fileDocument = document, fileDraft = document.content, fileDirty = false) }
    }

    fun updateFileDraft(content: String) = _state.update { state ->
        state.copy(fileDraft = content, fileDirty = content != state.fileDocument?.content)
    }

    fun saveFile() = action {
        val current = _state.value
        val document = current.fileDocument ?: return@action
        val saved = repository.saveFile(current.selectedProjectId, document.path, current.fileDraft, document.revision)
        _state.update { it.copy(fileDocument = saved, fileDraft = saved.content, fileDirty = false) }
    }

    fun createFile(path: String, directory: Boolean) = action {
        val current = _state.value
        repository.createFile(current.selectedProjectId, path, if (directory) "directory" else "file")
        loadFiles()
    }

    fun moveFile(source: String, destination: String) = action {
        repository.moveFile(_state.value.selectedProjectId, source, destination)
        _state.update { it.copy(fileDocument = null, fileDraft = "", fileDirty = false) }
        loadFiles()
    }

    fun deleteFile(path: String, recursive: Boolean) = action {
        repository.deleteFile(_state.value.selectedProjectId, path, recursive)
        _state.update { it.copy(fileDocument = null, fileDraft = "", fileDirty = false) }
        loadFiles()
    }

    fun closeFile(force: Boolean = false): Boolean {
        if (_state.value.fileDirty && !force) return false
        _state.update { it.copy(fileDocument = null, fileDraft = "", fileDirty = false) }
        return true
    }

    fun loadTerminals() {
        if (!foreground || _state.value.connectionPhase != ConnectionPhase.CONNECTED) return
        viewModelScope.launch {
            _state.update { it.copy(terminalLoading = true, error = null) }
            try {
                val terminals = repository.terminals().terminalsList.sortedWith(
                    compareBy<Terminal> { it.createdAt }.thenBy { it.id },
                )
                _state.update { current ->
                    val live = terminals.mapTo(mutableSetOf(), Terminal::getId)
                    val selected = current.selectedTerminalId?.takeIf(live::contains) ?: terminals.firstOrNull()?.id
                    current.copy(
                        terminals = terminals,
                        selectedTerminalId = selected,
                        terminalScreens = current.terminalScreens.filterKeys(live::contains),
                        terminalLoading = false,
                    )
                }
                terminalSequences.keys.retainAll(terminals.mapTo(mutableSetOf(), Terminal::getId))
                startTerminalWatch()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                _state.update { it.copy(terminalLoading = false, error = readableTerminalError(error)) }
            }
        }
    }

    fun showTerminalCreate() {
        _state.update { it.copy(terminalCreateVisible = true, error = null) }
    }

    fun dismissTerminalCreate() {
        _state.update { it.copy(terminalCreateVisible = false) }
    }

    fun selectTerminal(terminalId: String) {
        if (_state.value.terminals.none { it.id == terminalId }) return
        _state.update { it.copy(selectedTerminalId = terminalId) }
        startTerminalWatch()
    }

    fun createTerminal(
        projectId: String,
        name: String,
        shell: String,
        workingDirectory: String,
        onCreated: () -> Unit = {},
    ) {
        viewModelScope.launch {
            _state.update { it.copy(terminalLoading = true, error = null) }
            try {
                connectionManager.ensureProjectRoute(projectId)
                val terminal = repository.createTerminal(
                    CreateTerminalRequest.newBuilder()
                        .setProjectId(projectId)
                        .setName(name.trim())
                        .setShell(shell)
                        .setWorkingDirectory(workingDirectory.trim())
                        .setColumns(80)
                        .setRows(28)
                        .build(),
                )
                terminalSequences[terminal.id] = 0
                _state.update { current ->
                    current.copy(
                        destination = Destination.TERMINALS,
                        terminals = upsertTerminal(current.terminals, terminal),
                        selectedTerminalId = terminal.id,
                        terminalScreens = current.terminalScreens + (terminal.id to TerminalScreenState()),
                        terminalLoading = false,
                        terminalCreateVisible = false,
                    )
                }
                startTerminalWatch()
                onCreated()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                _state.update { it.copy(terminalLoading = false, error = readableTerminalError(error)) }
            }
        }
    }

    fun sendTerminalInput(terminalId: String, data: ByteArray) {
        if (data.isEmpty() || _state.value.terminals.none { it.id == terminalId && it.status == "running" }) return
        terminalPendingInput[terminalId] = terminalPendingInput[terminalId]?.plus(data) ?: data.copyOf()
        if (terminalInputJobs[terminalId]?.isActive == true) return
        terminalInputJobs[terminalId] = viewModelScope.launch {
            try {
                while (true) {
                    delay(12)
                    val pending = terminalPendingInput.remove(terminalId) ?: break
                    terminalInputChunks(pending).forEach { repository.writeTerminal(terminalId, it) }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                _state.update { it.copy(terminalStreamConnected = false, error = "Terminal input paused: ${readableError(error)}") }
            } finally {
                terminalInputJobs.remove(terminalId)
                if (terminalPendingInput[terminalId]?.isNotEmpty() == true) {
                    terminalPendingInput.remove(terminalId)?.let { sendTerminalInput(terminalId, it) }
                }
            }
        }
    }

    fun resizeTerminal(terminalId: String, columns: Int, rows: Int) {
        if (columns !in 2..500 || rows !in 2..500) return
        terminalResizeJobs.remove(terminalId)?.cancel()
        terminalResizeJobs[terminalId] = viewModelScope.launch {
            delay(120)
            try {
                upsertTerminal(repository.resizeTerminal(terminalId, columns, rows))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (_state.value.terminals.any { it.id == terminalId }) {
                    _state.update { it.copy(error = readableError(error)) }
                }
            }
        }
    }

    fun renameTerminal(terminalId: String, name: String) {
        val normalized = name.trim()
        if (normalized.isEmpty()) return
        viewModelScope.launch {
            try {
                upsertTerminal(repository.renameTerminal(terminalId, normalized))
            } catch (error: Throwable) {
                _state.update { it.copy(error = readableError(error)) }
            }
        }
    }

    fun closeTerminal(terminalId: String) {
        viewModelScope.launch {
            try {
                repository.closeTerminal(terminalId)
                terminalSequences.remove(terminalId)
                terminalPendingInput.remove(terminalId)
                terminalInputJobs.remove(terminalId)?.cancel()
                terminalResizeJobs.remove(terminalId)?.cancel()
                _state.update { current ->
                    val terminals = current.terminals.filterNot { it.id == terminalId }
                    current.copy(
                        terminals = terminals,
                        selectedTerminalId = if (current.selectedTerminalId == terminalId) terminals.firstOrNull()?.id else current.selectedTerminalId,
                        terminalScreens = current.terminalScreens - terminalId,
                    )
                }
                startTerminalWatch()
            } catch (error: Throwable) {
                _state.update { it.copy(error = readableError(error)) }
            }
        }
    }

    private fun startTerminalWatch() {
        stopTerminalWatch()
        val terminalId = _state.value.selectedTerminalId ?: return
        if (!foreground || _state.value.destination != Destination.TERMINALS) return
        terminalWatchJob = viewModelScope.launch {
            var delayMs = 500L
            while (_state.value.destination == Destination.TERMINALS && _state.value.selectedTerminalId == terminalId) {
                try {
                    _state.update { it.copy(terminalStreamConnected = true) }
                    repository.watchTerminal(terminalId, terminalSequences[terminalId] ?: 0).collectLatest { frame ->
                        acceptTerminalFrame(terminalId, frame)
                    }
                    _state.update { it.copy(terminalStreamConnected = false) }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    _state.update { it.copy(terminalStreamConnected = false) }
                    if (Status.fromThrowable(error).code == Status.Code.NOT_FOUND) {
                        _state.update { current ->
                            val terminals = current.terminals.filterNot { it.id == terminalId }
                            current.copy(
                                terminals = terminals,
                                selectedTerminalId = terminals.firstOrNull()?.id,
                                terminalScreens = current.terminalScreens - terminalId,
                            )
                        }
                        return@launch
                    }
                }
                delay(delayMs)
                delayMs = (delayMs * 1.8).toLong().coerceAtMost(5_000)
            }
        }
    }

    private fun stopTerminalWatch() {
        terminalWatchJob?.cancel()
        terminalWatchJob = null
        _state.update { it.copy(terminalStreamConnected = false) }
    }

    private fun cancelTerminalIO() {
        terminalInputJobs.values.forEach { it.cancel() }
        terminalResizeJobs.values.forEach { it.cancel() }
        terminalInputJobs.clear()
        terminalResizeJobs.clear()
        terminalPendingInput.clear()
    }

    private fun acceptTerminalFrame(terminalId: String, frame: TerminalFrame) {
        if (frame.hasTerminal() && frame.terminal.id == terminalId) upsertTerminal(frame.terminal)
        terminalSequences[terminalId] = maxOf(terminalSequences[terminalId] ?: 0, frame.sequence)
        if (!frame.screenReset && frame.data.isEmpty) return
        _state.update { current ->
            current.copy(
                terminalStreamConnected = true,
                terminalScreens = current.terminalScreens + (
                    terminalId to TerminalScreenReducer.apply(
                        current = current.terminalScreens[terminalId] ?: TerminalScreenState(),
                        data = frame.data.toByteArray(),
                        screenReset = frame.screenReset,
                    )
                ),
            )
        }
    }

    private fun upsertTerminal(terminal: Terminal) {
        _state.update { it.copy(terminals = upsertTerminal(it.terminals, terminal)) }
    }

    private fun upsertTerminal(terminals: List<Terminal>, terminal: Terminal): List<Terminal> =
        (terminals.filterNot { it.id == terminal.id } + terminal).sortedWith(
            compareBy<Terminal> { it.createdAt }.thenBy { it.id },
        )

    private suspend fun loadSchedules() {
        val projectId = _state.value.selectedProjectId
        if (projectId.isBlank()) return
        _state.update { it.copy(schedules = connectionManager.state.value.schedules.filter { schedule -> schedule.projectId == projectId }) }
    }

    fun previewSchedule(cron: String, timezone: String) {
        viewModelScope.launch {
            try {
                connectionManager.ensureProjectRoute(_state.value.selectedProjectId)
                val result = repository.previewSchedule(cron, timezone)
                _state.update { it.copy(schedulePreview = result.timesList, error = null) }
            } catch (error: Throwable) {
                _state.update { it.copy(schedulePreview = emptyList(), error = readableError(error)) }
            }
        }
    }

    fun saveSchedule(scheduleId: String, draft: ScheduleDraft) = action {
        repository.saveSchedule(
            scheduleId,
            SaveScheduleRequest.newBuilder().setScheduleId(scheduleId).setSchedule(draft).build(),
        )
        loadSchedules()
        _state.update { it.copy(appSurface = null, editingScheduleId = null, schedulePreview = emptyList()) }
    }

    fun selectSchedule(schedule: Schedule?) {
        _state.update {
            it.copy(
                selectedScheduleId = schedule?.id,
                scheduleRuns = schedule?.let { selected -> connectionManager.state.value.scheduleRuns.filter { run -> run.scheduleId == selected.id } }.orEmpty(),
            )
        }
    }

    fun toggleSchedule(schedule: Schedule) = action {
        repository.setScheduleEnabled(schedule.id, !schedule.enabled)
        loadSchedules()
    }

    fun runSchedule(schedule: Schedule) = action {
        repository.runSchedule(schedule.id)
        loadSchedules()
        selectSchedule(schedule)
    }

    fun deleteSchedule(schedule: Schedule) = action {
        repository.deleteSchedule(schedule.id)
        if (_state.value.selectedScheduleId == schedule.id) selectSchedule(null)
        loadSchedules()
    }

    fun loadAdministration() {
        viewModelScope.launch {
            try {
                connectionManager.ensureProjectRoute(_state.value.selectedProjectId)
                val (settings, options, archivedProjects) = coroutineScope {
                    val settings = async { repository.settings() }
                    val options = async { repository.settingsOptions() }
                    val archived = async { repository.archivedProjects() }
                    Triple(settings.await(), options.await(), archived.await())
                }
                val boardId = _state.value.selectedBoardId
                val archivedCards = if (boardId.isBlank()) emptyList() else repository.archivedCards(boardId).cardsList
                _state.update {
                    it.copy(
                        settings = settings,
                        settingsOptions = options,
                        archivedProjects = archivedProjects.projectsList,
                        archivedCards = archivedCards,
                    )
                }
            } catch (error: Throwable) {
                _state.update { it.copy(error = readableError(error)) }
            }
        }
    }

    fun listDirectories(path: String = "") {
        viewModelScope.launch {
            try {
                connectionManager.ensureProjectRoute(_state.value.selectedProjectId)
                _state.update { it.copy(directoryListing = repository.listDirectories(path)) }
            } catch (error: Throwable) {
                _state.update { it.copy(error = readableError(error)) }
            }
        }
    }

    fun createProject(mode: String, path: String, name: String, summary: String, prompt: String, boardName: String, workflow: String) = action {
        val created = repository.createProject(
            CreateProjectRequest.newBuilder()
                .setMode(mode)
                .setPath(path)
                .setName(name)
                .setSummary(summary)
                .setPrompt(prompt)
                .setBoardName(boardName)
                .setWorkflow(workflow)
                .build(),
        )
        _state.update {
            it.copy(
                selectedProjectId = created.project.id,
                selectedBoardId = created.board.id,
                boardOverviewVisible = false,
                appSurface = null,
                editingScheduleId = null,
            )
        }
        startStateStream()
    }

    fun updateProject(name: String?, summary: String?, prompt: String?) = action {
        val builder = UpdateProjectRequest.newBuilder().setProjectId(_state.value.selectedProjectId)
        if (name != null) builder.name = name
        if (summary != null) builder.summary = summary
        if (prompt != null) builder.prompt = prompt
        repository.updateProject(builder.build())
        refreshStateOnce()
    }

    fun archiveCurrentProject() = action {
        val projectId = _state.value.selectedProjectId
        if (projectId.isBlank()) return@action
        repository.archiveProject(projectId, true)
        _state.update { it.copy(selectedProjectId = "", selectedBoardId = "") }
        startStateStream()
    }

    fun restoreProject(project: Project) = action {
        repository.archiveProject(project.id, false)
        _state.update { it.copy(selectedProjectId = project.id) }
        startStateStream()
    }

    fun restoreCard(card: Card) = action {
        repository.archiveCard(card.id, false)
        loadAdministration()
        refreshStateOnce()
    }

    fun createBoard(name: String, workflow: String, description: String, openAfterCreate: Boolean = false) = action {
        val board = repository.createBoard(
            CreateBoardRequest.newBuilder()
                .setProjectId(_state.value.selectedProjectId)
                .setName(name)
                .setWorkflow(workflow)
                .setDescription(description)
                .setDoneArchivePolicy("never")
                .build(),
        )
        _state.update {
            it.copy(
                selectedBoardId = board.id,
                appSurface = if (openAfterCreate) null else it.appSurface,
                boardOverviewVisible = if (openAfterCreate) false else it.boardOverviewVisible,
            )
        }
        refreshStateOnce()
        refreshSpaces()
    }

    fun setBoardArchivePolicy(policy: String) = action {
        repository.setBoardArchivePolicy(_state.value.selectedBoardId, policy)
        refreshStateOnce()
    }

    fun createBoardLabel(name: String, color: String) = action {
        repository.createBoardLabel(_state.value.selectedBoardId, name, color)
        refreshStateOnce()
    }

    fun deleteBoardLabel(labelId: String) = action {
        repository.deleteBoardLabel(_state.value.selectedBoardId, labelId)
        refreshStateOnce()
    }

    fun updateSettings(settings: Settings) = action {
        _state.update { it.copy(settings = repository.updateSettings(settings)) }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    private fun action(block: suspend () -> Unit) {
        viewModelScope.launch {
            mutationMutex.withLock {
                _state.update { it.copy(working = true, error = null) }
                try {
                    connectionManager.ensureProjectRoute(_state.value.selectedProjectId)
                    block()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    _state.update { it.copy(error = readableError(error)) }
                } finally {
                    _state.update { it.copy(working = false) }
                }
            }
        }
    }

    private fun cardAction(
        cardId: String,
        operation: CardOperation,
        prepare: (DieterUiState) -> DieterUiState = { it },
        rollback: ((DieterUiState) -> DieterUiState)? = null,
        block: suspend () -> Unit,
    ) {
        if (_state.value.cardOperations.containsKey(cardId)) return
        _state.update { current ->
            prepare(current).let {
                it.copy(
                    cardOperations = it.cardOperations + (cardId to operation),
                    cardOperationErrors = it.cardOperationErrors - cardId,
                )
            }
        }
        viewModelScope.launch {
            try {
                block()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                val message = readableError(error)
                _state.update { current ->
                    (rollback?.invoke(current) ?: current).copy(
                        error = message,
                        cardOperationErrors = current.cardOperationErrors + (cardId to message),
                    )
                }
            } finally {
                _state.update { it.copy(cardOperations = it.cardOperations - cardId) }
            }
        }
    }

    private suspend fun refreshStateOnce() {
        connectionManager.state.value.selectedState?.let(::applyRemoteState)
    }

    private suspend fun <T> runFeatureCall(apply: (T) -> Unit, block: suspend () -> T) {
        try {
            apply(block())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            _state.update { it.copy(error = readableError(error)) }
        }
    }

    override fun onCleared() {
        stopTerminalWatch()
        cancelTerminalIO()
        connectionManager.onAppBackgrounded()
    }

    private fun readableTerminalError(error: Throwable): String {
        val status = Status.fromThrowable(error)
        if (status.code == Status.Code.UNIMPLEMENTED || status.description?.contains("404 (Not Found)") == true) {
            return "This gateway needs the terminal-forwarding update. Update it, then refresh terminals."
        }
        return readableError(error)
    }

    private fun readableError(error: Throwable): String {
        val status = Status.fromThrowable(error)
        return status.description?.takeIf { it.isNotBlank() }
            ?: error.message?.substringBefore('\n')
            ?: "Dieter could not complete the request"
    }

    class Factory(
        private val connectionManager: DieterConnectionManager,
        private val appPreferences: AppPreferences,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = DieterViewModel(connectionManager, appPreferences) as T
    }

    companion object {
        fun textPart(text: String): MessagePart = MessagePart.newBuilder().setType("text").setText(text).build()

        fun defaultScheduleDraft(projectId: String, boardId: String): ScheduleDraft = ScheduleDraft.newBuilder()
            .setProjectId(projectId)
            .setBoardId(boardId)
            .setTimezone(ZoneId.systemDefault().id)
            .setEnabled(true)
            .setAction("draft")
            .setTitleTemplate("Scheduled work · {{date}}")
            .setOpenCardPolicy("skip_if_open")
            .setMisfirePolicy("latest")
            .setBusyPolicy("queue")
            .build()
    }
}
