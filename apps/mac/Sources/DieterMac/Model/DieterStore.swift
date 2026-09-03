import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
// Feature extensions share module-internal state without exposing a public API.
final class DieterStore {
    struct PendingChatPin {
        let operationID: UUID
        let pinned: Bool
        let original: Dieter_V1_Card
    }

    var section: AppSection = .board {
        didSet {
            if oldValue != section, selectedMachineID != nil {
                dismissMachinePopover()
            }
        }
    }
    var settingsSection = DieterSettingsSection.general
    var phase: ConnectionPhase = .disconnected
    var endpoint: DieterEndpoint
    var endpoints: [DieterEndpoint]
    var health = Dieter_V1_HealthResponse()
    var runtime = Dieter_V1_RuntimeStatus()
    var state = Dieter_V1_State() {
        didSet {
            refreshIslandActivityProjection()
            refreshBoardProjection()
        }
    }
    var harnessCatalog = Dieter_V1_HarnessCatalog()
    var boardSettings = Dieter_V1_Settings()
    var settingsOptions = Dieter_V1_SettingsOptions()
    var chats: [Dieter_V1_Card] = [] {
        didSet { refreshIslandActivityProjection() }
    }
    var chatProjects: [Dieter_V1_Project] = []
    var navigationBoards: [String: [Dieter_V1_Board]] = [:]
    var navigationCards: [String: [Dieter_V1_Card]] = [:] {
        didSet { refreshIslandActivityProjection() }
    }
    var projectDirectory: [String: Dieter_V1_Project] = [:]
    var projectEndpointIDs: [String: String] = [:]
    var machineConnectionStatuses: [String: MachineConnectionStatus] = [:]
    var selectedMachineID: String?
    var machineInformation: [String: Dieter_V1_MachineInformation] = [:]
    var machineCPUHistory: [String: [Double]] = [:]
    var machineInformationLoading = false
    var machineInformationError: String?
    var machineOperationMessage: String?
    var archivedProjects: [Dieter_V1_Project] = []
    var archivedCards: [Dieter_V1_Card] = []

    var selectedProjectID = ""
    var selectedBoardID = "" {
        didSet { if selectedBoardID != oldValue { refreshBoardProjection() } }
    }
    var selectedCardID: String?
    var selectedChatID: String?
    var conversation: Dieter_V1_ConversationSnapshot? {
        didSet {
            guard conversation != oldValue else { return }
            refreshConversationPresentationState()
        }
    }
    var olderConversationMessages: [Dieter_V1_UiMessage] = [] {
        didSet {
            guard olderConversationMessages != oldValue else { return }
            refreshConversationPresentationState()
        }
    }
    var conversationMessages: [Dieter_V1_UiMessage] = []
    var conversationPresentationRevision = 0
    var conversationHistoryStart = 0
    var conversationHistoryTotal = 0
    var conversationHistoryHasMore = false
    var conversationHistoryLoading = false
    var selectedDetail: Dieter_V1_CardDetail?
    var conversationLoading = false
    var conversationSyncing = false
    var conversationLastRefreshedAt: Date?
    var conversationWorkspace: Dieter_V1_Workspace?
    var conversationChangeset: Dieter_V1_Changeset?
    var conversationDiff: Dieter_V1_FileDiff?
    var conversationChangeComments: [Dieter_V1_ChangeComment] = []
    var conversationSCMCapabilities: Dieter_V1_SCMCapabilities?
    var projectWorkspaces: [Dieter_V1_Workspace] = []
    var gitOperation: Dieter_V1_GitOperation?
    var gitOperationLogs: [Dieter_V1_GitOperationLogEntry] = []
    var workspaceLoading = false
    var workspaceError: String?
    var selectedChangePath = ""
    var selectedCommitSHA = ""
    var workspaceToast: WorkspaceToast?
    var mergeFlowStep: WorkspaceMergeStep?
    var fileScopeCardID: String?
    var terminalScopeCardID: String?
    var composerText = ""
    var composerAttachments: [Dieter_V1_MessagePart] = []
    var composerProvider = ""
    var composerModel = ""
    var composerEffort = ""
    var composerProviderOptions: [String: String] = [:]
    var showReasoning = ReasoningTracePreferences.load() {
        didSet {
            guard showReasoning != oldValue else { return }
            ReasoningTracePreferences.save(showReasoning)
        }
    }
    var themeSelection: DieterThemeSelection {
        didSet {
            guard themeSelection != oldValue else { return }
            themeSelection.save(to: themeDefaults)
            DieterTheme.install(selection: themeSelection)
        }
    }
    var commentText = ""
    var query = "" {
        didSet { if query != oldValue { refreshBoardProjection() } }
    }
    var runtimeFilter = "" {
        didSet { if runtimeFilter != oldValue { refreshBoardProjection() } }
    }
    var labelFilter = "" {
        didSet { if labelFilter != oldValue { refreshBoardProjection() } }
    }
    var movingCardIDs: Set<String> = []
    var labelUpdatingCardIDs: Set<String> = []
    var pendingCardIDs: Set<String> = []
    var pendingMessageIDs: Set<String> = []
    var acceptedOutboxIDs: Set<String> = []
    var failedOutboxIDs: Set<String> = []
    var machineOutboxSummaries: [String: MachineOutboxSummary] = [:]
    var globalSyncing = false
    var lastSyncedAt: Date?
    var islandActivity = DieterIslandActivity.empty
    var boardProjection = BoardProjection.empty
    @ObservationIgnored var islandActivityProjectionRevision = 0
    @ObservationIgnored var islandActivitySource: [DieterIslandActivity.SourceCard] = []
    @ObservationIgnored var islandActivityDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored var suppressIslandActivityRefresh = false

