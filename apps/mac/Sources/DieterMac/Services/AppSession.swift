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
        didSet {
            refreshLiveFlags()
            if phase.isConnected != oldValue.isConnected { onConversationContentConnectionChanged() }
        }
    }
    /// Connected, with every reachable machine's view caught up: nothing the
    /// workspace shows is cached or still loading (the core's `synced`).
    var workspaceIsLive = false
    /// What synchronized views with a cached workspace show while it is
    /// unavailable; nil while it is current.
    var workspaceNotice: ClientWorkspaceNotice?
    /// Each machine as the core presents it, by machine (endpoint) ID.
    var machineEntries: [String: ClientMachineEntry] = [:] {
        didSet { if machineEntries != oldValue { refreshLiveFlags() } }
    }

    /// Surfaces can change what lives on a machine while that machine is available.
    func refreshLiveFlags() {
        filesModel.isLive = filesAreLive
        schedulesModel.isLive = schedulesAreLive
        terminalsModel.isLive = terminalsAreLive
    }
    /// The gateway this Mac signs in to; its machines come with the session.
    var activeGateway: MachineEndpoint
    /// The active gateway's enrolled machines, in the core's order.
    var endpoints: [MachineEndpoint]
    let replica = WorkspaceReplica()
    /// The shared core: connection, sync, outbox, and conversations.
    @ObservationIgnored let core: CoreClient
    @ObservationIgnored let coreHost: CoreHost?
    @ObservationIgnored var coreStart: Task<Void, Never>?
    @ObservationIgnored var coreSubscriptions: [SliceSubscription] = []
    @ObservationIgnored var coreWorkspace = ClientWorkspaceSlice()
    @ObservationIgnored var coreMetadata = ClientMetadataSlice()
    var session = ClientSessionSlice()
    var outboxState = ClientOutboxSlice()
    var boardState = ClientBoardSlice()
    var creationMemory = ClientCreationSlice()
    /// The Inbox's rows, newest activity first, and what the island and the
    /// menu bar show of them, as the core classifies them.
    var activity = ClientActivitySlice() {
        didSet { refreshIslandActivity() }
    }
    /// Each machine's agents and runtime, by daemon ID, once read.
    var machineMetadata: [String: ClientMachineMetadata] = [:]
    /// Machines whose metadata this connection requested; each available
    /// machine's is read once it is listed.
    @ObservationIgnored var requestedMetadata: Set<String> = []
    /// UI fixtures that render injected state hold the core's folds; the
    /// latest slices apply when released.
    @ObservationIgnored var coreFoldsHeld = false {
        didSet { if oldValue, !coreFoldsHeld { releaseHeldFolds() } }
    }
    /// A session this launch adopts from `--dieter-endpoint` and `--dieter-access-token-file`.
    let launchSession: (gateway: MachineEndpoint, token: String)?
    @ObservationIgnored lazy var fleet = FleetModel(
        machines: { [weak self] in
            guard let self else { return [] }
            return self.machines.map {
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
    /// Some machine's complete, current view of the account's navigation is applied.
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
    /// Counts `refreshState()` calls; navigating never makes one.
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
    /// When some machine's view last changed, kept with the cached views.
    var lastSyncedAt: Date?
    var islandActivity = DieterIslandActivity.empty
    var boardProjection = BoardProjection.empty

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

    /// Whether a machine with a checkout of the project can take work now.
    func projectIsAvailable(_ projectID: String) -> Bool {
        projectMachine(forProjectID: projectID).map(machineIsAvailable) ?? false
    }

    var chatsLoading = false
    var chatsError: String?
    var archiveLoading = false
    var archiveError: String?
    var archiveRequestGeneration: UInt64 = 0

    var errorMessage: String?

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
        activeGateway = gateway
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

    /// Points the composer at the selected conversation's draft, which the
    /// core keeps per conversation on the machine that runs it. Project
    /// selection is not part of a draft's identity: chats open from any project.
    func bindComposer() {
        let id = selectedCardID ?? selectedChatID
        let card = selectedCard ?? selectedDetail.flatMap { $0.card.id == id ? $0.card : nil }
        guard let id, let card, !card.ownerDaemonID.isEmpty else { return composer.select(nil) }
        composer.select(WorkspaceTarget(endpointID: endpointID(for: card), projectID: "", conversationID: id))
    }
}
