#if os(iOS)
    import DieterAPI
    import DieterClient
    import DieterCore
    import DieterShared
    import Foundation
    import Observation
    import SharedCore

    /// The iOS app's SwiftUI adapter. The shared core owns identity, routing,
    /// sync, durable intent, conversation reduction, and recovery; this type
    /// only translates its schema-first slices into the existing views.
    @MainActor
    @Observable
    final class IOSStore {
        var gatewayAddress: String {
            didSet { defaults.set(gatewayAddress, forKey: "DieterIOSGateway") }
        }

        private(set) var selectedCardID: String?
        private(set) var utilityMachineID: String?
        private(set) var errorMessage: String?
        private var terminalLocalError: String?
        private var pendingOperations = 0
        private var foreground = true

        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let core: IOSCoreStore
        @ObservationIgnored private var authentication: IOSAuthentication?
        @ObservationIgnored private var started = false

        @ObservationIgnored lazy var quotas = IOSCoreQuotas(core: core)

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            var stored = defaults.string(forKey: "DieterIOSGateway") ?? "https://gateway.getdieter.com"
            #if DEBUG
                stored = ProcessInfo.processInfo.environment["DIETER_IOS_TEST_GATEWAY"] ?? stored
            #endif
            let normalizedGateway = DieterEndpoint.parse(stored)?.currentPublicGateway.address ?? stored
            gatewayAddress = normalizedGateway
            core = IOSCoreStore(defaults: defaults)
            defaults.set(normalizedGateway, forKey: "DieterIOSGateway")
        }

        // MARK: Shared state

        var phase: ConnectionPhase {
            switch core.session.phase {
            case .connecting, .syncing, .reconnecting: .connecting
            case .connected: .connected(version: DieterRelease.current)
            case .authRequired: .authenticationRequired
            case .updateRequired: .incompatible(found: "")
            case .noMachine: .disconnected
            default: .disconnected
            }
        }

        var machines: [DieterEndpoint] {
            let gateway =
                DieterEndpoint.parse(core.session.gatewayOrigin)
                ?? DieterEndpoint.parse(gatewayAddress)
                ?? DieterEndpoint.defaults[0]
            return core.session.machines.map { machine in
                DieterEndpoint(
                    name: machine.name.isEmpty ? machine.id : machine.name,
                    host: gateway.host,
                    port: gateway.port,
                    secure: gateway.secure,
                    daemonID: machine.id,
                    online: machine.online,
                    lastSeenAt: machine.lastSeenAt,
                    releaseVersion: machine.releaseVersion,
                    compatibility: machine.compatible ? .compatible : .updateRequired,
                    minimumReleaseVersion: machine.minimumReleaseVersion,
                    remoteDesktopReady: machine.remoteDesktopReady,
                    remoteDesktopReason: machine.remoteDesktopReason,
                    remoteDesktopPlatform: machine.platform)
            }
        }

        var supportedMachines: [DieterEndpoint] { machines.filter { $0.compatibility == .compatible } }
        var utilityMachine: DieterEndpoint? {
            supportedMachines.first { $0.daemonID == utilityMachineID }
        }
        var machineRouteDescriptions: [String: String] {
            Dictionary(
                uniqueKeysWithValues: core.session.machines.compactMap { machine in
                    machine.route.isEmpty ? nil : (machine.id, machine.route)
                })
        }
        var projects: [Dieter_V1_Project] { core.workspace.projects.filter { !$0.archived } }
        var boards: [Dieter_V1_Board] { core.workspace.boards.filter { !$0.retired } }
        var cards: [Dieter_V1_Card] {
            core.workspace.cards.filter {
                !$0.archived && !($0.scope == "chat" && $0.boardID.isEmpty)
            }
        }
        var chats: [Dieter_V1_Card] {
            core.workspace.cards.filter { !$0.archived && $0.scope == "chat" && $0.boardID.isEmpty }
        }
        var selectedCard: Dieter_V1_CardDetail? {
            guard let id = selectedCardID,
                let card = (cards + chats).first(where: { $0.id == id })
                    ?? core.conversations[id]?.card
            else { return nil }
            var detail = Dieter_V1_CardDetail()
            detail.card = card
            if let project = projects.first(where: { $0.id == card.projectID }) { detail.project = project }
            if let board = boards.first(where: { $0.id == card.boardID }) { detail.board = board }
            return detail
        }
        var conversation: Dieter_V1_Conversation? {
            guard let id = selectedCardID, let slice = core.conversations[id], !slice.loading else { return nil }
            var value = slice.conversation
            value.messages = slice.messages
            return value
        }
        var conversationState: ClientConversationState? {
            guard let id = selectedCardID, let slice = core.conversations[id] else { return nil }
            return slice.state
        }
        var hasOlderMessages: Bool {
            selectedCardID.flatMap { core.conversations[$0]?.hasEarlier_p } ?? false
        }
        var loadingOlder: Bool {
            selectedCardID.flatMap { core.conversations[$0]?.loadingEarlier } ?? false
        }
        var isAuthenticated: Bool { core.session.signedIn }
        var busy: Bool { pendingOperations > 0 || phase == .connecting }
        var canSendMessage: Bool {
            phase.isConnected && !busy && selectedCardID != nil && conversation != nil
        }
        var clientID: String { core.clientID }
        var coreClient: LiveCoreClient { core.client }
        var screenMedia: IOSScreenMedia { core.screenMedia }
        var machineInformation: Dieter_V1_MachineInformation? {
            guard let id = utilityMachineID, let readings = core.telemetry.machines[id], readings.hasInformation else {
                return nil
            }
            return readings.information
        }
        var machineInformationLoading: Bool {
            utilityMachineID.flatMap { core.telemetry.machines[$0]?.loading } ?? false
        }
        var machineInformationError: String? {
            guard let id = utilityMachineID else { return nil }
            let error = core.telemetry.machines[id]?.error ?? ""
            return error.isEmpty ? nil : error
        }
        var terminalSlice: ClientTerminalsSlice { core.terminals }
        var terminalScreens: [String: IOSTerminalScreenState] { core.terminalScreens }
        var terminalError: String? {
            terminalLocalError ?? (core.terminals.error.isEmpty ? nil : core.terminals.error)
        }

        // MARK: Session

        func bootstrap() async {
            guard !started else { return }
            started = true
            if core.needsLegacyImport {
                let endpoint = DieterEndpoint.parse(gatewayAddress)
                let token: String?
                #if DEBUG
                    if ProcessInfo.processInfo.environment["DIETER_IOS_TEST_GATEWAY"] != nil {
                        token =
                            ProcessInfo.processInfo.environment["DIETER_IOS_TEST_START_SIGNED_OUT"] == "1"
                            ? nil : ProcessInfo.processInfo.environment["DIETER_IOS_TEST_TOKEN"]
                    } else if let endpoint {
                        token = await DieterCredentialStore.token(for: endpoint)
                    } else {
                        token = nil
                    }
                #else
                    if let endpoint {
                        token = await DieterCredentialStore.token(for: endpoint)
                    } else {
                        token = nil
                    }
                #endif
                let preferred = endpoint.flatMap {
                    defaults.string(forKey: "DieterIOSUtilityMachine:\($0.credentialID)")
                }
                do {
                    try await core.importLegacy(
                        gateway: gatewayAddress, token: token, preferredMachine: preferred)
                } catch {
                    errorMessage = IOSUserError.message(error)
                }
            }
            defaults.set(core.clientID, forKey: "DieterIOSClientID")
            core.start()
            await setForeground(true)
            restoreUtilityMachine()
        }

        func clearError() { errorMessage = nil }
        func show(_ error: Error) { errorMessage = message(error) }

        func signIn() async {
            guard pendingOperations == 0 else { return }
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            let authentication = IOSAuthentication()
            self.authentication = authentication
            do {
                var begin = ClientBeginSignIn()
                begin.gatewayURL = gatewayAddress
                var command = ClientCommand()
                command.beginSignIn = begin
                let started = try await core.dispatch(command).signInStarted
                guard let url = URL(string: started.authorizeURL) else {
                    throw IOSAuthenticationError.invalidResponse
                }
                let callback = try await authentication.callback(for: url)
                var complete = ClientCompleteSignIn()
                complete.callbackURL = callback.absoluteString
                command = ClientCommand()
                command.completeSignIn = complete
                let selected = try await core.dispatch(command).gatewaySelected
                gatewayAddress = selected.origin
                restoreUtilityMachine()
            } catch is CancellationError {
            } catch {
                errorMessage = message(error)
            }
            if self.authentication === authentication { self.authentication = nil }
        }

        func connectWithToken(_ token: String) async {
            do {
                try await adopt(token: token, gateway: gatewayAddress)
            } catch {
                errorMessage = message(error)
            }
        }

        private func adopt(token: String, gateway: String) async throws {
            var payload = ClientAdoptSession()
            payload.gatewayURL = gateway
            payload.sessionToken = token
            payload.name = "Custom"
            var command = ClientCommand()
            command.adoptSession = payload
            _ = try await core.dispatch(command)
            restoreUtilityMachine()
        }

        func signOut() async {
            authentication?.cancel()
            authentication = nil
            var command = ClientCommand()
            command.signOut = ClientSignOut()
            do { _ = try await core.dispatch(command) } catch { errorMessage = message(error) }
            selectedCardID = nil
            utilityMachineID = nil
        }

        func reconnect() async {
            var command = ClientCommand()
            command.resync = ClientResync()
            do { _ = try await core.dispatch(command) } catch { errorMessage = message(error) }
        }

        func refreshMachines() async { await reconnect() }

        func suspend() {
            guard foreground else { return }
            foreground = false
            Task { await selectTelemetry(active: false) }
            Task { await setForeground(false) }
        }

        func resume() {
            guard !foreground else { return }
            foreground = true
            Task { await setForeground(true) }
        }

        private func setForeground(_ value: Bool) async {
            var payload = ClientSetForeground()
            payload.foreground = value
            var command = ClientCommand()
            command.setForeground = payload
            do { _ = try await core.dispatch(command) } catch {
                if value { errorMessage = message(error) }
            }
        }

        // MARK: Machine utilities

        func selectUtilityMachine(id: String) {
            guard let machine = supportedMachines.first(where: { $0.daemonID == id || $0.id == id }) else {
                return
            }
            utilityMachineID = machine.daemonID
            if let endpoint = activeGatewayEndpoint() {
                defaults.set(machine.daemonID, forKey: "DieterIOSUtilityMachine:\(endpoint.credentialID)")
            }
        }

        private func restoreUtilityMachine() {
            let saved = activeGatewayEndpoint().flatMap {
                defaults.string(forKey: "DieterIOSUtilityMachine:\($0.credentialID)")
            }
            utilityMachineID =
                supportedMachines.first(where: { $0.daemonID == saved })?.daemonID
                ?? supportedMachines.first(where: \.online)?.daemonID
                ?? supportedMachines.first?.daemonID
        }

        func refreshMachineInformation() async {
            guard let machine = utilityMachine else {
                errorMessage = "Choose a machine to inspect its state."
                return
            }
            guard machine.online else {
                errorMessage = "\(machine.name) is offline."
                return
            }
            await selectTelemetry(active: true)
        }

        func loadProviderQuotas(requestRefresh: Bool = false) async {
            do { try await quotas.load(requestRefresh: requestRefresh) } catch { errorMessage = message(error) }
        }

        func setProviderQuotaSummaryInclusion(
            provider: Dieter_Gateway_V1_ProviderQuotaProvider, accountKey: String, included: Bool
        ) async {
            do {
                try await quotas.setSummaryInclusion(
                    provider: provider, accountKey: accountKey, included: included)
            } catch { errorMessage = message(error) }
        }

        func consumeProviderQuotaReset(accountKey: String) async {
            do { try await quotas.consumeReset(accountKey: accountKey) } catch { errorMessage = message(error) }
        }

        private func selectTelemetry(active: Bool) async {
            var payload = ClientTelemetrySelect()
            payload.daemonID = utilityMachineID ?? ""
            payload.active = active
            var telemetry = ClientTelemetryCommand()
            telemetry.select = payload
            var command = ClientCommand()
            command.telemetry = telemetry
            do { _ = try await core.dispatch(command) } catch {
                if active { errorMessage = message(error) }
            }
        }

        // MARK: Conversation

        func selectCard(id: String) async {
            guard selectedCardID != id else { return }
            if let previous = selectedCardID { core.stopObservingConversation(previous) }
            selectedCardID = id
            core.observeConversation(id)
            var visible = ClientSetVisibleConversation()
            visible.cardID = id
            var command = ClientCommand()
            command.setVisibleConversation = visible
            do { _ = try await core.dispatch(command) } catch { errorMessage = message(error) }
        }

        func closeConversation() {
            if let id = selectedCardID { core.stopObservingConversation(id) }
            selectedCardID = nil
            var command = ClientCommand()
            command.setVisibleConversation = ClientSetVisibleConversation()
            Task { try? await core.dispatch(command) }
        }

        func loadOlderMessages() async {
            guard let id = selectedCardID else { return }
            var payload = ClientLoadEarlierMessages()
            payload.cardID = id
            var command = ClientCommand()
            command.loadEarlierMessages = payload
            do { _ = try await core.dispatch(command) } catch { errorMessage = message(error) }
        }

        func trimHistoryAtBottom() -> Bool {
            guard let id = selectedCardID, core.conversations[id]?.browsingEarlier == true else { return false }
            var payload = ClientReturnToLatest()
            payload.cardID = id
            var command = ClientCommand()
            command.returnToLatest = payload
            Task { try? await core.dispatch(command) }
            return true
        }

        func creationHarnesses(projectID: String, checkoutID: String) async throws -> [Dieter_V1_Harness] {
            guard let project = projects.first(where: { $0.id == projectID }) else {
                throw IOSCoreFailure(kind: .invalid, message: "Choose a project first.")
            }
            let daemonID =
                project.checkouts.first(where: { $0.id == checkoutID })?.daemonID
                ?? core.workspace.projectReplicas[projectID]
                ?? ""
            return try await harnesses(daemonID: daemonID)
        }

        func conversationHarnesses() async throws -> [Dieter_V1_Harness] {
            try await harnesses(daemonID: selectedCard?.card.ownerDaemonID ?? "")
        }

        private func harnesses(daemonID: String) async throws -> [Dieter_V1_Harness] {
            var payload = ClientEnsureMetadata()
            payload.daemonID = daemonID
            var command = ClientCommand()
            command.ensureMetadata = payload
            _ = try await core.dispatch(command)
            guard let metadata = core.metadata.machines[daemonID], metadata.loaded else {
                throw IOSCoreFailure(
                    kind: .transient,
                    message: core.metadata.machines[daemonID]?.error.isEmpty == false
                        ? core.metadata.machines[daemonID]!.error : "Agent choices are still loading.")
            }
            return metadata.harnesses.harnesses
        }

        func createTask(
            projectID: String, checkoutID: String, boardID: String?, title: String, prompt: String,
            provider: String, model: String, effort: String, labelIDs: [String],
            providerOptions: [String: String], attachments: [Dieter_V1_MessagePart] = [], run: Bool
        ) async -> String? {
            guard pendingOperations == 0 else { return nil }
            let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty || !title.isEmpty else {
                errorMessage = "Describe the task first."
                return nil
            }
            guard !run || !prompt.isEmpty else {
                errorMessage = "Add an initial task before running it."
                return nil
            }
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            var request = Dieter_V1_CreateConversationRequest()
            request.projectID = projectID
            request.checkoutID = checkoutID
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
            var payload = ClientCreateConversation()
            payload.request = request
            payload.chat = boardID == nil
            var command = ClientCommand()
            command.createConversation = payload
            do {
                let card = try await core.dispatch(command).card
                await selectCard(id: card.id)
                return card.id
            } catch {
                errorMessage = message(error)
                return nil
            }
        }

        func sendMessage(
            text: String, attachments: [Dieter_V1_MessagePart] = [],
            selection: Dieter_V1_HarnessSelection? = nil
        ) async -> Bool {
            guard pendingOperations == 0, let card = selectedCard?.card else { return false }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !attachments.isEmpty else { return false }
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            var payload = ClientSendMessage()
            payload.cardID = card.id
            if !text.isEmpty {
                var part = Dieter_V1_MessagePart()
                part.type = "text"
                part.text = text
                payload.parts = [part]
            }
            payload.parts.append(contentsOf: attachments)
            if let selection { payload.selection = selection }
            var command = ClientCommand()
            command.sendMessage = payload
            do {
                _ = try await core.dispatch(command)
                return true
            } catch {
                errorMessage = message(error)
                return false
            }
        }

        func removeQueuedMessage(_ message: Dieter_V1_QueuedMessage) async -> Dieter_V1_QueuedMessage? {
            guard let cardID = selectedCardID, !message.id.isEmpty else { return nil }
            var payload = ClientRemoveQueuedMessage()
            payload.cardID = cardID
            payload.messageID = message.id
            var command = ClientCommand()
            command.removeQueuedMessage = payload
            do { return try await core.dispatch(command).queuedMessage } catch {
                errorMessage = self.message(error)
                return nil
            }
        }

        func steerQueuedMessage(_ message: Dieter_V1_QueuedMessage) async { await cancelTask() }

        func startTask() async {
            guard let id = selectedCardID else { return }
            var payload = ClientStartCard()
            payload.cardID = id
            payload.hasDraftAttachments_p = !(conversation?.draftAttachments.isEmpty ?? true)
            await dispatchMutation { $0.startCard = payload }
        }

        func cancelTask() async {
            guard let id = selectedCardID else { return }
            var payload = ClientCancelCard()
            payload.cardID = id
            await dispatchMutation { $0.cancelCard = payload }
        }

        func moveTask(lane: String) async {
            guard let id = selectedCardID else { return }
            var payload = ClientMoveCard()
            payload.cardID = id
            payload.lane = lane
            await dispatchMutation { $0.moveCard = payload }
        }

        private func dispatchMutation(_ configure: (inout ClientCommand) -> Void) async {
            guard pendingOperations == 0 else { return }
            pendingOperations += 1
            defer { pendingOperations -= 1 }
            var command = ClientCommand()
            configure(&command)
            do { _ = try await core.dispatch(command) } catch { errorMessage = message(error) }
        }

        // MARK: Shared utility surfaces

        func listFiles(projectID: String, checkoutID: String, cardID: String = "", path: String = "") async
            -> Dieter_V1_FileList?
        {
            do {
                try await bindFiles(projectID: projectID, checkoutID: checkoutID, cardID: cardID)
                var payload = ClientFilesPath()
                payload.path = path
                var files = ClientFilesCommand()
                files.scope = IOSCoreStore.filesScope
                files.load = payload
                var command = ClientCommand()
                command.files = files
                let slice = try await core.dispatch(command).files
                var list = Dieter_V1_FileList()
                list.path = slice.directory
                list.entries = slice.entries
                return list
            } catch {
                errorMessage = message(error)
                return nil
            }
        }

        func readFile(projectID: String, checkoutID: String, cardID: String = "", path: String) async
            -> Dieter_V1_FileDocument?
        {
            do {
                try await bindFiles(projectID: projectID, checkoutID: checkoutID, cardID: cardID)
                var payload = ClientFilesPath()
                payload.path = path
                var files = ClientFilesCommand()
                files.scope = IOSCoreStore.filesScope
                files.open = payload
                var command = ClientCommand()
                command.files = files
                let slice = try await core.dispatch(command).files
                guard slice.hasDocument else {
                    throw IOSCoreFailure(
                        kind: .transient,
                        message: slice.documentError.isEmpty ? "The file is still loading." : slice.documentError)
                }
                return slice.document
            } catch {
                errorMessage = message(error)
                return nil
            }
        }

        func readConversationImage(projectID: String, cardID: String, url: URL) async
            -> Dieter_V1_FileDocument?
        {
            guard RemoteWorkspaceImage.isWorkspaceImageURL(url) else { return nil }
            do {
                try await bindFiles(projectID: projectID, checkoutID: "", cardID: cardID)
                var payload = ClientFilesPath()
                payload.path = url.absoluteString
                var files = ClientFilesCommand()
                files.scope = IOSCoreStore.filesScope
                files.open = payload
                var command = ClientCommand()
                command.files = files
                let slice = try await core.dispatch(command).files
                guard slice.hasDocument else {
                    throw IOSCoreFailure(
                        kind: .transient,
                        message: slice.documentError.isEmpty ? "The image is still loading." : slice.documentError)
                }
                return slice.document
            } catch {
                errorMessage = message(error)
                return nil
            }
        }

        func saveFile(
            projectID: String, checkoutID: String, cardID: String = "",
            document: Dieter_V1_FileDocument, content: String
        ) async -> Dieter_V1_FileDocument? {
            guard !document.binary else { return nil }
            do {
                try await bindFiles(projectID: projectID, checkoutID: checkoutID, cardID: cardID)
                var payload = ClientFilesText()
                payload.text = content
                var files = ClientFilesCommand()
                files.scope = IOSCoreStore.filesScope
                files.save = payload
                var command = ClientCommand()
                command.files = files
                return try await core.dispatch(command).fileDocument
            } catch {
                errorMessage = "Could not confirm the save. Your edits are still here. \(message(error))"
                return nil
            }
        }

        private func bindFiles(projectID: String, checkoutID: String, cardID: String) async throws {
            var payload = ClientFilesTarget()
            payload.daemonID = try fileDaemonID(
                projectID: projectID, checkoutID: checkoutID, cardID: cardID)
            payload.projectID = projectID
            payload.checkoutID = checkoutID
            payload.cardID = cardID
            var files = ClientFilesCommand()
            files.scope = IOSCoreStore.filesScope
            files.bind = payload
            var command = ClientCommand()
            command.files = files
            _ = try await core.dispatch(command)
        }

        private func fileDaemonID(projectID: String, checkoutID: String, cardID: String) throws -> String {
            let daemonID =
                if !cardID.isEmpty {
                    (cards + chats).first(where: { $0.id == cardID })?.ownerDaemonID
                } else {
                    projects.first(where: { $0.id == projectID })?.checkouts
                        .first(where: { $0.id == checkoutID })?.daemonID
                        ?? core.workspace.projectReplicas[projectID]
                }
            guard let daemonID, supportedMachines.contains(where: { $0.daemonID == daemonID && $0.online }) else {
                throw IOSCoreFailure(kind: .transient, message: "Choose an available checkout and machine.")
            }
            return daemonID
        }

        func bindTerminals(machineID: String, active: Bool) async {
            guard foreground, phase.isConnected,
                supportedMachines.contains(where: { $0.daemonID == machineID && $0.online })
            else {
                terminalLocalError = "Choose a connected Dieter machine."
                return
            }
            terminalLocalError = nil
            do {
                var bind = ClientTerminalTarget()
                bind.daemonID = machineID
                bind.kind = .machine
                var terminals = ClientTerminalsCommand()
                terminals.scope = IOSCoreStore.terminalsScope
                terminals.bind = bind
                var command = ClientCommand()
                command.terminals = terminals
                _ = try await core.dispatch(command)
                await setTerminalsActive(active)
                await loadTerminals()
            } catch {
                terminalLocalError = message(error)
            }
        }

        func setTerminalsActive(_ active: Bool, clear: Bool = false) async {
            var payload = ClientTerminalToggle()
            payload.on = active
            var terminals = ClientTerminalsCommand()
            terminals.scope = IOSCoreStore.terminalsScope
            terminals.active = payload
            var command = ClientCommand()
            command.terminals = terminals
            do {
                _ = try await core.dispatch(command)
                if clear {
                    var clearCommand = ClientTerminalsCommand()
                    clearCommand.scope = IOSCoreStore.terminalsScope
                    clearCommand.bind = ClientTerminalTarget()
                    var reset = ClientCommand()
                    reset.terminals = clearCommand
                    _ = try await core.dispatch(reset)
                }
            } catch {
                terminalLocalError = message(error)
            }
        }

        func loadTerminals() async {
            var terminals = ClientTerminalsCommand()
            terminals.scope = IOSCoreStore.terminalsScope
            terminals.load = ClientTerminalStep()
            var command = ClientCommand()
            command.terminals = terminals
            do { _ = try await core.dispatch(command) } catch { terminalLocalError = message(error) }
        }

        func selectTerminal(_ id: String) async {
            var payload = ClientTerminalId()
            payload.terminalID = id
            var terminals = ClientTerminalsCommand()
            terminals.scope = IOSCoreStore.terminalsScope
            terminals.select = payload
            var command = ClientCommand()
            command.terminals = terminals
            do { _ = try await core.dispatch(command) } catch { terminalLocalError = message(error) }
        }

        func createTerminal(name: String, shell: String, workingDirectory: String) async -> Bool {
            var payload = ClientCreateTerminal()
            payload.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            payload.shell = shell
            payload.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            payload.columns = 80
            payload.rows = 24
            var terminals = ClientTerminalsCommand()
            terminals.scope = IOSCoreStore.terminalsScope
            terminals.create = payload
            var command = ClientCommand()
            command.terminals = terminals
            do {
                _ = try await core.dispatch(command)
                terminalLocalError = nil
                return true
            } catch {
                terminalLocalError = message(error)
                return false
            }
        }

        func renameTerminal(id: String, name: String) async {
            var payload = ClientTerminalRename()
            payload.terminalID = id
            payload.name = name
            var terminals = ClientTerminalsCommand()
            terminals.scope = IOSCoreStore.terminalsScope
            terminals.rename = payload
            var command = ClientCommand()
            command.terminals = terminals
            do { _ = try await core.dispatch(command) } catch { terminalLocalError = message(error) }
        }

        func closeTerminal(id: String) async {
            var payload = ClientTerminalId()
            payload.terminalID = id
            var terminals = ClientTerminalsCommand()
            terminals.scope = IOSCoreStore.terminalsScope
            terminals.close = payload
            var command = ClientCommand()
            command.terminals = terminals
            do { _ = try await core.dispatch(command) } catch { terminalLocalError = message(error) }
        }

        func resizeTerminal(columns: Int, rows: Int) async {
            var payload = ClientTerminalGrid()
            payload.columns = Int32(columns)
            payload.rows = Int32(rows)
            var terminals = ClientTerminalsCommand()
            terminals.scope = IOSCoreStore.terminalsScope
            terminals.grid = payload
            var command = ClientCommand()
            command.terminals = terminals
            do { _ = try await core.dispatch(command) } catch { terminalLocalError = message(error) }
        }

        func sendTerminalInput(_ data: Data) {
            guard !data.isEmpty else { return }
            Task {
                var payload = ClientTerminalInput()
                payload.data = data
                var terminals = ClientTerminalsCommand()
                terminals.scope = IOSCoreStore.terminalsScope
                terminals.input = payload
                var command = ClientCommand()
                command.terminals = terminals
                do { _ = try await core.dispatch(command) } catch { terminalLocalError = message(error) }
            }
        }

        func clearTerminalError() { terminalLocalError = nil }

        private func activeGatewayEndpoint() -> DieterEndpoint? {
            DieterEndpoint.parse(core.session.gatewayOrigin.isEmpty ? gatewayAddress : core.session.gatewayOrigin)
        }

        private func message(_ error: Error) -> String {
            if let failure = error as? IOSCoreFailure { return failure.message }
            return IOSUserError.message(error)
        }
    }
#endif