    var workspaceFreshness: WorkspaceFreshnessState {
        WorkspaceFreshnessState.resolve(
            phase: phase,
            globalSyncing: globalSyncing,
            hasCachedWorkspace: hasLoadedWorkspace
        )
    }

    var workspaceIsLive: Bool {
        workspaceFreshness.isLive
    }

    func refreshConversationPresentationState() {
        let live = conversation?.conversation.messages ?? []
        let liveIDs = Set(live.lazy.map(\.id).filter { !$0.isEmpty })
        var seen = Set<String>()
        let history = olderConversationMessages.filter { $0.id.isEmpty || !liveIDs.contains($0.id) }
        let next = (history + live).filter { message in
            message.id.isEmpty || seen.insert(message.id).inserted
        }
        if conversationMessages != next { conversationMessages = next }
        conversationPresentationRevision &+= 1
    }

    var files: [Dieter_V1_FileEntry] = []
    var filePath = ""
    var fileNavigation = ProjectFileNavigation()
    var fileNavigationLoading = false
    var fileDocument: Dieter_V1_FileDocument?
    var showHiddenFiles = false

    var terminals: [Dieter_V1_Terminal] = []
    var selectedTerminalID: String?
    var terminalScreens: [String: TerminalScreenState] = [:]
    var terminalLoading = false
    var terminalStreamConnected = false
    var createTerminalPresented = false

    var schedules: [Dieter_V1_Schedule] = []
    var scheduleRuns: [Dieter_V1_ScheduleRun] = []
    var selectedScheduleID: String?
    var schedulesLoading = false
    var schedulesLoadingMore = false
    var scheduleRunsLoading = false
    var scheduleRunsLoadingMore = false
    var schedulesTotalCount = 0
    var schedulesNextPageToken = ""
    var scheduleRunsNextPageToken = ""
    var schedulesLoadedProjectID = ""
    var newChatProjectID = ""

    var commandPalettePresented = false
    var createConversationPresented = false
    var createProjectPresented = false
    var createBoardPresented = false
    var renameProjectPresented = false
    var renameProjectTargetID = ""
    var renameBoardPresented = false
    var renameBoardTargetID = ""
    var projectContextPresented = false
    var labelsPresented = false
    var archivePolicyPresented = false
    var errorMessage: String?

