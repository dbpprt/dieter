#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import Observation
    import SharedCore

    /// The app's connection to the shared core: it hosts the core, observes
    /// the app-wide slices, and sends the session, gateway, and machine
    /// commands. Views read the slices' presentation-ready fields; feature
    /// models (conversation, files, terminals, screens) take `core` and own
    /// their surfaces' scopes.
    @MainActor
    @Observable
    final class IOSAppModel {
        private(set) var session = ClientSessionSlice()
        private(set) var workspace = ClientWorkspaceSlice()
        private(set) var navigation = ClientNavigationSlice()
        private(set) var activity = ClientActivitySlice()
        private(set) var outbox = ClientOutboxSlice()
        /// The last command failure, shown once.
        var errorMessage: String?
        /// The sign-in sheet is open or its callback is being exchanged.
        private(set) var signingIn = false
        /// The core has said whether the active gateway has a session; until
        /// then the app shows neither sign-in nor the workspace.
        private(set) var launched = false

        private(set) var cardsByID: [String: Dieter_V1_Card] = [:]
        private(set) var projectsByID: [String: Dieter_V1_Project] = [:]

        @ObservationIgnored let core: CoreClient
        /// Unsent composer text, kept by the core per conversation.
        @ObservationIgnored let drafts: CoreDraftTexts
        @ObservationIgnored let launch: IOSLaunchConfiguration
        /// The WebRTC engine screen views attach their renderers to; absent
        /// without a hosted core.
        @ObservationIgnored let screenMedia: CoreScreenMedia?
        /// The account's provider quotas, which the core watches on the gateway.
        @ObservationIgnored private(set) lazy var quotas = CoreProviderQuotas(core: core)
        @ObservationIgnored private let host: CoreHost?
        @ObservationIgnored private let authentication = IOSAuthentication()
        @ObservationIgnored private var subscriptions: [SliceSubscription] = []
        @ObservationIgnored private var startTask: Task<Void, Never>?
        @ObservationIgnored private var foregroundTail: Task<Void, Never>?
        @ObservationIgnored private var visibleTail: Task<Void, Never>?
        @ObservationIgnored private var visibleCardID: String?

        /// The app's model for this process, over the launch's core.
        static let live = IOSAppModel(launch: .shared)

        /// Hosts the shared core for this launch. A core that cannot open its
        /// state directory leaves the app on a scripted core that reports why.
        convenience init(launch: IOSLaunchConfiguration) {
            var failure: String?
            var host: CoreHost?
            let media = CoreScreenMedia.iOS()
            do {
                host = try CoreHost(
                    configuration: CoreHostConfiguration(
                        root: launch.root, clientVersion: DieterRelease.current, logSubsystem: "com.dbpprt.dieter.ios"),
                    platform: .iOS(
                        screenClientName: launch.screenClientName, notificationsEnabled: { false },
                        secureStore: Self.secureStore(launch), clipboard: CoreUIPasteboardClipboard()),
                    defaults: launch.defaults,
                    screens: CoreHostScreens(media: media, fixture: Self.screenFixture(launch)))
            } catch {
                failure = error.localizedDescription
            }
            self.init(
                core: host?.client ?? ScriptedCoreClient(), host: host, launch: launch,
                screenMedia: host == nil ? nil : media)
            errorMessage = failure
            if host == nil { launched = true }
        }

        /// A model over `core`, e.g. a scripted one in tests.
        init(
            core: CoreClient, host: CoreHost? = nil, launch: IOSLaunchConfiguration,
            screenMedia: CoreScreenMedia? = nil
        ) {
            self.core = core
            self.host = host
            self.launch = launch
            self.screenMedia = screenMedia
            drafts = CoreDraftTexts(core: core)
        }

        private static func secureStore(_ launch: IOSLaunchConfiguration) -> any NativeSecureStore {
            #if DEBUG
                if launch.ephemeralCredentials { return IOSEphemeralSecureStore() }
            #endif
            return CoreKeychainSecureStore()
        }

        /// The isolated UI tests' native screen fixture, which every screen
        /// signals through (DEBUG only).
        private static func screenFixture(_ launch: IOSLaunchConfiguration) -> (any NativeScreenFixture)? {
            #if DEBUG
                if case .screen(let encoded) = launch.preview { return IOSScreenFixtureRoutes(encoded: encoded) }
            #endif
            return nil
        }

        // MARK: - Lifecycle

        /// Observes the app-wide slices, starts the core once, and adopts an
        /// isolated test run's session.
        func start() async {
            if let startTask { return await startTask.value }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                self.subscribe()
                self.host?.start()
                await self.drafts.load()
                if let test = self.launch.testSession {
                    await self.adoptSession(gatewayAddress: test.gatewayURL, token: test.token)
                }
            }
            startTask = task
            await task.value
        }

        /// The scene is active (keeps the streams live) or in the background.
        /// Sent in order once the core has started.
        func setForeground(_ foreground: Bool) {
            let previous = foregroundTail
            foregroundTail = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await self.start()
                await self.perform { $0.setForeground = .with { $0.foreground = foreground } }
            }
        }

        private func subscribe() {
            guard subscriptions.isEmpty else { return }
            subscriptions = [
                SliceSubscription(client: core, slice: .session) { [weak self] update in
                    guard let self, case .session(let value) = update.value else { return }
                    self.foldSession(value)
                },
                SliceSubscription(client: core, slice: .workspace) { [weak self] update in
                    guard let self else { return }
                    switch update.value {
                    case .workspace(let value): self.foldWorkspace(value)
                    case .workspaceDelta(let delta): self.foldWorkspace(self.workspace.applying(delta))
                    default: return
                    }
                },
                SliceSubscription(client: core, slice: .navigation) { [weak self] update in
                    guard let self, case .navigation(let value) = update.value else { return }
                    if self.navigation != value { self.navigation = value }
                },
                SliceSubscription(client: core, slice: .activity) { [weak self] update in
                    guard let self, case .activity(let value) = update.value else { return }
                    if self.activity != value { self.activity = value }
                },
                SliceSubscription(client: core, slice: .outbox) { [weak self] update in
                    guard let self, case .outbox(let value) = update.value else { return }
                    if self.outbox != value { self.outbox = value }
                },
            ]
        }

        private func foldSession(_ value: ClientSessionSlice) {
            if session != value { session = value }
            // Disconnected says nothing about the session until the core has
            // run once, unless the person chose to stay disconnected.
            if !launched, value.phase != .disconnected || activeGateway?.connect == false { launched = true }
        }

        private func foldWorkspace(_ value: ClientWorkspaceSlice) {
            guard workspace != value else { return }
            workspace = value
            cardsByID = Dictionary(value.cards.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            projectsByID = Dictionary(value.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        }

        // MARK: - Reading

        var signedIn: Bool { session.phase != .authRequired }
        var activeGateway: ClientGatewayEntry? { session.gateways.first(where: \.active) }

        func card(_ id: String) -> Dieter_V1_Card? { cardsByID[id] }
        func project(_ id: String) -> Dieter_V1_Project? { projectsByID[id] }
        func board(_ id: String) -> Dieter_V1_Board? {
            workspace.boards.first { $0.id == id } ?? workspace.retiredBoards.first { $0.id == id }
        }
        /// A project's boards in the workspace's order.
        func boards(in projectID: String) -> [Dieter_V1_Board] {
            workspace.boards.filter { $0.projectID == projectID }
        }
        func machine(_ id: String) -> ClientMachineEntry? { session.machines.first { $0.id == id } }

        /// The machine ID (`origin#daemon`) shared feature models take for a
        /// daemon. The core addresses machines by daemon, so the origin part
        /// only has to be present.
        nonisolated static func endpointID(daemonID: String) -> String { "core#" + daemonID }

        /// The machine's status line: the core's detail, followed by when it
        /// was last seen where that matters.
        func machineStatus(_ machine: ClientMachineEntry, now: Date = Date()) -> String { machine.statusLine(now: now) }

        // MARK: - Sign-in and session

        /// Opens the gateway's GitHub sign-in in the native sheet and hands
        /// its callback to the core, which exchanges it and connects.
        func signIn(gatewayAddress: String) async {
            guard !signingIn else { return }
            signingIn = true
            defer { signingIn = false }
            await start()
            guard
                let started = await perform({ $0.beginSignIn = .with { $0.gatewayURL = gatewayAddress } }),
                let url = URL(string: started.signInStarted.authorizeURL)
            else { return }
            do {
                guard let callback = try await authentication.authorize(url) else { return }
                await perform { $0.completeSignIn = .with { $0.callbackURL = callback.absoluteString } }
            } catch {
                show(error)
            }
        }

        /// Uses a gateway session token obtained elsewhere.
        @discardableResult
        func adoptSession(gatewayAddress: String, token: String, name: String = "") async -> Bool {
            await perform {
                $0.adoptSession = .with {
                    $0.gatewayURL = gatewayAddress
                    $0.sessionToken = token
                    $0.name = name
                }
            } != nil
        }

        /// Forgets this account's session and everything kept for it here.
        func signOut() async {
            authentication.cancel()
            await perform { $0.signOut = ClientSignOut() }
        }

        /// Connects now instead of at the core's next retry, and again after
        /// the person disconnected.
        func reconnect() async {
            await perform { $0.reconnect = ClientReconnect() }
        }

        // MARK: - Gateways

        /// The origin `UseGateway` accepts for `address`; empty when invalid.
        func gatewayOrigin(_ address: String) -> String {
            SharedRules.shared.gatewayOrigin(address: address.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func selectGateway(_ origin: String) async {
            await perform { $0.selectGateway = .with { $0.origin = origin } }
        }

        /// Makes the gateway at `address` active, adding it when it is new.
        @discardableResult
        func useGateway(address: String, name: String = "") async -> Bool {
            let origin = gatewayOrigin(address)
            guard !origin.isEmpty else { return false }
            return await perform {
                $0.useGateway = .with {
                    $0.url = origin
                    $0.name = name
                }
            } != nil
        }

        /// Removes a configured gateway; the core keeps at least one.
        func removeGateway(_ origin: String) async {
            await perform { $0.removeGateway = .with { $0.origin = origin } }
        }

        // MARK: - Machines and cards

        /// The conversation on screen, or none; the core marks it read as its
        /// replies arrive. Sent in order once the core has started.
        func setVisibleConversation(_ cardID: String?) {
            visibleCardID = cardID
            let previous = visibleTail
            visibleTail = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await self.start()
                _ = try? await self.core.dispatch { $0.setVisibleConversation = .with { $0.cardID = cardID ?? "" } }
            }
        }

        /// `cardID` left the screen; nothing is visible unless another
        /// conversation took its place.
        func conversationHidden(_ cardID: String) {
            if visibleCardID == cardID { setVisibleConversation(nil) }
        }

        /// Creates a task or chat as the core previews `intent`; the new
        /// card, or nil when the core refused it (the failure is shown).
        func createConversation(
            _ intent: ClientCreationIntent, chat: Bool, submissionID: String
        ) async -> Dieter_V1_Card? {
            await perform {
                $0.createConversation = .with {
                    $0.intent = intent
                    $0.chat = chat
                    $0.submissionID = submissionID
                }
            }?.card
        }

        /// Moves a card waiting in review to its board's done lane.
        func finish(cardID: String) async {
            await perform { $0.finishCard = .with { $0.cardID = cardID } }
        }

        // MARK: - Commands

        /// Runs a command on the core and shows its failure; nil on failure.
        @discardableResult
        func perform(_ build: (inout ClientCommand) -> Void) async -> ClientResult? {
            var command = ClientCommand()
            build(&command)
            do {
                return try await core.dispatch(command)
            } catch {
                show(error)
                return nil
            }
        }

        func show(_ error: any Error) {
            guard !(error is CancellationError) else { return }
            errorMessage = (error as? CoreFailure)?.message ?? error.localizedDescription
        }

        func shutdown() async {
            await drafts.save()
            subscriptions.forEach { $0.close() }
            subscriptions = []
            await host?.shutdown()
        }
    }
#endif
