import AppKit
import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
// Application lifetime and feature composition. Window selection and feature
// effects have dedicated owners; compatibility accessors live separately.
final class AppSession {
    struct PendingChatPin {
        let operationID: UUID
        let pinned: Bool
        let original: Dieter_V1_Card
    }

    let window = WindowWorkspace()
    @ObservationIgnored var reopenWorkspaceWindow: @MainActor () -> Void = {}
    var section: AppSection {
        get { window.section }
        set {
            let previous = window.section
            window.section = newValue
            terminalsModel.active = newValue == .terminals
            if previous != newValue, selectedMachineID != nil { dismissMachinePopover() }
        }
    }
    var phase: ConnectionPhase = .disconnected {
        didSet {
            filesModel.isLive = selectedProjectIsLive; schedulesModel.isLive = selectedProjectIsLive;
            terminalsModel.isLive = workspaceIsLive
        }
    }
    var endpoint: DieterEndpoint {
        didSet {
            if endpoint.id != oldValue.id {
                bindComposer(); resetFileSurface(); bindSchedules(); bindConversation(); bindWorktree(); bindTerminals()
            }
        }
    }
    var endpoints: [DieterEndpoint]
    var health = Dieter_V1_HealthResponse()
    var runtime = Dieter_V1_RuntimeStatus()
    let replica = WorkspaceReplica()
    var harnessCatalog = Dieter_V1_HarnessCatalog()
    var harnessCatalogsByEndpoint: [String: Dieter_V1_HarnessCatalog] = [:]
    var boardSettings = Dieter_V1_Settings()
    var settingsOptions = Dieter_V1_SettingsOptions()
    var machineConnectionStatuses: [String: MachineConnectionStatus] = [:]
    var machineConnectionErrors: [String: String] = [:]
    var selectedMachineID: String?
    var machineInformation: [String: Dieter_V1_MachineInformation] = [:]
    var machineCPUHistory: [String: [Double]] = [:]
    var machineGPUHistory: [String: [String: [Double]]] = [:]
    var gatewayInformation: [String: Dieter_Gateway_V1_GatewayInformation] = [:]
    var machineInformationLoading = false
    var machineInformationError: String?
    var machineOperationMessage: String?
    var machineOperationInFlight = false
    var archivedProjects: [Dieter_V1_Project] = []
    var archivedCards: [Dieter_V1_Card] = []

    let conversationModel = ConversationModel()
    @ObservationIgnored lazy var conversationContext = makeConversationContext()
    @ObservationIgnored let snapshotDecoder = DieterSnapshotDecoder()
    var conversationRead: OwnedRead<Dieter_V1_ConversationSnapshot> { conversationModel.conversationRead }
    var projectWorkspaces: [Dieter_V1_Workspace] = []
    let schedulesModel = SchedulesModel()
    let terminalsModel = TerminalsModel()
    let filesModel = FilesModel()
    var fileListingGeneration: UInt64 { filesModel.fileListingGeneration }
    let worktreeChanges = WorktreeChangesModel()
    let projectChanges = ProjectChangesModel()
    var stateRequestGeneration: UInt64 = 0
    var chatsRequestGeneration: UInt64 = 0
    var showReasoning: Bool {
        didSet {
            guard showReasoning != oldValue else { return }
            ReasoningTracePreferences.save(showReasoning, to: environment.defaults)
        }
    }
    var themeSelection: DieterThemeSelection {
        didSet {
            guard themeSelection != oldValue else { return }
            themeSelection.save(to: themeDefaults)
            DieterTheme.install(selection: themeSelection)
        }
    }
    let composer = ComposerModel()
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

    var selectedProjectIsLive: Bool {
        workspaceIsLive && (projectEndpointIDs[selectedProjectID] ?? endpoint.id) == endpoint.id
    }

    var workspaceIsLive: Bool {
        workspaceFreshness.isLive
    }

    func machineIsAvailable(_ machine: DieterEndpoint) -> Bool {
        guard machine.online, machine.apiCompatibility != .incompatible else { return false }
        return machine.id != endpoint.id || workspaceIsLive
    }

