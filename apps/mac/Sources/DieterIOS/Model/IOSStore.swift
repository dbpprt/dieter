#if os(iOS)
    import CryptoKit
    import DieterAPI
    import DieterClient
    import DieterCore
    import Foundation
    import GRPCCore
    import Observation

    @MainActor
    @Observable
    final class IOSStore {
        var gatewayAddress: String {
            didSet {
                if DieterEndpoint.parse(oldValue)?.credentialID != configuredOriginOrNil()?.credentialID {
                    cancelAuthentication()
                }
            }
        }
        private(set) var phase: ConnectionPhase = .disconnected
        private(set) var machines: [DieterEndpoint] = []
        private(set) var selectedMachineID: String?
        private(set) var projects: [Dieter_V1_Project] = []
        private(set) var boards: [Dieter_V1_Board] = []
        private(set) var cards: [Dieter_V1_Card] = []
        private(set) var chats: [Dieter_V1_Card] = []
        private(set) var harnesses: [Dieter_V1_Harness] = []
        private(set) var selectedCard: Dieter_V1_CardDetail?
        private(set) var conversation: Dieter_V1_Conversation?
        private(set) var hasOlderMessages = false
        private(set) var loadingOlder = false
        private(set) var isAuthenticated = false
        private(set) var errorMessage: String?
        private(set) var routeDescription = ""
        private(set) var providerQuotaGroups: [Dieter_Gateway_V1_ProviderQuotaGroup] = []
        private(set) var providerQuotasLoading = false
        private(set) var providerQuotaError: String?
        private(set) var providerQuotaMutatingAccounts: Set<String> = []
        private var pendingOperations = 0
        var busy: Bool { pendingOperations > 0 || phase == .connecting }
        var selectedMachine: DieterEndpoint? { machines.first { $0.daemonID == selectedMachineID } }

        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let connections = ConnectionManager()
        @ObservationIgnored private var authentication: IOSAuthentication?
        @ObservationIgnored private var authenticationOwnership = IOSAuthenticationOwnership()
        @ObservationIgnored private var gateway: DieterRPC?
        @ObservationIgnored private var gatewayTask: Task<Void, Never>?
        @ObservationIgnored private var dataPlane: DataPlaneConnection?
        @ObservationIgnored private var stateTask: Task<Void, Never>?
        @ObservationIgnored private var transcriptTask: Task<Void, Never>?
        @ObservationIgnored private var refreshTask: Task<Void, Never>?
        @ObservationIgnored private var providerQuotaTask: Task<Void, Never>?
        @ObservationIgnored private var reconnectTask: Task<Void, Never>?
        @ObservationIgnored private var authTask: Task<String, Error>?
        @ObservationIgnored private var connectionID = UUID()
        @ObservationIgnored private var selectionID = UUID()
        @ObservationIgnored private var bootstrapStarted = false
        @ObservationIgnored private var foreground = true
        @ObservationIgnored private var accessToken: String?
        @ObservationIgnored private var connectedOrigin: DieterEndpoint?
        @ObservationIgnored private var transcript = IOSTranscript()
        @ObservationIgnored private var clientID: String
        @ObservationIgnored private var createIdentity = IOSMutationIdentity()
        @ObservationIgnored private var messageIdentity = IOSMutationIdentity()
        @ObservationIgnored private var startIdentity = IOSMutationIdentity()

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            gatewayAddress = defaults.string(forKey: "DieterIOSGateway") ?? "https://board.dbpprt.com"
            clientID = defaults.string(forKey: "DieterIOSClientID") ?? "ios-\(UUID().uuidString.lowercased())"
            defaults.set(clientID, forKey: "DieterIOSClientID")
            #if DEBUG
                if let address = ProcessInfo.processInfo.environment["DIETER_IOS_TEST_GATEWAY"] {
                    gatewayAddress = address
                }
            #endif
        }

        deinit {
            stateTask?.cancel()
            transcriptTask?.cancel()
            refreshTask?.cancel()
            providerQuotaTask?.cancel()
            reconnectTask?.cancel()
            authTask?.cancel()
            dataPlane?.shutdown()
            gatewayTask?.cancel()
            gateway?.shutdown()
        }

        func bootstrap() async {
            guard !bootstrapStarted else { return }
            bootstrapStarted = true
            await reconnect()
        }

        func clearError() { errorMessage = nil }

        func show(_ error: Error) { errorMessage = IOSUserError.message(error) }

        func signIn() async {
            cancelAuthentication()
            do {
                let origin = try configuredOrigin()
                let flow = IOSAuthentication()
                authentication = flow
                await authenticate(to: origin) { try await flow.signIn(to: origin) }
            } catch { errorMessage = IOSUserError.message(error) }
        }

        func connectWithToken(_ token: String) async {
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { errorMessage = "Enter a gateway session token."; return }
            cancelAuthentication()
            do {
                let origin = try configuredOrigin()
                await authenticate(to: origin) { token }
            } catch { errorMessage = IOSUserError.message(error) }
        }

        private func authenticate(
            to origin: DieterEndpoint,
            obtainToken: @MainActor @escaping () async throws -> String
        ) async {
            let attempt = authenticationOwnership.begin(gatewayID: origin.credentialID)
            // Own the complete exchange and Keychain write, so canceling a
            // replaced/sign-out attempt also cancels a not-yet-admitted save.
            let task = Task { [weak self] in
                let token = try await obtainToken()
                guard let self, self.ownsAuthentication(attempt), !Task.isCancelled else {
                    throw CancellationError()
                }
                try await DieterCredentialStore.save(token, for: origin)
                guard self.ownsAuthentication(attempt), !Task.isCancelled else { throw CancellationError() }
                return token
            }
            authTask = task
            pendingOperations += 1
            defer {
                pendingOperations -= 1
                // A previous task can complete after a newer sign-in starts.
                if authenticationOwnership.finish(attempt) {
                    authTask = nil
                    authentication = nil
                }
            }
            do {
                _ = try await task.value
                let shouldConnect = authenticationOwnership.shouldConnect(
                    attempt, gatewayID: configuredOriginOrNil()?.credentialID, foreground: foreground)
                // Authentication is complete once its token is persisted. Retire
                // it before suspending in reconnect so a foreground return can
                // replace that connection attempt instead of waiting on auth.
                if authenticationOwnership.finish(attempt) {
                    authTask = nil
                    authentication = nil
                }
                if shouldConnect { await reconnect() }
            } catch is CancellationError {
            } catch {
                if ownsAuthentication(attempt) { errorMessage = IOSUserError.message(error) }
            }
        }

        private func ownsAuthentication(_ attempt: IOSAuthenticationOwnership.Attempt) -> Bool {
            authenticationOwnership.accepts(attempt, gatewayID: configuredOriginOrNil()?.credentialID)
        }

        private func cancelAuthentication() {
            authenticationOwnership.invalidate()
            authTask?.cancel()
            authTask = nil
            authentication?.cancel()
            authentication = nil
        }

        func signOut() async {
            let origins = [connectedOrigin, configuredOriginOrNil()].compactMap { $0 }
            cancelAuthentication()
            closeConnections(clearContent: true)
            machines = []
            selectedMachineID = nil
            isAuthenticated = false
            accessToken = nil
            phase = .authenticationRequired
            var removedOrigins = Set<String>()
            for origin in origins where removedOrigins.insert(origin.credentialID).inserted {
                do { try await DieterCredentialStore.remove(for: origin) } catch {
                    errorMessage = "Could not remove the saved sign-in: \(IOSUserError.message(error))"
                }
            }
        }

        func reconnect() async {
            guard foreground else { return }
            let previousID = selectedMachineID
            let previousCardID = selectedCard?.card.id
            let retainingSnapshot = IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: connectedOrigin, currentDaemonID: previousID,
                requestedOrigin: configuredOriginOrNil(), requestedDaemonID: previousID)
            closeConnections(clearContent: !retainingSnapshot)
            let attempt = connectionID
            phase = .connecting
            errorMessage = nil
            do {
                let origin = try configuredOrigin()
                if connectedOrigin?.credentialID != origin.credentialID {
                    machines = []
                    selectedMachineID = nil
                    isAuthenticated = false
                }
                connectedOrigin = origin
                var token = await DieterCredentialStore.token(for: origin)
                #if DEBUG
                    if ProcessInfo.processInfo.environment["DIETER_IOS_TEST_GATEWAY"] != nil {
                        token = ProcessInfo.processInfo.environment["DIETER_IOS_TEST_TOKEN"]
                    }
                #endif
                guard owns(attempt) else { return }
                guard let token, !token.isEmpty else {
                    isAuthenticated = false; phase = .authenticationRequired; return
                }
                accessToken = token
                let control = try DieterRPC(endpoint: origin, accessToken: token)
                gateway = control
                gatewayTask = ConnectionManager.run(control)
                let directory = try await control.daemons()
                guard owns(attempt) else { return }
                isAuthenticated = true
                machines = makeMachines(directory, origin: origin)
                startProviderQuotaRefresh(attempt: attempt)
                defaults.set(gatewayAddress, forKey: "DieterIOSGateway")
                let saved = defaults.string(forKey: "DieterIOSMachine:\(origin.credentialID)")
                let preferred = IOSMachinePolicy.preferred(in: machines, preferredID: previousID ?? saved)
                guard let machine = preferred else {
                    selectedMachineID =
                        retainingSnapshot
                        ? IOSWorkspaceContinuity.retainedOfflineSelection(in: machines, previousDaemonID: previousID)
                        : nil
                    if selectedMachineID == nil { clearNodeContent() }
                    phase = .disconnected
                    errorMessage =
                        machines.isEmpty
                        ? "No machines are enrolled for this account."
                        : machines.contains(where: \.online)
                            ? "Update your online machines to Dieter API \(IOSMachinePolicy.apiVersion)."
                            : "Your machines are offline."
                    startDirectoryRefresh(attempt: attempt)
                    return
                }
                try await connectMachine(machine, attempt: attempt)
                guard owns(attempt) else { return }
                if let previousCardID,
                    cards.contains(where: { $0.id == previousCardID })
                        || chats.contains(where: { $0.id == previousCardID })
                {
                    await selectCard(id: previousCardID)
                }
                guard owns(attempt) else { return }
                startDirectoryRefresh(attempt: attempt)
            } catch {
                guard owns(attempt) else { return }
                connectionFailed(error, attempt: attempt)
            }
        }

        func refreshMachines() async {
            guard let control = gateway, let origin = connectedOrigin else { await reconnect(); return }
            let attempt = connectionID
            do {
                let directory = try await control.daemons()
                guard owns(attempt) else { return }
                machines = makeMachines(directory, origin: origin)
                if case .incompatible = phase { return }
                if dataPlane == nil,
                    let first = IOSMachinePolicy.preferred(in: machines, preferredID: selectedMachineID)
                {
                    try await connectMachine(first, attempt: attempt)
                    guard owns(attempt) else { return }
                    if let cardID = selectedCard?.card.id,
                        cards.contains(where: { $0.id == cardID }) || chats.contains(where: { $0.id == cardID })
                    {
                        await selectCard(id: cardID)
                    }
                    guard owns(attempt) else { return }
                    // A directory poll may own this recovery. Keep that task
                    // alive rather than canceling it while restoring the watch.
                    if refreshTask == nil { startDirectoryRefresh(attempt: attempt) }
                }
            } catch {
                guard owns(attempt) else { return }
                connectionFailed(error, attempt: attempt)
            }
        }

        func selectMachine(id: String) async {
            guard let machine = machines.first(where: { $0.daemonID == id || $0.id == id }) else { return }
            guard selectedMachineID != machine.daemonID || !phase.isConnected else { return }
            // Preserve the authenticated gateway but retire all node-owned requests.
            connectionID = UUID()
            let attempt = connectionID
            stateTask?.cancel(); stateTask = nil
            transcriptTask?.cancel(); transcriptTask = nil
            refreshTask?.cancel(); refreshTask = nil
            reconnectTask?.cancel(); reconnectTask = nil
            dataPlane?.shutdown(); dataPlane = nil
            clearNodeContent()
            selectedMachineID = machine.daemonID
            phase = .connecting
            errorMessage = nil
            do {
                try await connectMachine(machine, attempt: attempt)
                guard owns(attempt) else { return }
                startProviderQuotaRefresh(attempt: attempt)
                startDirectoryRefresh(attempt: attempt)
            } catch {
                guard owns(attempt) else { return }
                connectionFailed(error, attempt: attempt)
            }
        }

        private func connectMachine(_ machine: DieterEndpoint, attempt: UUID) async throws {
            guard let gateway, let accessToken else { throw IOSAuthenticationError.invalidResponse }
            if !IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: connectedOrigin, currentDaemonID: selectedMachineID,
                requestedOrigin: machine.gatewayEndpoint, requestedDaemonID: machine.daemonID)
            {
                clearNodeContent()
            }
            selectedMachineID = machine.daemonID
            guard IOSMachinePolicy.isCompatible(machine) else { throw IOSStoreError.incompatible(machine.apiVersion) }
            var candidateScope = DirectCandidateScope.nonLoopback
            #if DEBUG
                if ProcessInfo.processInfo.environment["DIETER_IOS_TEST_GATEWAY"] != nil { candidateScope = .all }
            #endif
            let plane = try await connections.selectDataPlane(
                gateway: gateway, target: machine, gatewayAccessToken: accessToken, directCandidateScope: candidateScope
            )
            guard owns(attempt) else { plane.shutdown(); return }
            dataPlane = plane
            let health = try await plane.rpc.health(timeout: .seconds(5))
            guard health.version == IOSMachinePolicy.apiVersion else {
                throw IOSStoreError.incompatible(health.version)
            }
            var request = Dieter_V1_GetStateRequest()
            request.allProjects = true
            async let state = plane.rpc.state(request)
            async let catalog = plane.rpc.harnesses()
            let (stateValue, catalogValue) = try await (state, catalog)
            guard owns(attempt) else { return }
            harnesses = catalogValue.harnesses
            applyState(stateValue)
            routeDescription = plane.connection.route == .local ? "Direct TLS" : plane.connection.route.rawValue
            phase = .connected(version: health.version)
            defaults.set(machine.daemonID, forKey: "DieterIOSMachine:\(machine.credentialID)")
            watchState(attempt: attempt)
        }

        private func watchState(attempt: UUID) {
            stateTask?.cancel()
            guard let rpc = dataPlane?.rpc else { return }
            stateTask = Task { [weak self] in
                var request = Dieter_V1_WatchStateRequest()
                request.filter.allProjects = true
                request.intervalMs = 1_500
                do {
                    try await rpc.watchState(request) { [weak self] value in
                        await self?.receiveState(value, attempt: attempt)
                    }
                    guard !Task.isCancelled else { return }
                    self?.connectionFailed(IOSStoreError.streamEnded, attempt: attempt)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.connectionFailed(error, attempt: attempt)
                }
            }
        }

        private func receiveState(_ value: Dieter_V1_State, attempt: UUID) {
            guard owns(attempt) else { return }
            applyState(value)
        }

        private func applyState(_ value: Dieter_V1_State) {
            guard !value.notModified else { return }
            projects = value.projects.filter { !$0.archived }
            boards = value.boards
            cards = value.cards.filter { !$0.archived }
            chats = value.chats.filter { !$0.archived }
            if let selected = selectedCard, let current = (cards + chats).first(where: { $0.id == selected.card.id }) {
                selectedCard?.card = current
            }
        }

        private func startDirectoryRefresh(attempt: UUID) {
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.owns(attempt) else { return }
                    if let expiry = self.dataPlane?.directTokenExpiresAt.flatMap(DieterTimestamp.date(from:)),
                        expiry.timeIntervalSinceNow < 45
                    {
                        self.refreshTask = nil
                        await self.reconnect()
                        return
                    }
                    await self.refreshMachines()
                }
            }
        }

        private func startProviderQuotaRefresh(attempt: UUID) {
            providerQuotaTask?.cancel()
            providerQuotaTask = Task { [weak self] in
                guard let self else { return }
                await self.loadProviderQuotas()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard self.owns(attempt) else { return }
                    await self.loadProviderQuotas()
                }
            }
        }

        func loadProviderQuotas(requestRefresh: Bool = false) async {
            guard !providerQuotasLoading, let control = gateway else { return }
            let attempt = connectionID
            providerQuotasLoading = true
            defer {
                if connectionID == attempt { providerQuotasLoading = false }
            }
            do {
                let groups =
                    if requestRefresh {
                        try await control.refreshProviderQuotas().groups
                    } else {
                        try await control.providerQuotas().groups
                    }
                guard owns(attempt) else { return }
                providerQuotaGroups = groups
                providerQuotaError = nil
            } catch {
                guard owns(attempt) else { return }
                providerQuotaError = IOSUserError.message(error)
            }
        }

        func setProviderQuotaSummaryInclusion(
            provider: Dieter_Gateway_V1_ProviderQuotaProvider,
            accountKey: String,
            included: Bool
        ) async {
            guard let control = gateway else { return }
            guard providerQuotaMutatingAccounts.insert(accountKey).inserted else { return }
            defer { providerQuotaMutatingAccounts.remove(accountKey) }
            let attempt = connectionID
            do {
                let response = try await control.setProviderQuotaSummaryInclusion(
                    provider: provider, accountKey: accountKey, included: included)
                guard owns(attempt) else { return }
                replaceProviderQuotaGroups(response.groups, provider: provider)
                providerQuotaError = nil
            } catch {
                guard owns(attempt) else { return }
                providerQuotaError = IOSUserError.message(error)
            }
        }

        func consumeProviderQuotaReset(accountKey: String) async {
            guard let control = gateway else { return }
            guard providerQuotaMutatingAccounts.insert(accountKey).inserted else { return }
            defer { providerQuotaMutatingAccounts.remove(accountKey) }
            let attempt = connectionID
            do {
                let response = try await control.consumeProviderQuotaReset(
                    accountKey: accountKey, idempotencyKey: UUID().uuidString.lowercased())
                guard owns(attempt) else { return }
                replaceProviderQuotaGroups(response.groups, provider: .openaiCodex)
                providerQuotaError =
                    response.accepted
                    ? nil : "No online machine with access to this OpenAI account accepted the reset."
            } catch {
                guard owns(attempt) else { return }
                providerQuotaError = IOSUserError.message(error)
            }
        }

        private func replaceProviderQuotaGroups(
            _ groups: [Dieter_Gateway_V1_ProviderQuotaGroup],
            provider: Dieter_Gateway_V1_ProviderQuotaProvider
        ) {
            providerQuotaGroups.removeAll { $0.provider == provider }
            providerQuotaGroups.append(contentsOf: groups)
            providerQuotaGroups.sort { $0.provider.rawValue < $1.provider.rawValue }
        }

        func selectCard(id: String) async {
            let hasReadableSnapshot = selectedCard?.card.id == id && conversation?.cardID == id
            if hasReadableSnapshot, transcriptTask != nil { return }
            if hasReadableSnapshot {
                // A reconnect retired the old watch. Keep its readable snapshot
                // while fetching a fresh one, under a new navigation generation.
                selectionID = UUID()
                loadingOlder = false
            } else {
                closeConversation()
            }
            guard let rpc = dataPlane?.rpc else { return }
            let scope = scope
            selectedCard = (cards + chats).first(where: { $0.id == id }).map { card in
                var detail = Dieter_V1_CardDetail(); detail.card = card; return detail
            }
            do {
                let snapshot = try await rpc.conversation(cardID: id, limit: 60)
                guard owns(scope) else { return }
                selectedCard = snapshot.detail
                transcript.reset(snapshot)
                publishTranscript()
                watchConversation(id: id, scope: scope)
            } catch {
                guard owns(scope) else { return }
                errorMessage = IOSUserError.message(error)
                if hasReadableSnapshot {
                    // Resume from the retained sequence even if the refresh RPC
                    // failed. The stream already owns bounded retry handling.
                    watchConversation(id: id, scope: scope)
                }
            }
        }

        func closeConversation() {
            selectionID = UUID()
            transcriptTask?.cancel(); transcriptTask = nil
            selectedCard = nil
            conversation = nil
            transcript = IOSTranscript()
            hasOlderMessages = false
            loadingOlder = false
        }

        private func watchConversation(id: String, scope: IOSRequestScope) {
            transcriptTask?.cancel()
            guard let rpc = dataPlane?.rpc else { return }
            let sequence = transcript.conversation?.lastSeq ?? 0
            transcriptTask = Task { [weak self] in
                do {
                    try await rpc.watchConversation(cardID: id, after: sequence) { [weak self] update in
                        await self?.receiveConversation(update, scope: scope)
                    }
                    guard !Task.isCancelled else { return }
                    self?.conversationStreamFailed(IOSStoreError.streamEnded, id: id, scope: scope)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.conversationStreamFailed(error, id: id, scope: scope)
                }
            }
        }

        private func receiveConversation(_ update: Dieter_V1_ConversationUpdate, scope: IOSRequestScope) {
            guard owns(scope) else { return }
            transcript.apply(update)
            if update.hasSnapshot {
                selectedCard = update.snapshot.detail
            } else if update.hasDetail {
                selectedCard = update.detail
            }
            publishTranscript()
        }

        private func conversationStreamFailed(_ error: Error, id: String, scope: IOSRequestScope) {
            guard owns(scope) else { return }
            if (error as? RPCError)?.code == .unauthenticated {
                connectionFailed(error, attempt: scope.connection)
                return
            }
            errorMessage = "Conversation interrupted. Reconnecting…"
            transcriptTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.owns(scope) else { return }
                self.transcriptTask = nil
                self.watchConversation(id: id, scope: scope)
            }
        }

        func loadOlderMessages() async {
            guard !loadingOlder, hasOlderMessages, let rpc = dataPlane?.rpc, let current = conversation else { return }
            let scope = scope
            let before = transcript.page.start
            loadingOlder = true
            defer { if owns(scope) { loadingOlder = false } }
            do {
                let previous = try await rpc.conversation(cardID: current.cardID, limit: 60, before: before)
                guard owns(scope) else { return }
                if transcript.prepend(previous, expectedSequence: current.lastSeq) { publishTranscript() }
            } catch {
                guard owns(scope) else { return }
                errorMessage = IOSUserError.message(error)
            }
        }

        @discardableResult
        func trimHistoryAtBottom() -> Bool {
            guard transcript.trimToLatest() else { return false }
            publishTranscript()
            return true
        }

        private func publishTranscript() {
            conversation = transcript.conversation
            hasOlderMessages =
                transcript.page.hasMore_p && (conversation?.messages.count ?? 0) < IOSTranscript.maximumMessages
        }

        func createTask(
            projectID: String, boardID: String?, title: String, prompt: String,
            provider: String, model: String, effort: String, labelIDs: [String],
            providerOptions: [String: String], attachments: [Dieter_V1_MessagePart] = [], run: Bool
        ) async -> String? {
            guard pendingOperations == 0, let rpc = dataPlane?.rpc else { return nil }
            let attempt = connectionID
            let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty || !title.isEmpty else { errorMessage = "Describe the task first."; return nil }
            guard !run || !prompt.isEmpty else { errorMessage = "Add an initial task before running it."; return nil }
            guard !provider.isEmpty, !model.isEmpty else {
                errorMessage = "Choose an available provider and model."; return nil
            }
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            var request = Dieter_V1_CreateConversationRequest()
            request.projectID = projectID
            request.boardID = boardID ?? ""
            request.lane = run ? "running" : "todo"
            request.title =
                title.isEmpty
                ? String((prompt.split(separator: "\n").first.map(String.init) ?? prompt).prefix(100)) : title
            request.prompt = prompt
            request.provider = provider
            request.model = model
            request.effort = effort
            request.labelIds = labelIDs
            request.providerOptions = providerOptions
            request.attachments = attachments
            request.deferStart = !run
            request.workspaceMode = "project"
            request.clientID = clientID
            request.commandID = createIdentity.command(
                for: [
                    selectedMachine?.id ?? "", projectID, boardID ?? "", title, prompt, provider, model, effort,
                    String(run),
                ] + labelIDs + IOSCreateTaskProviderOptions.identity(providerOptions)
                    + attachments.map(Self.attachmentIdentity))
            do {
                let card = try await (boardID == nil ? rpc.createChat(request) : rpc.createCard(request))
                guard owns(attempt) else { return nil }
                createIdentity.acknowledge(command: request.commandID)
                if boardID == nil {
                    chats = IOSWorkspaceContinuity.admittingCreatedCard(card, into: chats)
                } else {
                    cards = IOSWorkspaceContinuity.admittingCreatedCard(card, into: cards)
                }
                await selectCard(id: card.id)
                return card.id
            } catch {
                guard owns(attempt) else { return nil }
                errorMessage =
                    "Could not confirm creation. Retrying the same task is safe. \(IOSUserError.message(error))"
                return nil
            }
        }

        private static func attachmentIdentity(_ part: Dieter_V1_MessagePart) -> String {
            let digest = SHA256.hash(data: part.data).map { String(format: "%02x", $0) }.joined()
            return [part.filename, part.mediaType, String(part.data.count), digest].joined(separator: "\u{0}")
        }

        func sendMessage(
            text: String, attachments: [Dieter_V1_MessagePart] = [],
            selection: Dieter_V1_HarnessSelection? = nil
        ) async -> Bool {
            guard pendingOperations == 0, let rpc = dataPlane?.rpc, let card = selectedCard?.card else { return false }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !attachments.isEmpty else { return false }
            let scope = scope
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            var request = Dieter_V1_SendMessageRequest()
            request.cardID = card.id
            if !text.isEmpty {
                var part = Dieter_V1_MessagePart(); part.type = "text"; part.text = text
                request.parts = [part]
            }
            request.parts.append(contentsOf: attachments)
            request.provider = selection?.provider ?? card.provider
            request.model = selection?.model ?? card.model
            request.effort = selection?.effort ?? card.effort
            request.providerOptions = selection?.providerOptions ?? card.providerOptions
            request.clientID = clientID
            let attachmentIdentity = attachments.map(Self.attachmentIdentity).joined(separator: "\u{1}")
            let optionIdentity = request.providerOptions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let command = messageIdentity.command(
                for: [
                    selectedMachine?.id ?? "", card.id, text, attachmentIdentity, request.provider, request.model,
                    request.effort,
                ] + optionIdentity)
            request.commandID = command
            request.messageID = "ios-\(command)"
            do {
                _ = try await rpc.sendMessage(request)
                guard owns(scope) else { return false }
                messageIdentity.acknowledge(command: request.commandID)
                return true
            } catch {
                guard owns(scope) else { return false }
                errorMessage =
                    "Could not confirm delivery. Retrying the same message is safe. \(IOSUserError.message(error))"
                return false
            }
        }

        func removeQueuedMessage(_ message: Dieter_V1_QueuedMessage) async -> Dieter_V1_QueuedMessage? {
            guard pendingOperations == 0, !message.id.isEmpty, let rpc = dataPlane?.rpc,
                let card = selectedCard?.card, conversation?.queue.contains(where: { $0.id == message.id }) == true
            else { return nil }
            let scope = scope
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            do {
                let removed = try await rpc.removeQueuedMessage(cardID: card.id, messageID: message.id)
                if owns(scope) {
                    _ = transcript.removeQueuedMessage(id: removed.id)
                    publishTranscript()
                }
                return removed
            } catch {
                if owns(scope) { errorMessage = IOSUserError.message(error) }
                return nil
            }
        }

        func steerQueuedMessage(_ message: Dieter_V1_QueuedMessage) async {
            guard conversation?.queue.first?.id == message.id,
                IOSConversationPresentation.isAgentWorking(
                    conversationStatus: conversation?.status ?? "", cardRuntime: selectedCard?.card.runtime ?? "")
            else { return }
            await cancelTask()
        }

        func startTask() async {
            await mutateSelected { rpc, card in
                var request = Dieter_V1_StartCardRequest()
                request.cardID = card.id
                request.clientID = self.clientID
                request.commandID = self.startIdentity.command(for: [self.selectedMachine?.id ?? "", card.id])
                _ = try await rpc.startCard(request)
                self.startIdentity.acknowledge(command: request.commandID)
            }
        }

        func cancelTask() async { await mutateSelected { rpc, card in try await rpc.cancelCard(id: card.id) } }

        func moveTask(lane: String) async {
            await mutateSelected { rpc, card in
                var request = Dieter_V1_MoveCardRequest(); request.cardID = card.id; request.lane = lane
                _ = try await rpc.moveCard(request)
            }
        }

        private func mutateSelected(_ operation: (DieterRPC, Dieter_V1_Card) async throws -> Void) async {
            guard pendingOperations == 0, let rpc = dataPlane?.rpc, let card = selectedCard?.card else { return }
            let scope = scope
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            do {
                try await operation(rpc, card)
                guard owns(scope) else { return }
                let detail = try await rpc.card(id: card.id)
                guard owns(scope) else { return }
                selectedCard = detail
            } catch {
                guard owns(scope) else { return }
                errorMessage = IOSUserError.message(error)
            }
        }

        func listFiles(projectID: String, cardID: String = "", path: String = "") async -> Dieter_V1_FileList? {
            guard let rpc = dataPlane?.rpc else { return nil }
            let attempt = connectionID
            var request = Dieter_V1_ListFilesRequest()
            request.projectID = projectID; request.cardID = cardID; request.path = path
            do {
                let value = try await rpc.listFiles(request)
                return owns(attempt) ? value : nil
            } catch {
                if owns(attempt) { errorMessage = IOSUserError.message(error) }
                return nil
            }
        }

        func readFile(projectID: String, cardID: String = "", path: String) async -> Dieter_V1_FileDocument? {
            guard let rpc = dataPlane?.rpc else { return nil }
            let attempt = connectionID
            var request = Dieter_V1_ReadFileRequest()
            request.projectID = projectID; request.cardID = cardID; request.path = path
            do {
                let value = try await rpc.readFile(request)
                return owns(attempt) ? value : nil
            } catch {
                if owns(attempt) { errorMessage = IOSUserError.message(error) }
                return nil
            }
        }

        func readConversationImage(projectID: String, cardID: String, url: URL) async -> Dieter_V1_FileDocument? {
            guard let rpc = dataPlane?.rpc, RemoteWorkspaceImage.isWorkspaceImageURL(url) else { return nil }
            let attempt = connectionID
            do {
                let path: String
                if let relative = RemoteWorkspaceImage.relativePath(from: url) {
                    path = relative
                } else {
                    let workspace = try await rpc.workspace(cardID: cardID)
                    guard owns(attempt),
                        let relative = RemoteWorkspaceImage.relativePath(from: url, workspaceRoot: workspace.path)
                    else { return nil }
                    path = relative
                }
                var request = Dieter_V1_ReadFileRequest()
                request.projectID = projectID; request.cardID = cardID; request.path = path
                let value = try await rpc.readFile(request)
                return owns(attempt) ? value : nil
            } catch {
                if owns(attempt) { errorMessage = IOSUserError.message(error) }
                return nil
            }
        }

        func saveFile(projectID: String, cardID: String = "", document: Dieter_V1_FileDocument, content: String) async
            -> Dieter_V1_FileDocument?
        {
            guard let rpc = dataPlane?.rpc, !document.binary else { return nil }
            let attempt = connectionID
            var request = Dieter_V1_SaveFileRequest()
            request.projectID = projectID; request.cardID = cardID; request.path = document.path
            request.content = content; request.revision = document.revision
            do {
                let value = try await rpc.saveFile(request)
                return owns(attempt) ? value : nil
            } catch {
                if owns(attempt) {
                    errorMessage =
                        "Could not confirm the save. Your edits are still here. \(IOSUserError.message(error))"
                }
                return nil
            }
        }

        func remoteDesktopConnection() async throws -> RemoteDesktopSignalingConnection {
            guard foreground, let gateway, let accessToken, let target = selectedMachine else {
                throw NSError(
                    domain: "DieterScreens", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Select a connected Dieter machine."])
            }
            guard target.online else {
                throw NSError(
                    domain: "DieterScreens", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."])
            }
            guard IOSMachinePolicy.isCompatible(target) else {
                throw IOSStoreError.incompatible(target.apiVersion)
            }
            var candidateScope = DirectCandidateScope.nonLoopback
            #if DEBUG
                if ProcessInfo.processInfo.environment["DIETER_IOS_TEST_GATEWAY"] != nil {
                    candidateScope = .all
                }
            #endif
            return try await connections.remoteDesktopConnection(
                gateway: gateway, target: target, gatewayAccessToken: accessToken,
                directCandidateScope: candidateScope)
        }

        func suspend() {
            foreground = false
            // Keep an in-progress web sign-in alive for authenticator/2FA app
            // switches. Foreground RPC streams still release their resources.
            closeConnections(clearContent: false)
            phase = .disconnected
        }

        func resume() {
            guard !foreground else { return }
            foreground = true
            // Its completion reconnects if foreground; if it finished while
            // suspended, the accepted token is already in Keychain below.
            guard authTask == nil else { return }
            reconnectTask = Task { [weak self] in
                guard let self else { return }
                self.reconnectTask = nil
                await self.reconnect()
            }
        }

        private var scope: IOSRequestScope { .init(connection: connectionID, selection: selectionID) }
        private func owns(_ id: UUID) -> Bool { foreground && connectionID == id && !Task.isCancelled }
        private func owns(_ scope: IOSRequestScope) -> Bool {
            scope.accepts(connection: connectionID, selection: selectionID, active: foreground && !Task.isCancelled)
        }

        private func closeConnections(clearContent: Bool) {
            connectionID = UUID()
            selectionID = UUID()
            loadingOlder = false
            stateTask?.cancel(); stateTask = nil
            transcriptTask?.cancel(); transcriptTask = nil
            refreshTask?.cancel(); refreshTask = nil
            providerQuotaTask?.cancel(); providerQuotaTask = nil
            reconnectTask?.cancel(); reconnectTask = nil
            dataPlane?.shutdown(); dataPlane = nil
            gatewayTask?.cancel(); gatewayTask = nil
            gateway?.shutdown(); gateway = nil
            connections.invalidateTemporaryLeases()
            if clearContent {
                providerQuotaGroups = []
                providerQuotasLoading = false
                providerQuotaError = nil
                providerQuotaMutatingAccounts = []
                clearNodeContent()
            }
        }

        private func clearNodeContent() {
            projects = []; boards = []; cards = []; chats = []; harnesses = []
            routeDescription = ""
            closeConversation()
        }

        private func connectionFailed(_ error: Error, attempt: UUID) {
            guard owns(attempt) else { return }
            // Retire every response still owned by the failed transport. Keep the
            // last readable snapshot, but no old RPC may re-enable or replace it.
            connectionID = UUID()
            selectionID = UUID()
            loadingOlder = false
            let retryAttempt = connectionID
            refreshTask?.cancel(); refreshTask = nil
            stateTask?.cancel(); stateTask = nil
            transcriptTask?.cancel(); transcriptTask = nil
            let requiresSignIn = (error as? RPCError)?.code == .unauthenticated
            if case IOSStoreError.incompatible(let version) = error {
                phase = .incompatible(found: version)
                errorMessage = IOSUserError.message(error)
                dataPlane?.shutdown(); dataPlane = nil
                startDirectoryRefresh(attempt: retryAttempt)
                return
            }
            phase = requiresSignIn ? .authenticationRequired : .failed(IOSUserError.message(error))
            if requiresSignIn {
                isAuthenticated = false
                refreshTask?.cancel(); refreshTask = nil
                gatewayTask?.cancel(); gatewayTask = nil
                gateway?.shutdown(); gateway = nil
                connections.invalidateTemporaryLeases()
            }
            errorMessage = IOSUserError.message(error)
            dataPlane?.shutdown(); dataPlane = nil
            stateTask?.cancel(); stateTask = nil
            transcriptTask?.cancel(); transcriptTask = nil
            if !requiresSignIn, gateway != nil {
                reconnectTask?.cancel()
                reconnectTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, self.owns(retryAttempt) else { return }
                    self.reconnectTask = nil
                    await self.reconnect()
                }
            }
        }

        private func configuredOrigin() throws -> DieterEndpoint {
            guard let origin = configuredOriginOrNil() else { throw IOSStoreError.invalidGateway }
            #if DEBUG
                if ProcessInfo.processInfo.environment["DIETER_IOS_TEST_GATEWAY"] == gatewayAddress,
                    IOSMachinePolicy.isLoopbackTestEndpoint(origin)
                {
                    return origin
                }
            #endif
            guard origin.secure else { throw IOSAuthenticationError.secureEndpointRequired }
            return origin
        }

        private func configuredOriginOrNil() -> DieterEndpoint? {
            DieterEndpoint.parse(gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines), name: "Gateway")
        }

        private func makeMachines(_ response: Dieter_Gateway_V1_ListDaemonsResponse, origin: DieterEndpoint)
            -> [DieterEndpoint]
        {
            response.daemons.map {
                DieterEndpoint(
                    name: $0.name.isEmpty ? $0.id : $0.name, host: origin.host, port: origin.port,
                    secure: origin.secure, daemonID: $0.id,
                    online: MachinePresenceText.online(serverOnline: $0.online, lastSeenAt: $0.lastSeenAt),
                    lastSeenAt: $0.lastSeenAt, version: $0.version, apiVersion: $0.apiVersion)
            }.sorted { left, right in
                if left.online != right.online { return left.online }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    private enum IOSStoreError: LocalizedError {
        case invalidGateway, streamEnded, incompatible(String)
        var errorDescription: String? {
            switch self {
            case .invalidGateway: "Enter a gateway address such as https://board.dbpprt.com."
            case .streamEnded: "The connection ended. Reconnecting…"
            case .incompatible(let version):
                "This machine uses API \(version). Update its Dieter daemon to API \(IOSMachinePolicy.apiVersion)."
            }
        }
    }
#endif
