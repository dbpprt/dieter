package com.dbpprt.dieter.ui

import androidx.compose.runtime.Immutable
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.DirectoryListing
import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.api.v1.FileEntry
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.ScheduleRun
import com.dbpprt.dieter.api.v1.Settings
import com.dbpprt.dieter.api.v1.SettingsOptions
import com.dbpprt.dieter.api.v1.Terminal
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.core.activity.ActivityItem
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.core.admin.MachineSnapshot
import com.dbpprt.dieter.core.board.CardOperation
import com.dbpprt.dieter.core.board.PendingMove
import com.dbpprt.dieter.core.composition.ConversationDraft
import com.dbpprt.dieter.core.connection.Availability
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.conversation.ConversationView
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.outbox.MachineOutboxSummary
import com.dbpprt.dieter.core.schedules.SchedulesView
import com.dbpprt.dieter.core.terminals.TerminalScreen
import com.dbpprt.dieter.core.terminals.TerminalsView
import com.dbpprt.dieter.core.workspace.ProjectChangesView
import com.dbpprt.dieter.core.workspace.WorkspaceReviewView
import com.dbpprt.dieter.settings.DEFAULT_PANE_LEADING_FRACTION
import com.dbpprt.dieter.settings.DEFAULT_SIDEBAR_LEADING_FRACTION
import com.dbpprt.dieter.settings.DieterPalette

enum class AppSurface { NEW_CHAT, NEW_CARD, NEW_BOARD, SCHEDULE_EDITOR, WORKSPACE, NEW_PROJECT, APP_SETTINGS }

/** The machine that last listed a project. */
@Immutable
data class ProjectReplica(val endpointId: String, val daemonId: String, val hostname: String, val online: Boolean)

/** Board administration data loaded on demand for the workspace sheet. */
@Immutable
data class AdministrationState(
    val settings: Settings? = null,
    val settingsOptions: SettingsOptions? = null,
    val archivedProjects: List<Project> = emptyList(),
    val archivedCards: List<Card> = emptyList(),
)