    func projectIsAvailable(_ projectID: String) -> Bool {
        guard let machine = machine(forProjectID: projectID) else { return workspaceIsLive }
        return machineIsAvailable(machine)
    }

    func refreshConversationPresentationState() { conversationModel.refreshConversationPresentationState() }

    @ObservationIgnored let chatsRead = OwnedRead<Dieter_V1_ChatsResponse>()
    var terminalsRead: OwnedRead<Dieter_V1_TerminalsResponse> { terminalsModel.terminalsRead }
    var chatsLoading = false
    var chatsError: String?
    var archiveLoading = false
    var archiveError: String?
    var archiveRequestGeneration: UInt64 = 0

    var errorMessage: String?

    var rpc: DieterRPC? {
        didSet {
            if rpc !== oldValue {
                terminalInputForwarder.suspend(); resetFileSurface(); bindSchedules(); bindConversation();
                bindWorktree(); bindTerminals()
            }
        }
    }
    let scheduleRPCOverride: (any DieterScheduleRPC)?
    let chatPinRPCOverride: (any DieterChatPinRPC)?
    let connections: ConnectionManager
    var connectionTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var directRefreshTask: Task<Void, Never>?
    var machineDirectoryTask: Task<Void, Never>?
    var machinePresenceLeaseTask: Task<Void, Never>?
    var machineTelemetryTask: Task<Void, Never>?
    var machineInformationGeneration: UInt64 = 0
    var syncRestoreTask: Task<Void, Never>?
    var stateTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?
    var syncLivenessTask: Task<Void, Never>?
    var outboxTask: Task<Void, Never>? {
        get { outbox.workerTask }
        set { outbox.workerTask = newValue }
    }
    var outboxWorkerGeneration: UInt64 {
        get { outbox.workerGeneration }
        set { outbox.workerGeneration = newValue }
    }
    var connectionGeneration: UInt64 = 0
    var boardSelectionGeneration: UInt64 = 0
    var pendingCardMoves: [String: OptimisticCardMove] {
        get { replica.pendingCardMoves }
        set { replica.pendingCardMoves = newValue }
    }
    var pendingCardLabelUpdates: [String: OptimisticCardLabels] {
        get { replica.pendingCardLabelUpdates }
        set { replica.pendingCardLabelUpdates = newValue }
    }
    var pendingBoards: [String: Dieter_V1_Board] {
        get { replica.pendingBoards }
        set { replica.pendingBoards = newValue }
    }
    var pendingProjects: [String: Dieter_V1_Project] {
        get { replica.pendingProjects }
        set { replica.pendingProjects = newValue }
    }
    var activityTransitions = ActivityTransitions()
    @ObservationIgnored var lastSyncFrameAt: Date?
    @ObservationIgnored var lastSyncPersistenceAt: [String: Date] = [:]
    var persistConnectionSelection = true
    let accessTokenOverride: String?
    @ObservationIgnored let themeDefaults: UserDefaults
    var gatewayOrigins: [DieterEndpoint]
    var readChatActivity: [String: String]
    let authentication: DieterAuthentication
    @ObservationIgnored let environment: DieterAppEnvironment
    let syncPersistence: DieterSyncPersistence
    let attachmentLoader = AttachmentLoader()
    let syncClientID: String
    var terminalInputForwarder: TerminalInputForwarder { terminalsModel.terminalInputForwarder }
    var terminalOutputAccumulator: TerminalOutputAccumulator { terminalsModel.terminalOutputAccumulator }
    var pendingChatPins: [String: PendingChatPin] = [:]
    let outbox: DurableOutbox
    var syncDiskState = DieterSyncDiskState.empty
    var syncProjection = DieterSyncProjection.empty
    var syncSnapshot: Dieter_V1_GlobalSnapshot?
    @ObservationIgnored var syncStateDirty = false

