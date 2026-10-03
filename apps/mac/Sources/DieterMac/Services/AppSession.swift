import AppKit
import DieterAPI
import DieterShared
import Foundation
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
        didSet { refreshLiveFlags() }
    }
    /// The attached machine's live projection is applied: the workspace is
    /// current, neither cached nor still loading (the core's `workspace_live`).
    var workspaceIsLive = false {
        didSet { if workspaceIsLive != oldValue { refreshLiveFlags() } }
    }
    /// What synchronized views with a cached workspace show while it is
    /// unavailable; nil while it is current.
    var workspaceNotice: ClientWorkspaceNotice?
    /// Each machine as the core presents it, by machine (endpoint) ID.
    var machineEntries: [String: ClientMachineEntry] = [:] {
        didSet { if machineEntries != oldValue { refreshLiveFlags() } }
    }

    private func refreshLiveFlags() {
        filesModel.isLive = filesAreLive; schedulesModel.isLive = workspaceIsLive
        terminalsModel.isLive =
            terminalScopeCardID == nil
            ? terminalOverviewMachines.contains(where: machineIsAvailable)
            : workspaceIsLive
    }
    var endpoint: MachineEndpoint {
        didSet {
            if endpoint.id != oldValue.id {
                bindComposer(); resetFileSurface(); bindSchedules(); bindConversation(); bindWorktree(); bindTerminals()
            }
        }
    }
    var endpoints: [MachineEndpoint]
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
    /// The Inbox's rows, newest activity first, and what the island and the
    /// menu bar show of them, as the core classifies them.
    var activity = ClientActivitySlice() {
        didSet { refreshIslandActivity() }
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
    let launchSession: (gateway: MachineEndpoint, token: String)?
    var harnessCatalog = Dieter_V1_HarnessCatalog()
    var boardSettings = Dieter_V1_Settings()
    var settingsOptions = Dieter_V1_SettingsOptions()
    @ObservationIgnored lazy var fleet = FleetModel(
        machines: { [weak self] in
            guard let self else { return [] }
            let machines =
                self.machines.contains(where: { $0.id == self.endpoint.id })
                ? self.machines : self.machines + [self.endpoint]
            return machines.map {
                FleetMachine(id: $0.id, daemonID: $0.daemonID ?? "", name: $0.name, entry: self.machineEntry($0))
            }
        },
        core: core, reportError: { [weak self] in self?.show($0) })
    var gatewayInformation: [String: Dieter_Gateway_V1_GatewayInformation] = [:]
    @ObservationIgnored lazy var quotas = CoreProviderQuotas(core: core)
    var archivedProjects: [Dieter_V1_Project] = []
    var archivedCards: [Dieter_V1_Card] = []
    /// Archived chats, which the core's live workspace omits.
    var archivedChats: [Dieter_V1_Card] = []
    /// The account's navigation layout as the core shows it: the sidebar's
    /// projects, folders, and pins, and the saved disclosure of each list.
    var navigation = ClientNavigationSlice()
    /// The chats pane's list, as the core lays it out.
    let chatsList = ChatsListModel(scope: "mac-chats")

    @ObservationIgnored var navigationEditTail: Task<Void, Never>?
    var navigationPendingCount = 0
    /// The core has replayed the account's navigation since it attached a machine.
    @ObservationIgnored var navigationCaughtUp = false
    var navigationSyncError: String?
    let conversationModel = ConversationModel()
    @ObservationIgnored var onConversationContentConnectionChanged: @MainActor () -> Void = {}
    @ObservationIgnored lazy var conversationContext = makeConversationContext()
    /// The selected project's conversation workspaces, as the core lists them.
    var projectWorkspaces: [ClientProjectWorkspaceRow] = []
    let schedulesModel = SchedulesModel()
    let terminalsModel: TerminalsModel
    let screensModel: ScreensModel
    @ObservationIgnored lazy var terminalOverview = TerminalOverviewModel(
        terminalsModel: terminalsModel, core: core,
        endpointID: { [weak self] in self?.endpointID(forDaemon: $0) ?? $0 },
        active: { [weak self] in self?.section == .terminals && self?.terminalsModel.terminalScopeCardID == nil },
        reportError: { [weak self] in self?.errorMessage = $0 })
    let filesModel = FilesModel()
    let worktreeChanges = WorktreeChangesModel()
    let projectChanges = ProjectChangesModel()
    /// Counts `refreshState()` calls; navigating a live workspace makes none.
    @ObservationIgnored var stateRefreshCount: UInt64 = 0
    var chatsRequestGeneration: UInt64 = 0
    /// This device shows reasoning traces. The core keeps the preference,
    /// reports it in the session slice, and regroups conversations for it.
    var showReasoning = false {
        didSet {
            guard showReasoning != oldValue else { return }
            #if DIETER_UI_SMOKE
                conversationModel.fixtureShowsReasoning = showReasoning
            #endif
            guard !foldingShowReasoning else { return }
            let show = showReasoning
            Task { await perform { $0.setShowReasoning = .with { $0.show = show } } }
        }
    }
    @ObservationIgnored var foldingShowReasoning = false
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
    var machineFilter = "" {
        didSet { if machineFilter != oldValue { refreshBoardProjection() } }
    }
    var stateFilter = ClientBoardStateFilter.all {
        didSet { if stateFilter != oldValue { refreshBoardProjection() } }
    }
    var labelFilter = "" {
        didSet { if labelFilter != oldValue { refreshBoardProjection() } }
    }
    /// The core's view of the selected board, and what it was last told to show.
    /// The core's view of the board the Mac shows.
    @ObservationIgnored let boardViewModel = BoardViewModel(scope: "mac-board")
    var boardView: ClientBoardViewSlice { boardViewModel.slice }
    /// What the board shows for each shown card and offers on it.
    var boardCardFlags: [String: ClientBoardCardFlags] = [:]
    /// Board ID → its cards in a review lane or with a working agent.
    var boardAttention: [String: Int32] = [:]
    var movingCardIDs: Set<String> = []
    var labelUpdatingCardIDs: Set<String> = []
    var pendingCardIDs: Set<String> = []
    var pendingMessageIDs: Set<String> = []
    var acceptedOutboxIDs: Set<String> = []
    var failedOutboxIDs: Set<String> = []
    /// What waits for each machine in the outbox, as the core words it.
    var machineOutboxes: [ClientMachineOutbox] = []
    /// When the attached machine's feed last applied an update.
    var lastSyncedAt: Date?
    var islandActivity = DieterIslandActivity.empty
    var boardProjection = BoardProjection.empty

    var selectedProjectIsLive: Bool {
        workspaceIsLive && (projectReplicaEndpointIDs[selectedProjectID] ?? endpoint.id) == endpoint.id
    }

    /// `machine` as the core presents it; nil for a machine it does not list.
    func machineEntry(_ machine: MachineEndpoint) -> ClientMachineEntry? {
        machineEntries[machine.id]
    }

    /// Whether `machine` can host projects, terminals, and operations now.
    func machineIsAvailable(_ machine: MachineEndpoint) -> Bool {
        machineEntry(machine)?.available == true
    }

    /// Why `machine` cannot take work now, as the core words it; nil when it can.
    func unavailableReason(_ machine: MachineEndpoint) -> String? {
        guard let entry = machineEntry(machine) else { return SharedRules.shared.unenrolledMachineMessage() }
        return entry.available ? nil : entry.unavailableMessage
    }

    /// Checkouts picked on this Mac for new conversations, by project; the
    /// core remembers each pick too.
    var creationCheckoutIDs: [String: String] = [:]

    func projectIsAvailable(_ projectID: String) -> Bool {
        guard let machine = replica(forProjectID: projectID) else { return workspaceIsLive }
        return machineIsAvailable(machine)
    }

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
    #if DIETER_UI_SMOKE
        /// The `--dieter-access-token-file` session smoke fixtures use for host-side calls.
        let accessTokenOverride: String?
    #endif
    @ObservationIgnored let themeDefaults: UserDefaults
    var gatewayOrigins: [MachineEndpoint]
    @ObservationIgnored let environment: DieterAppEnvironment
    let attachmentLoader = AttachmentLoader()

    /// `core` replaces the shared core, e.g. with a `ScriptedCoreClient` in
    /// tests. Only `liveCore` builds the real one from the environment: it
    /// owns the state under the environment's storage root, so the app entry
    /// point and isolated integration tests opt in, and nothing else does.
    /// Without an `environment`, `liveEnvironment` picks the process's own
    /// (arguments, defaults, state root) or a throwaway one for tests.
    init(
        environment: DieterAppEnvironment? = nil,
        core: CoreClient? = nil,
        liveCore: Bool = false,
        themeDefaultsOverride: UserDefaults? = nil,
        liveEnvironment: Bool = true
    ) {
        let environment = environment ?? (liveEnvironment ? .live() : .testing(defaults: themeDefaultsOverride))
        self.environment = environment
        terminalsModel = TerminalsModel()
        screensModel = ScreensModel(defaults: environment.defaults)
        defaultConversationMode = ConversationDefaultMode.load(from: environment.defaults)
        let root =
            environment.storageRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        #if DIETER_UI_SMOKE
            accessTokenOverride = tokenOverride
        #endif
        let override = arguments.firstIndex(of: "--dieter-endpoint")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .flatMap { MachineEndpoint(address: $0, name: "Command line") }
        launchSession = override.flatMap { gateway in tokenOverride.map { (gateway, $0) } }
        let gateway = override ?? MachineEndpoint.defaultGateway
        endpoints = []
        endpoint = gateway
        gatewayOrigins = [gateway]
        var host: CoreHost?
        var screenMedia: CoreScreenMedia?
        if liveCore, core == nil {
            let defaults = environment.defaults
            let media = CoreScreenMedia.mac()
            screenMedia = media
            host = try? CoreHost(
                configuration: CoreHostConfiguration(
                    root: root, clientVersion: DieterRelease.current, logSubsystem: "com.dbpprt.dieter.mac"),
                platform: .mac(
                    credentialsFile: environment.credentialsFile, notificationsEnabled: { true },
                    clipboard: CoreScreenClipboard()),
                defaults: defaults, screens: CoreHostScreens(media: media))
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
}