    var rpc: DieterRPC?
    let scheduleRPCOverride: (any DieterScheduleRPC)?
    let chatPinRPCOverride: (any DieterChatPinRPC)?
    var connectionTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var directRefreshTask: Task<Void, Never>?
    var machineDirectoryTask: Task<Void, Never>?
    var machinePresenceLeaseTask: Task<Void, Never>?
    var machineTelemetryTask: Task<Void, Never>?
    var syncRestoreTask: Task<Void, Never>?
    var stateTask: Task<Void, Never>?
    var conversationTask: Task<Void, Never>?
    var gitOperationTask: Task<Void, Never>?
    var workspaceToastTask: Task<Void, Never>?
    var terminalWatchTask: Task<Void, Never>?
    var conversationHistoryRequestID: UUID?
    var syncTask: Task<Void, Never>?
    var syncLivenessTask: Task<Void, Never>?
    var outboxTask: Task<Void, Never>?
    var connectionGeneration: UInt64 = 0
    var boardSelectionGeneration: UInt64 = 0
    var pendingCardMoves: [String: OptimisticCardMove] = [:]
    var pendingCardLabelUpdates: [String: OptimisticCardLabels] = [:]
    var pendingBoards: [String: Dieter_V1_Board] = [:]
    var pendingProjects: [String: Dieter_V1_Project] = [:]
    var notificationStatuses: [String: String] = [:]
    @ObservationIgnored var lastSyncFrameAt: Date?
    @ObservationIgnored var lastSyncPersistenceAt: [String: Date] = [:]
    var persistConnectionSelection = true
    let accessTokenOverride: String?
    @ObservationIgnored let themeDefaults: UserDefaults
    var gatewayOrigins: [DieterEndpoint]
    var readChatActivity: [String: String]
    let authentication = DieterAuthentication()
    let syncPersistence: DieterSyncPersistence
    let attachmentLoader = AttachmentLoader()
    let syncClientID = DieterSyncPersistence.installationID()
    let terminalInputForwarder = TerminalInputForwarder()
    let terminalOutputAccumulator = TerminalOutputAccumulator()
    @ObservationIgnored var terminalSequences: [String: UInt64] = [:]
    var pendingChatPins: [String: PendingChatPin] = [:]
    var schedulesLoadedEndpointID = ""
    var schedulesRequestGeneration: UInt64 = 0
    var scheduleRunsRequestGeneration: UInt64 = 0
    var syncDiskState = DieterSyncDiskState.empty
    var syncProjection = DieterSyncProjection.empty
    var syncSnapshot: Dieter_V1_GlobalSnapshot?
    @ObservationIgnored var syncStateDirty = false

    init(
        scheduleRPCOverride: (any DieterScheduleRPC)? = nil,
        chatPinRPCOverride: (any DieterChatPinRPC)? = nil,
        syncPersistenceOverride: DieterSyncPersistence? = nil,
        themeDefaultsOverride: UserDefaults? = nil,
        restoreSync: Bool = true
    ) {
        self.scheduleRPCOverride = scheduleRPCOverride
        self.chatPinRPCOverride = chatPinRPCOverride
        syncPersistence = syncPersistenceOverride ?? DieterSyncPersistence()
        let themeDefaults = themeDefaultsOverride ?? DieterAppearance.applicationDefaults()
        self.themeDefaults = themeDefaults
        themeSelection = DieterThemeSelection.load(from: themeDefaults)
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--dieter-access-token-file"), arguments.indices.contains(flag + 1),
           let token = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            accessTokenOverride = token
        } else {
            accessTokenOverride = nil
        }
        readChatActivity = UserDefaults.standard.dictionary(forKey: "DieterReadChatActivity") as? [String: String] ?? [:]
        if let flag = arguments.firstIndex(of: "--dieter-endpoint"), arguments.indices.contains(flag + 1),
           let override = DieterEndpoint.parse(arguments[flag + 1], name: "Command line") {
            endpoints = [override]
            endpoint = override
            gatewayOrigins = [override]
            persistConnectionSelection = false
            if restoreSync {
                syncRestoreTask = Task { [weak self] in await self?.restorePersistentSync() }
            }
            return
        }

        let defaults = UserDefaults.standard
        let storedEndpoints = defaults.data(forKey: "DieterEndpoints")
            .flatMap { try? JSONDecoder().decode([DieterEndpoint].self, from: $0) }
        let secureEndpoints = storedEndpoints?.filter { $0.secure && $0.daemonID == nil } ?? []
        let loadedEndpoints = secureEndpoints.isEmpty ? DieterEndpoint.defaults : secureEndpoints
        endpoints = loadedEndpoints
        gatewayOrigins = loadedEndpoints
        if let data = defaults.data(forKey: "DieterActiveEndpoint"),
           let decoded = try? JSONDecoder().decode(DieterEndpoint.self, from: data), decoded.secure {
            endpoint = decoded
        } else {
            endpoint = loadedEndpoints[0]
        }
        if loadedEndpoints != storedEndpoints { persistEndpoints() }
        if restoreSync {
            syncRestoreTask = Task { [weak self] in await self?.restorePersistentSync() }
        }
    }

    func accessToken(for endpoint: DieterEndpoint) async -> String? {
        if let accessTokenOverride { return accessTokenOverride }
        return await DieterCredentialStore.token(for: endpoint)
    }
}