    init(
        environment: DieterAppEnvironment? = nil,
        scheduleRPCOverride: (any DieterScheduleRPC)? = nil,
        chatPinRPCOverride: (any DieterChatPinRPC)? = nil,
        syncPersistenceOverride: DieterSyncPersistence? = nil,
        outboxOverride: DurableOutbox? = nil,
        themeDefaultsOverride: UserDefaults? = nil,
        restoreSync: Bool = true
    ) {
        self.scheduleRPCOverride = scheduleRPCOverride
        self.chatPinRPCOverride = chatPinRPCOverride
        let environment = environment ?? (restoreSync ? .live() : .testing(defaults: themeDefaultsOverride))
        self.environment = environment
        connections = ConnectionManager(factory: environment.clients, clock: environment.clock)
        authentication = DieterAuthentication(
            defaults: environment.defaults, credentials: environment.credentials, clock: environment.clock)
        syncClientID = DieterSyncPersistence.installationID(defaults: environment.defaults)
        showReasoning = ReasoningTracePreferences.load(from: environment.defaults)
        let persistence = syncPersistenceOverride ?? DieterSyncPersistence(root: environment.storageRoot)
        syncPersistence = persistence
        outbox =
            outboxOverride
            ?? DurableOutbox(journal: OutboxJournal(url: persistence.outboxJournalURL, legacyURL: persistence.fileURL))
        let themeDefaults = themeDefaultsOverride ?? environment.defaults
        self.themeDefaults = themeDefaults
        themeSelection = DieterThemeSelection.load(from: themeDefaults)
        let arguments = environment.arguments
        if let flag = arguments.firstIndex(of: "--dieter-access-token-file"), arguments.indices.contains(flag + 1),
            let token = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        {
            accessTokenOverride = token
        } else {
            accessTokenOverride = nil
        }
        readChatActivity = environment.defaults.dictionary(forKey: "DieterReadChatActivity") as? [String: String] ?? [:]
        if let flag = arguments.firstIndex(of: "--dieter-endpoint"), arguments.indices.contains(flag + 1),
            let override = DieterEndpoint.parse(arguments[flag + 1], name: "Command line")
        {
            endpoints = [override]
            endpoint = override
            gatewayOrigins = [override]
            persistConnectionSelection = false
            if restoreSync {
                syncRestoreTask = Task { [weak self] in await self?.restorePersistentSync() }
            }
            return
        }

        let defaults = environment.defaults
        let storedEndpoints = defaults.data(forKey: "DieterEndpoints")
            .flatMap { try? JSONDecoder().decode([DieterEndpoint].self, from: $0) }
        let secureEndpoints = storedEndpoints?.filter { $0.secure && $0.daemonID == nil } ?? []
        let loadedEndpoints = secureEndpoints.isEmpty ? DieterEndpoint.defaults : secureEndpoints
        endpoints = loadedEndpoints
        gatewayOrigins = loadedEndpoints
        if let data = defaults.data(forKey: "DieterActiveEndpoint"),
            let decoded = try? JSONDecoder().decode(DieterEndpoint.self, from: data), decoded.secure
        {
            endpoint = decoded
        } else {
            endpoint = loadedEndpoints[0]
        }
        if loadedEndpoints != storedEndpoints { persistEndpoints() }
        if restoreSync {
            syncRestoreTask = Task { [weak self] in await self?.restorePersistentSync() }
        }
    }

    func refreshReplicaPresentation() {
        refreshIslandActivityProjection()
        refreshBoardProjection()
    }

    func bindComposer() {
        let id = selectedCardID ?? selectedChatID
        // Conversation IDs are unique on one daemon; project selection is not
        // part of draft identity because global chats can open from any project.
        let projectID =
            selectedCard?.projectID ?? selectedDetail.flatMap { $0.card.id == id ? $0.card.projectID : nil } ?? ""
        let destination = projectEndpointIDs[projectID] ?? endpoint.id
        composer.select(id.map { WorkspaceTarget(endpointID: destination, projectID: "", conversationID: $0) })
    }

    func accessToken(for endpoint: DieterEndpoint) async -> String? {
        if let accessTokenOverride { return accessTokenOverride }
        return await environment.credentials.token(for: endpoint.credentialID)
    }
}