@Immutable
data class DieterUiState(
    val sharedConflicts: List<PeerRecord> = emptyList(),
    val creationCheckoutId: String = "",
    val destination: Destination = Destination.ACTIVITY,
    val appSurface: AppSurface? = null,
    val editingScheduleId: String? = null,
    val endpoint: String = Gateway.DEFAULT.httpBase,
    val connectionPhase: ConnectionPhase = ConnectionPhase.DISCONNECTED,
    val lastConnectedAtMillis: Long? = null,
    val connectionDialogVisible: Boolean = false,
    val connectionError: String? = null,
    val desiredConnected: Boolean = true,
    val signedIn: Boolean = false,
    val backgroundSyncMode: BackgroundMode = BackgroundMode.LIVE,
    val palette: DieterPalette = DieterPalette.DEFAULT,
    val showReasoningTraces: Boolean = false,
    val notificationBoardIds: Set<String> = emptySet(),
    val notificationSettings: NotificationSettings = NotificationSettings(),
    val endpointConnections: List<MachineRow> = emptyList(),
    val gateways: List<Gateway> = listOf(Gateway.DEFAULT),
    val activeGatewayId: String = Gateway.DEFAULT.origin,
    val loading: Boolean = true,
    val working: Boolean = false,
    val error: String? = null,
    val harnesses: List<Harness> = emptyList(),
    val harnessesEndpointId: String? = null,
    val providerQuotaGroups: List<ProviderQuotaGroup> = emptyList(),
    val providerQuotasLoading: Boolean = false,
    val providerQuotaError: String? = null,
    val providerQuotaMutatingAccounts: Set<String> = emptySet(),
    val projects: List<Project> = emptyList(),
    val pinnedProjectOrder: List<String> = emptyList(),
    /** Folders, orders, disclosure, and lane sort, shared across the account. */
    val navigationLayout: NavigationLayout = NavigationLayout(emptyMap()),
    val navigationPendingCount: Int = 0,
    val navigationSyncError: String? = null,
    val peerSyncWarnings: List<String> = emptyList(),
    val retiredBoards: List<Board> = emptyList(),
    val projectFolders: List<NavigationFolder> = emptyList(),
    val chatFolders: List<NavigationFolder> = emptyList(),
    val collapsedChatProjectIds: Set<String> = emptySet(),
    val expandedChatProjectIds: Set<String> = emptySet(),
    val pinnedChatOrder: List<String> = emptyList(),
    val chatsPaneLeadingFraction: Float = DEFAULT_PANE_LEADING_FRACTION,
    val activityPaneLeadingFraction: Float = DEFAULT_SIDEBAR_LEADING_FRACTION,
    val projectsPaneLeadingFraction: Float = DEFAULT_SIDEBAR_LEADING_FRACTION,
    val boardPaneLeadingFraction: Float = DEFAULT_PANE_LEADING_FRACTION,
    val projectReplicas: Map<String, ProjectReplica> = emptyMap(),
    /** The selected project's boards and cards. */
    val boards: List<Board> = emptyList(),
    val cards: List<Card> = emptyList(),
    /** Every project's boards and cards. */
    val spaceBoards: List<Board> = emptyList(),
    val spaceCards: List<Card> = emptyList(),
    val activityItems: List<ActivityItem> = emptyList(),
    val spacesLoading: Boolean = false,
    val boardOverviewVisible: Boolean = true,
    /** Unfiled chats, newest activity first. */
    val chats: List<Card> = emptyList(),
    val selectedProjectId: String = "",
    val selectedBoardId: String = "",
    val selectedLane: String = "",
    val selectedCardId: String? = null,
    val conversation: ConversationSnapshot? = null,
    /** The open conversation as the core presents it. */
    val conversationView: ConversationView? = null,
    val historyStart: Int = 0,
    val historyTotal: Int = 0,
    val historyHasMore: Boolean = false,
    val historyLoading: Boolean = false,
    val conversationRefreshing: Boolean = false,
    val conversationSyncing: Boolean = false,
    val conversationLastRefreshedAtMillis: Long? = null,
    val conversationScrollRequest: Long = 0,
    val detailTab: Int = 0,
    val filePath: String = "",
    val files: List<FileEntry> = emptyList(),
    val showHiddenFiles: Boolean = false,
    val fileDocument: FileDocument? = null,
    val fileDraft: String = "",
    val fileDirty: Boolean = false,
    /** The last save hit a newer version on disk; the draft is kept. */
    val fileConflict: Boolean = false,
    val projectFilesMode: String = "browse",
    val projectChanges: ProjectChangesView = ProjectChangesView(),
    val terminalWorkspace: TerminalsView = TerminalsView(),
    val terminalCreateVisible: Boolean = false,
    val scheduleWorkspace: SchedulesView = SchedulesView(),
    val administration: AdministrationState = AdministrationState(),
    val directoryListing: DirectoryListing? = null,
    val directoryListingEndpointId: String = "",
    val directoryListingLoading: Boolean = false,
    val composerDraft: ConversationDraft = ConversationDraft(),
    val projectWorkspaces: List<Workspace> = emptyList(),
    val projectWorkspacesLoading: Boolean = false,
    val projectWorkspaceOperations: Set<String> = emptySet(),
    val projectWorkspaceErrors: Map<String, String> = emptyMap(),
    val pendingCardIds: Set<String> = emptySet(),
    val pendingMessageIds: Set<String> = emptySet(),
    val acceptedOutboxIds: Set<String> = emptySet(),
    val failedOutboxIds: Set<String> = emptySet(),
    val machineOutboxSummaries: Map<String, MachineOutboxSummary> = emptyMap(),
    val selectedMachineId: String? = null,
    /** Every machine's latest information, load, and read state. */
    val machineSnapshots: Map<String, MachineSnapshot> = emptyMap(),
    val machineOperationInFlight: Boolean = false,
    val machineOperationMessage: String? = null,
    val cardOperations: Map<String, CardOperation> = emptyMap(),
    val cardOperationErrors: Map<String, String> = emptyMap(),
    val pendingCardMoves: Map<String, PendingMove> = emptyMap(),
    val workspaceReview: WorkspaceReviewView = WorkspaceReviewView(),
) {
    fun conversationHost(card: Card): ProjectReplica? = presentedEndpointConnections.firstOrNull { it.daemonId == card.owner_daemon_id }?.let {
        ProjectReplica(it.id, it.daemonId.orEmpty(), it.label, it.online)
    }
    val connected: Boolean get() = connectionPhase == ConnectionPhase.CONNECTED
    val backgroundSyncEnabled: Boolean get() = backgroundSyncMode.usesBackgroundService
    val hasCachedWorkspace: Boolean
        get() = projects.isNotEmpty() || boards.isNotEmpty() || cards.isNotEmpty() || chats.isNotEmpty()
    /** Files and schedules need a project whose machine is not known to be offline. */
    val projectSurfacesEnabled: Boolean
        get() = Availability.projectScopedEnabled(projects.map { it.id }) { presentedProjectReplicas[it]?.online }
    val presentedProjectReplicas: Map<String, ProjectReplica>
        get() = if (connected) projectReplicas else projectReplicas.mapValues { (_, host) -> host.copy(online = false) }

    /** Machines, plus rows for machines that only have queued changes; cached presence is never online while disconnected. */
    val presentedEndpointConnections: List<MachineRow>
        get() = MachineRows.presented(
            endpointConnections,
            connectionPhase,
            machineOutboxSummaries.keys,
            projectReplicas.values.associate { it.endpointId to it.hostname },
        )
    val project: Project? get() = projects.firstOrNull { it.id == selectedProjectId }
    val board: Board? get() = boards.firstOrNull { it.id == selectedBoardId } ?: retiredBoards.firstOrNull { it.id == selectedBoardId } ?: boards.firstOrNull()
    val boardNotificationsEnabled: Boolean get() = selectedBoardId in notificationBoardIds
    val selectedCard: Card?
        get() = conversation?.detail?.card
            ?: cards.firstOrNull { it.id == selectedCardId }
            ?: chats.firstOrNull { it.id == selectedCardId }
            ?: spaceCards.firstOrNull { it.id == selectedCardId }
    val schedules: List<Schedule> get() = scheduleWorkspace.schedules
    val schedulesTotalCount: Int get() = scheduleWorkspace.totalCount
    val schedulesNextPageToken: String get() = scheduleWorkspace.nextPageToken
    val schedulesLoading: Boolean get() = scheduleWorkspace.loading
    val schedulesLoadingMore: Boolean get() = scheduleWorkspace.loadingMore
    val selectedScheduleId: String? get() = scheduleWorkspace.selectedId
    val scheduleRuns: List<ScheduleRun> get() = scheduleWorkspace.runs
    val scheduleRunsNextPageToken: String get() = scheduleWorkspace.runsNextPageToken
    val scheduleRunsLoading: Boolean get() = scheduleWorkspace.runsLoading
    val scheduleRunsLoadingMore: Boolean get() = scheduleWorkspace.runsLoadingMore
    val schedulePreview: List<String> get() = scheduleWorkspace.preview
    val settings: Settings? get() = administration.settings
    val settingsOptions: SettingsOptions? get() = administration.settingsOptions
    val archivedProjects: List<Project> get() = administration.archivedProjects
    val archivedCards: List<Card> get() = administration.archivedCards
    val selectedSchedule: Schedule? get() = schedules.firstOrNull { it.id == selectedScheduleId }
    val terminals: List<Terminal> get() = terminalWorkspace.terminals
    val selectedTerminalId: String? get() = terminalWorkspace.selectedId
    val terminalScreens: Map<String, TerminalScreen> get() = terminalWorkspace.screens
    val terminalLoading: Boolean get() = terminalWorkspace.loading
    val terminalStreamConnected: Boolean get() = terminalWorkspace.streamConnected
    val selectedTerminal: Terminal? get() = terminalWorkspace.selected
    /** Loaded history and the live window, as the core merges them. */
    val conversationMessages: List<UiMessage>
        get() = conversationView?.messages ?: conversation?.conversation?.messages.orEmpty()
}
