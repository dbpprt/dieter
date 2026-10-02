import AppKit
import DieterAPI
import DieterCore
import DieterClient
import Foundation
import GRPCCore
import Observation
import OSLog
import SharedCore
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
// Application lifetime and feature composition. Window selection and feature
// effects have dedicated owners; compatibility accessors live separately.
final class AppSession {
    let quickTaskForm = QuickTaskFormState()
    var lastUsedChatID: String?
    var pendingCardStarts: [String: OptimisticCardStart] {
        get { replica.pendingCardStarts }
        set { replica.pendingCardStarts = newValue }
    }
    let window = WindowWorkspace()
    @ObservationIgnored var reopenWorkspaceWindow: @MainActor () -> Void = {}
    var section: AppSection {
        get { window.section }
        set {
            let previous = window.section
            window.section = newValue
            terminalsModel.active = newValue == .terminals
            if previous == .terminals, newValue != .terminals { stopTerminalWatch() }
            if previous != newValue, fleet.selectedMachineID != nil { fleet.dismissMachinePopover() }
        }
    }
    var phase: ConnectionPhase = .disconnected {
        didSet {
            filesModel.isLive = filesAreLive; schedulesModel.isLive = workspaceIsLive;
            terminalsModel.isLive =
                terminalScopeCardID == nil
                ? terminalOverviewMachines.contains(where: machineIsAvailable)
                : workspaceIsLive
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
    /// The shared core: connection, sync, outbox, and conversations.
    @ObservationIgnored let core: CoreClient
    @ObservationIgnored let coreHost: CoreHost?
    @ObservationIgnored var coreStart: Task<Void, Never>?
    @ObservationIgnored var coreSubscriptions: [SliceSubscription] = []
    @ObservationIgnored var coreWorkspace = ClientWorkspaceSlice()
    var session = ClientSessionSlice()
    var outboxState = ClientOutboxSlice()
    var boardState = ClientBoardSlice()
    var creationMemory = ClientCreationSlice()
    /// The Inbox's rows, newest activity first, as the core classifies them.
    var activityRows: [ClientActivityRow] = [] {
        didSet { refreshIslandActivityProjection() }
    }
    @ObservationIgnored var machineMetadata: [String: ClientMachineMetadata] = [:]
    /// The attached machine whose metadata was last requested.
    @ObservationIgnored var requestedMetadata: String?
    /// UI fixtures that render injected state hold the core's folds; the
    /// latest slices apply when released.
    @ObservationIgnored var coreFoldsHeld = false {
        didSet { if oldValue, !coreFoldsHeld { releaseHeldFolds() } }
    }
    /// A session this launch adopts from `--dieter-endpoint` and `--dieter-access-token-file`.
    let launchSession: (gateway: DieterEndpoint, token: String)?
    var harnessCatalog = Dieter_V1_HarnessCatalog()
    var harnessCatalogsByEndpoint: [String: Dieter_V1_HarnessCatalog] = [:]
    var boardSettings = Dieter_V1_Settings()
    var settingsOptions = Dieter_V1_SettingsOptions()
    var machineConnectionStatuses: [String: MachineConnectionStatus] = [:]
    var machineConnectionErrors: [String: String] = [:]
    var machineSyncIssues: [String: String] = [:]
    @ObservationIgnored lazy var fleet = FleetModel(
        machines: { [weak self] in
            guard let self else { return [] }
            return self.machines.contains(where: { $0.id == self.endpoint.id })
                ? self.machines : self.machines + [self.endpoint]
        },
        core: core, reportError: { [weak self] in self?.show($0) })
    var gatewayInformation: [String: Dieter_Gateway_V1_GatewayInformation] = [:]
    @ObservationIgnored lazy var quotas = CoreProviderQuotas(core: core)
    var archivedProjects: [Dieter_V1_Project] = []
    var archivedCards: [Dieter_V1_Card] = []
    /// Archived chats, which the core's live workspace omits.
    var archivedChats: [Dieter_V1_Card] = []
    var sidebarProjectNavigation: SidebarProjectNavigationPreferences {
        didSet {
            guard sidebarProjectNavigation != oldValue else { return }
            syncSidebarProjects(oldValue, sidebarProjectNavigation)
        }
    }
    var sidebarProjectFolders: NavigationFolderPreferences {
        didSet {
            guard sidebarProjectFolders != oldValue else { return }
            syncNavigationFolders(sidebarProjectFolders, scope: .projects)
        }
    }
    var allChatsFolders: NavigationFolderPreferences {
        didSet {
            guard allChatsFolders != oldValue else { return }
            syncNavigationFolders(allChatsFolders, scope: .chats)
        }
    }

    @ObservationIgnored var navigationEditTail: Task<Void, Never>?
    /// The legacy app's state directory; the core imported from it and keeps its own state below it.
    let legacyDirectory: URL
    @ObservationIgnored var applyingSharedNavigation = false
    var navigationPendingCount = 0
    /// The core has replayed the account's navigation since it attached a machine.
    @ObservationIgnored var navigationCaughtUp = false
    var navigationSyncError: String?
    var sharedLaneSortDirections: [String: String] = [:]
    var pinnedProjectNavigation = PinnedProjectNavigationPreferences() {
        didSet {
            guard pinnedProjectNavigation != oldValue else { return }
            syncPinnedProjects(pinnedProjectNavigation)
        }
    }
    var pinnedChatNavigation = PinnedChatNavigationPreferences() {
        didSet {
            guard pinnedChatNavigation != oldValue else { return }
            syncPinnedChats(pinnedChatNavigation)
        }
    }
    var chatProjectDisclosure = ChatProjectDisclosurePreferences() {
        didSet {
            guard chatProjectDisclosure != oldValue else { return }
            syncChatDisclosure(oldValue, chatProjectDisclosure)
        }
    }
    let conversationModel = ConversationModel()
    @ObservationIgnored var onConversationContentConnectionChanged: @MainActor () -> Void = {}
    @ObservationIgnored lazy var conversationContext = makeConversationContext()
    var projectWorkspaces: [Dieter_V1_Workspace] = []
    let schedulesModel = SchedulesModel()
    let terminalsModel: TerminalsModel
    let screensModel: ScreensModel
    @ObservationIgnored lazy var terminalOverview = TerminalOverviewModel(
        terminalsModel: terminalsModel, core: core,
        endpointID: { [weak self] in self?.endpointID(forDaemon: $0) ?? $0 },
        active: { [weak self] in self?.section == .terminals && self?.terminalsModel.terminalScopeCardID == nil },
        reportError: { [weak self] in self?.errorMessage = $0 })
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
    var defaultConversationMode: ConversationDefaultMode {
        didSet {
            guard defaultConversationMode != oldValue else { return }
            defaultConversationMode.save(to: environment.defaults)
        }
    }
    var themeSelection: DieterThemeSelection {
        didSet {
            guard themeSelection != oldValue else { return }
            themeSelection.save(to: themeDefaults)
            DieterTheme.install(selection: themeSelection)
        }
    }
    let composer: ComposerModel
    /// Unsent draft text, kept by the core.
    @ObservationIgnored let composerDrafts: CoreDraftTexts
    var query = "" {
        didSet { if query != oldValue { refreshBoardProjection() } }
    }
    var machineFilter = "" { didSet { refreshBoardProjection() } }
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

    var workspaceFreshness: WorkspaceFreshnessState {
        WorkspaceFreshnessState.resolve(
            phase: phase,
            globalSyncing: globalSyncing,
            hasCachedWorkspace: hasLoadedWorkspace
        )
    }

    var selectedProjectIsLive: Bool {
        workspaceIsLive && (projectReplicaEndpointIDs[selectedProjectID] ?? endpoint.id) == endpoint.id
    }

    var workspaceIsLive: Bool {
        // Cached workspace contents distinguish offline presentation states,
        // but cannot affect liveness. Avoid observing all cards for this flag.
        phase.isConnected && !globalSyncing
    }

    func machineIsAvailable(_ machine: DieterEndpoint) -> Bool {
        guard machine.online, machine.compatibilityState != .incompatible else { return false }
        return machine.id != endpoint.id || phase.isConnected
    }

    var creationCheckoutIDs: [String: String] = [:]

    func projectIsAvailable(_ projectID: String) -> Bool {
        guard let machine = replica(forProjectID: projectID) else { return workspaceIsLive }
        return machineIsAvailable(machine)
    }

    func refreshConversationPresentationState() { conversationModel.refreshConversationPresentationState() }

    var chatsLoading = false
    var chatsError: String?
    var archiveLoading = false
    var archiveError: String?
    var archiveRequestGeneration: UInt64 = 0

    var errorMessage: String?

    /// The attached machine while the core is connected to it. The feature
    /// surfaces rebind when it changes.
    var connectedMachineID: String? {
        didSet {
            if connectedMachineID != oldValue {
                connectionGeneration &+= 1
                resetFileSurface(); bindSchedules(); bindConversation();
                bindWorktree(); bindTerminals()
                onConversationContentConnectionChanged()
            }
        }
    }
    /// Changes whenever the connected machine changes.
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
    let accessTokenOverride: String?
    @ObservationIgnored let themeDefaults: UserDefaults
    var gatewayOrigins: [DieterEndpoint]
    @ObservationIgnored let environment: DieterAppEnvironment
    let attachmentLoader = AttachmentLoader()
    var terminalOutputAccumulator: TerminalOutputAccumulator { terminalsModel.terminalOutputAccumulator }

    /// `core` replaces the shared core, e.g. with a `ScriptedCoreClient` in
    /// tests. Only `liveCore` builds the real one from the environment: it
    /// owns the state under the environment's storage root, so the app entry
    /// point and isolated integration tests opt in, and nothing else does.
    init(
        environment: DieterAppEnvironment? = nil,
        core: CoreClient? = nil,
        liveCore: Bool = false,
        themeDefaultsOverride: UserDefaults? = nil,
        restoreSync: Bool = true
    ) {
        let environment = environment ?? (restoreSync ? .live() : .testing(defaults: themeDefaultsOverride))
        self.environment = environment
        terminalsModel = TerminalsModel()
        screensModel = ScreensModel(defaults: environment.defaults)
        sidebarProjectNavigation = SidebarProjectNavigationPreferences()
        sidebarProjectFolders = NavigationFolderPreferences()
        allChatsFolders = NavigationFolderPreferences()
        showReasoning = ReasoningTracePreferences.load(from: environment.defaults)
        defaultConversationMode = ConversationDefaultMode.load(from: environment.defaults)
        let root =
            environment.storageRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        legacyDirectory = root.appending(path: "Dieter", directoryHint: .isDirectory)
        let themeDefaults = themeDefaultsOverride ?? environment.defaults
        self.themeDefaults = themeDefaults
        let initialTheme = DieterThemeSelection.load(from: themeDefaults)
        themeSelection = initialTheme
        DieterTheme.install(selection: initialTheme)
        let arguments = environment.arguments
        var tokenOverride: String?
        if let flag = arguments.firstIndex(of: "--dieter-access-token-file"), arguments.indices.contains(flag + 1),
            let token = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        {
            tokenOverride = token
        }
        accessTokenOverride = tokenOverride
        let override = arguments.firstIndex(of: "--dieter-endpoint")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .flatMap { DieterEndpoint.parse($0, name: "Command line") }
        launchSession = override.flatMap { gateway in tokenOverride.map { (gateway, $0) } }
        let gateway = override ?? DieterEndpoint.defaults[0]
        endpoints = []
        endpoint = gateway
        gatewayOrigins = [gateway]
        var host: CoreHost?
        var screenMedia: CoreScreenMedia?
        if liveCore, core == nil {
            let defaults = environment.defaults
            let media = CoreScreenMedia()
            screenMedia = media
            host = try? CoreHost(
                configuration: CoreHostConfiguration(
                    root: root,
                    credentialsFile: environment.storageRoot?.appending(path: "gateway-sessions.json")
                        ?? DieterCredentialFileStore.defaultFileURL(),
                    clientVersion: DieterRelease.current, oauthRedirectURI: "dieter-mac://oauth/callback",
                    clientIDPrefix: "mac", logSubsystem: "com.dbpprt.dieter.mac"),
                defaults: defaults, notificationsEnabled: { true },
                screens: CoreHostScreens(media: media, clipboard: CoreScreenClipboard()))
        }
        let resolved: CoreClient = core ?? host?.client ?? ScriptedCoreClient()
        self.core = resolved
        coreHost = host
        composerDrafts = CoreDraftTexts(core: resolved)
        composer = ComposerModel(store: composerDrafts)
        conversationModel.core = resolved
        screensModel.core = resolved
        screensModel.media = screenMedia
        quickTaskForm.remember = { [weak self] remember in
            Task { await self?.perform { $0.rememberCreation = remember } }
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
        let destination = projectReplicaEndpointIDs[projectID] ?? endpoint.id
        composer.select(id.map { WorkspaceTarget(endpointID: destination, projectID: "", conversationID: $0) })
    }

    func accessToken(for endpoint: DieterEndpoint) async -> String? {
        if let accessTokenOverride { return accessTokenOverride }
        return await environment.credentials.token(for: endpoint.credentialID)
    }
}
