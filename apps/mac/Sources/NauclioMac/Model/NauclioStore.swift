import AppKit
import NauclioAPI
import Foundation
import GRPCCore
import Observation
import UniformTypeIdentifiers
import UserNotifications

private let nauclioExpectedAPIVersion = "2"

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case board = "Board"
    case chats = "All chats"
    case files = "Files"
    case schedules = "Schedules"
    case archive = "Archive"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .board: "rectangle.split.3x1"
        case .chats: "bubble.left.and.bubble.right"
        case .files: "doc.on.doc"
        case .schedules: "calendar.badge.clock"
        case .archive: "archivebox"
        case .settings: "gearshape"
        }
    }
}

private struct MachineSnapshot {
    let endpoint: NauclioEndpoint
    let connection: MachineConnectionStatus
    let projects: [Nauclio_V1_Project]
    let boards: [Nauclio_V1_Board]
    let cards: [Nauclio_V1_Card]
    let chats: [Nauclio_V1_Card]
}

private struct DataPlaneConnection {
    let rpc: NauclioRPC
    let task: Task<Void, Never>
    let connection: MachineConnectionStatus
}

private enum NauclioStoreConnectionError: LocalizedError {
    case incompatible(found: String)
    case syncEnded

    var errorDescription: String? {
        switch self {
        case let .incompatible(found):
            "Nauclio API \(found.isEmpty ? "unknown" : found) is incompatible; macOS requires \(nauclioExpectedAPIVersion)."
        case .syncEnded:
            "Live updates stopped unexpectedly."
        }
    }
}

enum SyncStreamLiveness {
    static let timeout: TimeInterval = 45

    static func shouldRestart(lastFrameAt: Date?, now: Date = Date()) -> Bool {
        guard let lastFrameAt else { return true }
        return now.timeIntervalSince(lastFrameAt) >= timeout
    }
}

enum MachineConnectionRoute: String, Sendable {
    case local = "Local"
    case gateway = "Gateway"
}

struct MachineConnectionStatus: Equatable, Sendable {
    let route: MachineConnectionRoute
    let latencyMilliseconds: Int
}

enum MachineRoutingPolicy {
    static func automaticConnectionTarget(
        from machines: [NauclioEndpoint],
        preferredDaemonID: String?
    ) -> NauclioEndpoint? {
        machines.first { $0.daemonID == preferredDaemonID && $0.online }
            ?? machines.filter(\.online).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }.first
    }
}

struct OptimisticCardMove: Equatable, Sendable {
    let operationID: UUID
    var lane: String
    var position: Int64
    var confirmsPosition: Bool

    func isConfirmed(by card: Nauclio_V1_Card) -> Bool {
        card.lane == lane && (!confirmsPosition || card.position == position)
    }

    func applying(to card: Nauclio_V1_Card) -> Nauclio_V1_Card {
        var card = card
        card.lane = lane
        card.position = position
        return card
    }
}

struct OptimisticCardLabels: Equatable, Sendable {
    let operationID: UUID
    let labelIDs: [String]

    func isConfirmed(by card: Nauclio_V1_Card) -> Bool {
        card.labelIds == labelIDs
    }

    func applying(to card: Nauclio_V1_Card) -> Nauclio_V1_Card {
        var card = card
        card.labelIds = labelIDs
        return card
    }
}

struct OptimisticCardProjection {
    let cards: [Nauclio_V1_Card]
    let moves: [String: OptimisticCardMove]
    let labels: [String: OptimisticCardLabels]

    static func reconcile(
        cards: [Nauclio_V1_Card],
        moves: [String: OptimisticCardMove],
        labels: [String: OptimisticCardLabels]
    ) -> OptimisticCardProjection {
        var remainingMoves = moves
        var remainingLabels = labels
        let projected = cards.map { serverCard in
            var card = serverCard
            if let move = moves[card.id] {
                if move.isConfirmed(by: serverCard) { remainingMoves.removeValue(forKey: card.id) }
                else { card = move.applying(to: card) }
            }
            if let labelUpdate = labels[card.id] {
                if labelUpdate.isConfirmed(by: serverCard) { remainingLabels.removeValue(forKey: card.id) }
                else { card = labelUpdate.applying(to: card) }
            }
            return card
        }
        return .init(cards: projected, moves: remainingMoves, labels: remainingLabels)
    }
}

struct OptimisticWorkspaceProjection {
    static func reconcileBoards(
        _ serverBoards: [Nauclio_V1_Board],
        pending: [String: Nauclio_V1_Board]
    ) -> (boards: [Nauclio_V1_Board], pending: [String: Nauclio_V1_Board]) {
        var remaining = pending
        let boards = serverBoards.map { serverBoard in
            guard let expected = pending[serverBoard.id] else { return serverBoard }
            if serverBoard == expected {
                remaining.removeValue(forKey: serverBoard.id)
                return serverBoard
            }
            return expected
        }
        return (boards, remaining)
    }

    static func reconcileProjects(
        _ serverProjects: [Nauclio_V1_Project],
        pending: [String: Nauclio_V1_Project]
    ) -> (projects: [Nauclio_V1_Project], pending: [String: Nauclio_V1_Project]) {
        var remaining = pending
        let projects = serverProjects.map { serverProject in
            guard let expected = pending[serverProject.id] else { return serverProject }
            if serverProject == expected {
                remaining.removeValue(forKey: serverProject.id)
                return serverProject
            }
            return expected
        }
        return (projects, remaining)
    }
}

@MainActor
@Observable
final class NauclioStore {
    var section: AppSection = .board
    var phase: ConnectionPhase = .disconnected
    var endpoint: NauclioEndpoint
    var endpoints: [NauclioEndpoint]
    var health = Nauclio_V1_HealthResponse()
    var runtime = Nauclio_V1_RuntimeStatus()
    var state = Nauclio_V1_State()
    var harnessCatalog = Nauclio_V1_HarnessCatalog()
    var boardSettings = Nauclio_V1_Settings()
    var settingsOptions = Nauclio_V1_SettingsOptions()
    var chats: [Nauclio_V1_Card] = []
    var chatProjects: [Nauclio_V1_Project] = []
    var navigationBoards: [String: [Nauclio_V1_Board]] = [:]
    var navigationCards: [String: [Nauclio_V1_Card]] = [:]
    var projectDirectory: [String: Nauclio_V1_Project] = [:]
    var projectEndpointIDs: [String: String] = [:]
    var machineConnectionStatuses: [String: MachineConnectionStatus] = [:]
    var archivedProjects: [Nauclio_V1_Project] = []
    var archivedCards: [Nauclio_V1_Card] = []

    var selectedProjectID = ""
    var selectedBoardID = ""
    var selectedCardID: String?
    var selectedChatID: String?
    var conversation: Nauclio_V1_ConversationSnapshot?
    var selectedDetail: Nauclio_V1_CardDetail?
    var conversationLoading = false
    var composerText = ""
    var composerAttachments: [Nauclio_V1_MessagePart] = []
    var composerProvider = ""
    var composerModel = ""
    var composerEffort = ""
    var composerProviderOptions: [String: String] = [:]
    var showReasoning = true
    var commentText = ""
    var query = ""
    var runtimeFilter = ""
    var labelFilter = ""
    var movingCardIDs: Set<String> = []
    var labelUpdatingCardIDs: Set<String> = []
    private(set) var pendingCardIDs: Set<String> = []
    private(set) var pendingMessageIDs: Set<String> = []
    private(set) var acceptedOutboxIDs: Set<String> = []
    private(set) var failedOutboxIDs: Set<String> = []

    var files: [Nauclio_V1_FileEntry] = []
    var filePath = ""
    var fileDocument: Nauclio_V1_FileDocument?
    var fileEditorText = ""
    var showHiddenFiles = false

    var schedules: [Nauclio_V1_Schedule] = []
    var scheduleRuns: [Nauclio_V1_ScheduleRun] = []
    var selectedScheduleID: String?
    var newChatProjectID = ""

    var commandPalettePresented = false
    var createConversationPresented = false
    var createProjectPresented = false
    var createBoardPresented = false
    var renameBoardPresented = false
    var renameBoardTargetID = ""
    var projectContextPresented = false
    var labelsPresented = false
    var archivePolicyPresented = false
    var errorMessage: String?

    private(set) var rpc: NauclioRPC?
    private var connectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var directRefreshTask: Task<Void, Never>?
    private var machineDirectoryTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var pendingCardMoves: [String: OptimisticCardMove] = [:]
    private var pendingCardLabelUpdates: [String: OptimisticCardLabels] = [:]
    private var pendingBoards: [String: Nauclio_V1_Board] = [:]
    private var pendingProjects: [String: Nauclio_V1_Project] = [:]
    private var notificationStatuses: [String: String] = [:]
    private var lastSyncFrameAt: Date?
    private var persistConnectionSelection = true
    private var gatewayOrigins: [NauclioEndpoint]
    private var readChatActivity: [String: String]
    private let authentication = NauclioAuthentication()
    private let syncPersistence = NauclioSyncPersistence()
    private let syncClientID = NauclioSyncPersistence.installationID()
    private var syncDiskState = NauclioSyncDiskState.empty
    private var syncProjection = NauclioSyncProjection.empty

    init() {
        readChatActivity = UserDefaults.standard.dictionary(forKey: "NauclioReadChatActivity") as? [String: String] ?? [:]
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--nauclio-endpoint"), arguments.indices.contains(flag + 1),
           let override = NauclioEndpoint.parse(arguments[flag + 1], name: "Command line") {
            endpoints = [override]
            endpoint = override
            gatewayOrigins = [override]
            persistConnectionSelection = false
            Task { [weak self] in await self?.restorePersistentSync() }
            return
        }

        let defaults = UserDefaults.standard
        let storedEndpoints = defaults.data(forKey: "NauclioEndpoints")
            .flatMap { try? JSONDecoder().decode([NauclioEndpoint].self, from: $0) }
        let secureEndpoints = storedEndpoints?.filter { $0.secure && $0.daemonID == nil } ?? []
        let loadedEndpoints = secureEndpoints.isEmpty ? NauclioEndpoint.defaults : secureEndpoints
        endpoints = loadedEndpoints
        gatewayOrigins = loadedEndpoints
        if let data = defaults.data(forKey: "NauclioActiveEndpoint"),
           let decoded = try? JSONDecoder().decode(NauclioEndpoint.self, from: data), decoded.secure {
            endpoint = decoded
        } else {
            endpoint = loadedEndpoints[0]
        }
        if loadedEndpoints != storedEndpoints { persistEndpoints() }
        Task { [weak self] in await self?.restorePersistentSync() }
    }

    var selectedProject: Nauclio_V1_Project? {
        if let project = projectDirectory[selectedProjectID] { return project }
        if let project = state.projects.first(where: { $0.id == selectedProjectID }) { return project }
        return state.project.id == selectedProjectID ? state.project : nil
    }

    var projects: [Nauclio_V1_Project] {
        let values = projectDirectory.isEmpty ? state.projects : Array(projectDirectory.values)
        return values.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame { return $0.id < $1.id }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var machines: [NauclioEndpoint] {
        endpoints.filter { $0.daemonID != nil }.sorted {
            if $0.online != $1.online { return $0.online && !$1.online }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var gateways: [NauclioEndpoint] {
        gatewayOrigins.sorted {
            let lhsPrimary = $0.credentialID == NauclioEndpoint.defaults.first?.credentialID
            let rhsPrimary = $1.credentialID == NauclioEndpoint.defaults.first?.credentialID
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var activeGateway: NauclioEndpoint {
        gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) ?? endpoint.gatewayEndpoint
    }

    var hasLoadedWorkspace: Bool {
        !health.version.isEmpty || !state.projects.isEmpty || !projectDirectory.isEmpty
    }

    func isChatUnread(_ card: Nauclio_V1_Card) -> Bool {
        guard selectedChatID != card.id else { return false }
        let activity = card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt
        guard !activity.isEmpty else { return false }
        guard let read = readChatActivity[card.id] else { return true }
        if let activityDate = Self.parseTimestamp(activity), let readDate = Self.parseTimestamp(read) {
            return activityDate > readDate
        }
        return activity > read
    }

    func isPendingCard(_ id: String) -> Bool { pendingCardIDs.contains(id) }
    func isPendingMessage(_ id: String) -> Bool { pendingMessageIDs.contains(id) }
    func isAcceptedOutboxItem(_ id: String) -> Bool { acceptedOutboxIDs.contains(id) }
    func isFailedOutboxItem(_ id: String) -> Bool { failedOutboxIDs.contains(id) }

    func machine(forProjectID projectID: String) -> NauclioEndpoint? {
        guard let endpointID = projectEndpointIDs[projectID] else { return nil }
        return endpoints.first { $0.id == endpointID }
    }

    func connectionStatus(for machine: NauclioEndpoint) -> MachineConnectionStatus? {
        machineConnectionStatuses[machine.id]
    }

    var selectedBoard: Nauclio_V1_Board? {
        state.boards.first { $0.id == selectedBoardID }
    }

    var renameBoardTarget: Nauclio_V1_Board? {
        board(id: renameBoardTargetID)
    }

    var selectedCard: Nauclio_V1_Card? {
        let id = selectedCardID ?? selectedChatID
        return state.cards.first { $0.id == id } ?? state.chats.first { $0.id == id } ?? chats.first { $0.id == id }
    }

    var selectedSchedule: Nauclio_V1_Schedule? {
        guard let selectedScheduleID else { return nil }
        return schedules.first { $0.id == selectedScheduleID }
    }

    var displayedCards: [Nauclio_V1_Card] {
        boardCards.filter { card in
            (runtimeFilter.isEmpty || card.runtime == runtimeFilter) &&
            (labelFilter.isEmpty || card.labelIds.contains(labelFilter)) &&
            (query.isEmpty || card.title.localizedCaseInsensitiveContains(query) || card.summary.localizedCaseInsensitiveContains(query))
        }
    }

    var boardCards: [Nauclio_V1_Card] {
        state.cards.filter { selectedBoardID.isEmpty || $0.boardID == selectedBoardID }
    }

    func boards(for projectID: String) -> [Nauclio_V1_Board] {
        navigationBoards[projectID] ?? (projectID == state.project.id ? state.boards : [])
    }

    func board(id: String) -> Nauclio_V1_Board? {
        guard !id.isEmpty else { return nil }
        if let board = state.boards.first(where: { $0.id == id }) { return board }
        return navigationBoards.values.lazy.compactMap { boards in
            boards.first(where: { $0.id == id })
        }.first
    }

    func connect(to newEndpoint: NauclioEndpoint? = nil, automatic: Bool = false) async {
        if !automatic { reconnectTask?.cancel(); reconnectTask = nil }
        let requested = newEndpoint ?? endpoint
        let preferredDaemonID = requested.daemonID ?? (requested.credentialID == endpoint.credentialID ? endpoint.daemonID : nil)
        let origin = gatewayOrigins.first(where: { $0.credentialID == requested.credentialID }) ?? requested.gatewayEndpoint
        connectionGeneration &+= 1
        let generation = connectionGeneration
        phase = .connecting
        stateTask?.cancel(); conversationTask?.cancel(); syncTask?.cancel(); outboxTask?.cancel(); connectionTask?.cancel(); directRefreshTask?.cancel(); machineDirectoryTask?.cancel()
        rpc?.shutdown()
        rpc = nil
        connectionTask = nil
        var gatewayRPC: NauclioRPC?
        var gatewayTask: Task<Void, Never>?
        var gatewayAuthenticated = false
        do {
            let accessToken = await NauclioCredentialStore.token(for: origin)
            let control = try NauclioRPC(endpoint: origin, accessToken: accessToken)
            gatewayRPC = control
            gatewayTask = Task { try? await control.run() }
            let daemonDirectory = try await control.daemons()
            guard generation == connectionGeneration else {
                gatewayTask?.cancel()
                control.shutdown()
                return
            }
            gatewayAuthenticated = true
            let discovered = daemonDirectory.daemons.map {
                NauclioEndpoint(
                    name: $0.name.isEmpty ? $0.id : $0.name,
                    host: origin.host,
                    port: origin.port,
                    secure: origin.secure,
                    daemonID: $0.id,
                    online: $0.online,
                    lastSeenAt: $0.lastSeenAt,
                    version: $0.version
                )
            }
            guard !discovered.isEmpty else {
                throw NSError(domain: "NauclioGateway", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Nauclio daemons are enrolled for this account."])
            }
            endpoints = discovered
            let target = MachineRoutingPolicy.automaticConnectionTarget(
                from: discovered,
                preferredDaemonID: preferredDaemonID
            )
            guard let target else {
                throw NSError(domain: "NauclioGateway", code: 3, userInfo: [NSLocalizedDescriptionKey: "No enrolled Nauclio machines are online."])
            }

            let dataPlane = try await selectDataPlane(
                gateway: control,
                target: target,
                gatewayAccessToken: accessToken
            )
            guard generation == connectionGeneration else {
                dataPlane.task.cancel()
                dataPlane.rpc.shutdown()
                gatewayTask?.cancel()
                control.shutdown()
                return
            }
            gatewayTask?.cancel()
            control.shutdown()
            gatewayTask = nil
            gatewayRPC = nil

            rpc = dataPlane.rpc
            connectionTask = dataPlane.task
            machineConnectionStatuses[target.id] = dataPlane.connection
            endpoint = target
            activateSyncProjection(for: target)
            persistEndpoints()
            // Do not use `async let` in this throwing `do` scope. Swift 6.1–6.3 can
            // destroy failed child tasks out of allocation order (Swift #81771),
            // aborting the process while a gRPC connection is unwinding. Explicit
            // tasks preserve parallel loading without using async-let stack storage.
            let healthTask = Task { try await dataPlane.rpc.health() }
            let runtimeTask = Task { try await dataPlane.rpc.runtimeStatus() }
            let stateTask = Task { try await dataPlane.rpc.state() }
            let harnessesTask = Task { try await dataPlane.rpc.harnesses() }
            let settingsTask = Task { try await dataPlane.rpc.settings() }
            let optionsTask = Task { try await dataPlane.rpc.settingsOptions() }
            defer {
                healthTask.cancel()
                runtimeTask.cancel()
                stateTask.cancel()
                harnessesTask.cancel()
                settingsTask.cancel()
                optionsTask.cancel()
            }
            let initialHealth = try await healthTask.value
            guard initialHealth.status == "ok", initialHealth.version == nauclioExpectedAPIVersion else {
                throw NauclioStoreConnectionError.incompatible(found: initialHealth.version)
            }
            let initialRuntime = try await runtimeTask.value
            let initialState = try await stateTask.value
            let initialHarnesses = try await harnessesTask.value
            let initialSettings = try await settingsTask.value
            let initialOptions = try await optionsTask.value
            self.health = initialHealth
            self.runtime = initialRuntime
            acceptState(initialState)
            self.harnessCatalog = initialHarnesses
            self.boardSettings = initialSettings
            self.settingsOptions = initialOptions
            phase = .connected(version: initialHealth.version)
            startGlobalSync()
            startOutboxWorker()
            await refreshMachineDirectory()
            startMachineDirectoryRefresh()
        } catch {
            gatewayTask?.cancel()
            gatewayRPC?.shutdown()
            connectionTask?.cancel()
            connectionTask = nil
            rpc?.shutdown()
            rpc = nil
            guard generation == connectionGeneration else { return }
            if let connectionError = error as? NauclioStoreConnectionError,
               case let .incompatible(found) = connectionError {
                phase = .incompatible(found: found)
                errorMessage = error.localizedDescription
                return
            }
            if !gatewayAuthenticated, let rpcError = error as? RPCError, rpcError.code == .unauthenticated {
                phase = .authenticationRequired
                errorMessage = nil
                return
            }
            if hasLoadedWorkspace {
                phase = .connecting
                scheduleReconnect(to: requested)
            } else {
                phase = .failed(error.localizedDescription)
                errorMessage = "Could not connect to \(requested.address): \(error.localizedDescription)"
            }
        }
    }

    private func selectDataPlane(
        gateway: NauclioRPC,
        target: NauclioEndpoint,
        gatewayAccessToken: String?
    ) async throws -> DataPlaneConnection {
        guard let daemonID = target.daemonID else {
            throw NSError(domain: "NauclioGateway", code: 5, userInfo: [NSLocalizedDescriptionKey: "No routed Nauclio machine is available."])
        }
        let route = try await gateway.route(daemonID: daemonID)
        if !route.directCandidates.isEmpty {
            let token = try await gateway.daemonAccessToken(daemonID: daemonID)
            guard token.tokenType == "Bearer" else {
                throw NSError(domain: "NauclioGateway", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gateway returned an unsupported daemon token."])
            }
            for candidate in route.directCandidates.sorted(by: { $0.priority > $1.priority }) {
                do {
                    let direct = try NauclioRPC(
                        endpoint: target,
                        direct: .init(
                            host: candidate.host,
                            port: Int(candidate.port),
                            daemonID: daemonID,
                            daemonCAPEM: route.daemonCaPem,
                            accessToken: token.accessToken
                        )
                    )
                    let directTask = startConnectionTask(for: direct)
                    let started = Date()
                    do {
                        _ = try await direct.health(timeout: .seconds(2))
                        scheduleDirectRefresh(expiresAt: token.expiresAt, target: target)
                        return DataPlaneConnection(
                            rpc: direct,
                            task: directTask,
                            connection: .init(route: .local, latencyMilliseconds: Self.latencyMilliseconds(since: started))
                        )
                    } catch {
                        directTask.cancel()
                        direct.shutdown()
                    }
                } catch {
                    continue
                }
            }
        }
        guard route.relayAvailable else {
            throw NSError(domain: "NauclioGateway", code: 3, userInfo: [NSLocalizedDescriptionKey: "This Nauclio daemon is offline."])
        }
        let relay = try NauclioRPC(endpoint: target, accessToken: gatewayAccessToken, route: .relay(daemonID: daemonID))
        let relayTask = startConnectionTask(for: relay)
        do {
            let started = Date()
            _ = try await relay.health(timeout: .seconds(5))
            return DataPlaneConnection(
                rpc: relay,
                task: relayTask,
                connection: .init(route: .gateway, latencyMilliseconds: Self.latencyMilliseconds(since: started))
            )
        } catch {
            relayTask.cancel()
            relay.shutdown()
            throw error
        }
    }

    private func startConnectionTask(for client: NauclioRPC) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await client.run()
                if !Task.isCancelled {
                    self?.connectionStopped(
                        NSError(domain: "NauclioTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Nauclio connection closed."]),
                        client: client
                    )
                }
            }
            catch where Self.isExpectedCancellation(error) { }
            catch { self?.connectionStopped(error, client: client) }
        }
    }

    private func scheduleDirectRefresh(expiresAt: String, target: NauclioEndpoint) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires = formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        guard let expires else { return }
        let delay = max(1, expires.timeIntervalSinceNow - 30)
        directRefreshTask?.cancel()
        directRefreshTask = Task { [weak self] in
            try? await NauclioTaskSleep.seconds(delay)
            guard !Task.isCancelled, let self else { return }
            // Do not let connect(to:) cancel the task that is currently
            // performing the scheduled token refresh.
            self.directRefreshTask = nil
            await self.connect(to: target, automatic: true)
        }
    }

    func signIn() async {
        do {
            let origin = gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) ?? endpoint.gatewayEndpoint
            _ = try await authentication.signIn(to: origin)
            await connect(to: endpoint)
        } catch {
            errorMessage = "Could not sign in: \(error.localizedDescription)"
        }
    }

    func completeAuthentication(url: URL) {
        guard !authentication.complete(url: url) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let endpoint = try await self.authentication.resumePending(url: url) else { return }
                await self.connect(to: endpoint)
            } catch {
                self.errorMessage = "Could not finish sign-in: \(error.localizedDescription)"
            }
        }
    }

    func signOut() async {
        await NauclioCredentialStore.remove(for: endpoint)
        disconnect()
        phase = endpoint.secure ? .authenticationRequired : .disconnected
    }

    private func connectionStopped(_ error: Error, client: NauclioRPC) {
        guard !Task.isCancelled else { return }
        guard rpc === client else { return }
        guard hasLoadedWorkspace else {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .connecting
        scheduleReconnect(to: endpoint)
    }

    private func scheduleReconnect(to target: NauclioEndpoint) {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled, let self {
                try? await NauclioTaskSleep.seconds(delay)
                guard !Task.isCancelled else { return }
                await self.connect(to: target, automatic: true)
                if self.phase.isConnected {
                    self.reconnectTask = nil
                    return
                }
                delay = min(15, delay * 1.8)
            }
        }
    }

    func disconnect() {
        connectionGeneration &+= 1
        stateTask?.cancel(); conversationTask?.cancel(); syncTask?.cancel(); outboxTask?.cancel(); connectionTask?.cancel(); directRefreshTask?.cancel(); machineDirectoryTask?.cancel(); reconnectTask?.cancel()
        reconnectTask = nil
        rpc?.shutdown(); rpc = nil
        lastSyncFrameAt = nil
        phase = .disconnected
    }

    func chooseGateway(_ gateway: NauclioEndpoint) async {
        guard gateway.daemonID == nil else { return }
        if !gatewayOrigins.contains(where: { $0.credentialID == gateway.credentialID }) {
            gatewayOrigins.append(gateway)
        }
        if gateway.credentialID != activeGateway.credentialID {
            clearDeploymentWorkspace()
        }
        endpoint = gateway
        await connect(to: gateway)
    }

    func saveEndpoint(_ endpoint: NauclioEndpoint) async {
        if let index = gatewayOrigins.firstIndex(where: { $0.credentialID == endpoint.credentialID || $0.name == endpoint.name }) {
            gatewayOrigins[index] = endpoint
        } else {
            gatewayOrigins.append(endpoint)
        }
        if endpoint.credentialID != activeGateway.credentialID {
            clearDeploymentWorkspace()
        }
        persistEndpoints()
        await connect(to: endpoint)
    }

    private func clearDeploymentWorkspace() {
        state = Nauclio_V1_State()
        projectDirectory.removeAll()
        projectEndpointIDs.removeAll()
        navigationBoards.removeAll()
        navigationCards.removeAll()
        chats.removeAll()
        chatProjects.removeAll()
        schedules.removeAll()
        scheduleRuns.removeAll()
        selectedProjectID = ""
        selectedBoardID = ""
        closeConversation()
        syncProjection = .empty
    }

    func deleteEndpoint(_ endpoint: NauclioEndpoint) {
        guard endpoint.daemonID == nil, gatewayOrigins.count > 1 else { return }
        gatewayOrigins.removeAll { $0.credentialID == endpoint.credentialID }
        persistEndpoints()
    }

    func revokeDaemon(_ endpoint: NauclioEndpoint) async {
        guard let daemonID = endpoint.daemonID, let rpc else { return }
        do {
            try await rpc.revokeDaemon(daemonID: daemonID)
            endpoints.removeAll { $0.daemonID == daemonID }
            projectEndpointIDs = projectEndpointIDs.filter { $0.value != endpoint.id }
            projectDirectory = projectDirectory.filter { projectEndpointIDs[$0.key] != nil }
            persistEndpoints()
            await connect(to: endpoints.first(where: \.online) ?? gatewayOrigins[0])
        } catch { show(error) }
    }

    func renameMachine(_ endpoint: NauclioEndpoint, name: String) async {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let daemonID = endpoint.daemonID, !normalized.isEmpty else { return }
        let origin = gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) ?? endpoint.gatewayEndpoint
        do {
            let client = try NauclioRPC(endpoint: origin, accessToken: await NauclioCredentialStore.token(for: origin))
            let runner = Task { try? await client.run() }
            defer { runner.cancel(); client.shutdown() }
            _ = try await client.renameDaemon(daemonID: daemonID, name: normalized)
            await refreshDaemonPresence()
            persistEndpoints()
        } catch { show(error) }
    }

    private func persistEndpoints() {
        guard persistConnectionSelection else { return }
        if let data = try? JSONEncoder().encode(gatewayOrigins) { UserDefaults.standard.set(data, forKey: "NauclioEndpoints") }
        if let data = try? JSONEncoder().encode(endpoint) { UserDefaults.standard.set(data, forKey: "NauclioActiveEndpoint") }
    }

    @discardableResult
    private func ensureProjectConnection(_ projectID: String) async -> Bool {
        guard let target = machine(forProjectID: projectID) else { return true }
        guard target.online else {
            errorMessage = "\(target.name) is offline. Start Nauclio on that machine to open this project."
            return false
        }
        guard target.id != endpoint.id else { return true }
        selectedProjectID = projectID
        await connect(to: target)
        return phase.isConnected && endpoint.id == target.id
    }

    func refreshMachineDirectory(includeArchivedChats: Bool = false) async {
        // The active machine is owned by WatchSync. Polling it here used to
        // replace the live snapshot while retaining its cursor, so later
        // deltas could be reduced against state from a different point in time.
        let onlineMachines = machines.filter { $0.online && $0.id != endpoint.id }
        guard !onlineMachines.isEmpty else { return }

        var snapshots: [MachineSnapshot] = []
        for machine in onlineMachines {
            do {
                snapshots.append(try await loadMachine(machine, includeArchivedChats: includeArchivedChats))
            } catch {
                // Presence is authoritative and refreshed on the next gateway
                // connection. One unreachable host must not hide other hosts.
                continue
            }
        }
        guard !snapshots.isEmpty else { return }

        let refreshedEndpointIDs = Set(snapshots.map(\.endpoint.id))
        var nextProjects = projectDirectory.filter { projectEndpointIDs[$0.key].map { !refreshedEndpointIDs.contains($0) } ?? false }
        var nextProjectEndpoints = projectEndpointIDs.filter { !refreshedEndpointIDs.contains($0.value) }
        var nextBoards = navigationBoards.filter { projectID, _ in nextProjectEndpoints[projectID] != nil }
        var nextCards = navigationCards.filter { projectID, _ in nextProjectEndpoints[projectID] != nil }
        var nextChats = chats.filter { chat in nextProjectEndpoints[chat.projectID] != nil }

        for snapshot in snapshots {
            machineConnectionStatuses[snapshot.endpoint.id] = snapshot.connection
            persistInactiveMachineSnapshot(snapshot)
            for project in snapshot.projects {
                nextProjects[project.id] = project
                nextProjectEndpoints[project.id] = snapshot.endpoint.id
            }
            for project in snapshot.projects {
                nextBoards[project.id] = snapshot.boards.filter { $0.projectID == project.id }
                nextCards[project.id] = snapshot.cards.filter { $0.projectID == project.id }
            }
            nextChats.append(contentsOf: snapshot.chats)
        }
        projectDirectory = nextProjects
        projectEndpointIDs = nextProjectEndpoints
        navigationBoards = nextBoards
        navigationCards = nextCards
        chatProjects = projects
        chats = nextChats
            .filter { $0.scope == "chat" && $0.boardID.isEmpty }
            .reduce(into: [String: Nauclio_V1_Card]()) { $0[$1.id] = $1 }
            .values
            .sorted { ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt) > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt) }
        updateSelectedState()
        if let selectedChatID, let selected = chats.first(where: { $0.id == selectedChatID }) {
            markChatRead(selected)
        }
        try? await syncPersistence.save(syncDiskState)
    }

    private func persistInactiveMachineSnapshot(_ machine: MachineSnapshot) {
        guard machine.endpoint.id != endpoint.id else { return }
        syncDiskState.projections[machine.endpoint.id] = NauclioSyncProjectionCache.replacingMetadata(
            in: syncDiskState.projections[machine.endpoint.id] ?? .empty,
            projects: machine.projects,
            boards: machine.boards,
            cards: machine.cards,
            chats: machine.chats
        )
    }

    private func startMachineDirectoryRefresh() {
        machineDirectoryTask?.cancel()
        machineDirectoryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await NauclioTaskSleep.seconds(15)
                guard !Task.isCancelled, let self else { return }
                await self.refreshDaemonPresence()
                await self.refreshMachineDirectory()
                if SyncStreamLiveness.shouldRestart(lastFrameAt: self.lastSyncFrameAt) {
                    self.startGlobalSync()
                }
            }
        }
    }

    private func refreshDaemonPresence() async {
        guard let origin = gatewayOrigins.first(where: { $0.credentialID == endpoint.credentialID }) else { return }
        do {
            let client = try NauclioRPC(endpoint: origin, accessToken: await NauclioCredentialStore.token(for: origin))
            let runner = Task { try? await client.run() }
            defer { runner.cancel(); client.shutdown() }
            let directory = try await client.daemons()
            let previous = Dictionary(uniqueKeysWithValues: endpoints.compactMap { item in item.daemonID.map { ($0, item) } })
            endpoints = directory.daemons.map { daemon in
                var item = previous[daemon.id] ?? NauclioEndpoint(
                    name: daemon.name.isEmpty ? daemon.id : daemon.name,
                    host: origin.host,
                    port: origin.port,
                    secure: origin.secure,
                    daemonID: daemon.id
                )
                item.name = daemon.name.isEmpty ? daemon.id : daemon.name
                item.online = daemon.online
                item.lastSeenAt = daemon.lastSeenAt
                item.version = daemon.version
                return item
            }
            if let refreshedActive = endpoints.first(where: { $0.id == endpoint.id }) {
                endpoint = refreshedActive
            }
        } catch {
            // Keep the last known directory during a transient gateway loss.
        }
    }

    private func loadMachine(_ machine: NauclioEndpoint, includeArchivedChats: Bool) async throws -> MachineSnapshot {
        let client: NauclioRPC
        let ownsClient: Bool
        var runner: Task<Void, Never>?
        if machine.id == endpoint.id, let rpc {
            client = rpc
            ownsClient = false
        } else {
            guard let daemonID = machine.daemonID else {
                throw NSError(domain: "NauclioGateway", code: 5, userInfo: [NSLocalizedDescriptionKey: "Machine endpoint is missing its daemon identity."])
            }
            client = try NauclioRPC(
                endpoint: machine,
                accessToken: await NauclioCredentialStore.token(for: machine),
                route: .relay(daemonID: daemonID)
            )
            ownsClient = true
            runner = Task { try? await client.run() }
        }
        defer {
            if ownsClient { client.shutdown() }
            runner?.cancel()
        }

        let started = Date()
        let root = try await client.state()
        let connection = MachineConnectionStatus(
            route: machineConnectionStatuses[machine.id]?.route ?? (ownsClient ? .gateway : .local),
            latencyMilliseconds: Self.latencyMilliseconds(since: started)
        )
        let projects = root.projects.filter { !$0.archived }
        var boards: [Nauclio_V1_Board] = []
        var cards: [Nauclio_V1_Card] = []
        for project in projects {
            var request = Nauclio_V1_GetStateRequest()
            request.projectID = project.id
            request.limit = 500
            let snapshot = try await client.state(request)
            boards.append(contentsOf: snapshot.boards)
            cards.append(contentsOf: snapshot.cards)
        }
        let chatResponse = try await client.chats(includeArchived: includeArchivedChats)
        return MachineSnapshot(
            endpoint: machine,
            connection: connection,
            projects: projects,
            boards: Array(boards.reduce(into: [String: Nauclio_V1_Board]()) { $0[$1.id] = $1 }.values),
            cards: Array(cards.reduce(into: [String: Nauclio_V1_Card]()) { $0[$1.id] = $1 }.values),
            chats: chatResponse.chats
        )
    }

    private nonisolated static func latencyMilliseconds(since started: Date) -> Int {
        max(1, Int((Date().timeIntervalSince(started) * 1_000).rounded()))
    }

    private nonisolated static func parseTimestamp(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func selectProject(_ id: String) async {
        guard await ensureProjectConnection(id) else { return }
        selectedProjectID = id
        selectedBoardID = boards(for: id).first?.id ?? ""
        filePath = ""; fileDocument = nil
        await refreshState()
        if section == .files { await loadFiles() }
        if section == .schedules { await loadSchedules() }
    }

    func selectBoard(_ id: String) async {
        selectedBoardID = id
        await refreshState()
    }

    func openBoard(_ boardID: String, projectID: String) async {
        guard await ensureProjectConnection(projectID) else { return }
        closeConversation()
        section = .board
        selectedProjectID = projectID
        selectedBoardID = boardID
        filePath = ""; fileDocument = nil
        query = ""; runtimeFilter = ""; labelFilter = ""
        await refreshState()
    }

    func openProject(_ projectID: String, section destination: AppSection) async {
        guard await ensureProjectConnection(projectID) else { return }
        closeConversation()
        section = destination
        selectedProjectID = projectID
        if selectedBoardID.isEmpty || boards(for: projectID).contains(where: { $0.id == selectedBoardID }) == false {
            selectedBoardID = boards(for: projectID).first?.id ?? ""
        }
        filePath = ""; fileDocument = nil
        await refreshState()
        if destination == .files { await loadFiles() }
        if destination == .schedules { await loadSchedules() }
    }

    func openChats() async {
        closeConversation()
        section = .chats
        await refreshChats()
    }

    func beginStandaloneChat(projectID: String? = nil) {
        closeConversation()
        section = .chats
        newChatProjectID = projectID ?? selectedProjectID
    }

    func openSettings() {
        closeConversation()
        section = .settings
    }

    func presentNewBoard(projectID: String) {
        Task {
            guard await ensureProjectConnection(projectID) else { return }
            selectedProjectID = projectID
            selectedBoardID = boards(for: projectID).first?.id ?? ""
            createBoardPresented = true
        }
    }

    func presentRenameBoard(boardID: String) {
        guard let target = board(id: boardID) else { return }
        Task {
            guard await ensureProjectConnection(target.projectID) else { return }
            renameBoardTargetID = boardID
            renameBoardPresented = true
        }
    }

    private func restorePersistentSync() async {
        let restored = await syncPersistence.load()
        syncDiskState = restored
        let activePrefix = activeGateway.credentialID + "#"
        let deploymentProjections = restored.projections
            .filter { $0.key.hasPrefix(activePrefix) }
            .sorted { $0.key < $1.key }
        for (endpointID, projection) in deploymentProjections {
            if let raw = projection.snapshot,
               let snapshot = try? Nauclio_V1_GlobalSnapshot(serializedBytes: raw) {
                applyGlobalSnapshot(snapshot, endpointID: endpointID)
            }
        }
        if deploymentProjections.isEmpty,
           let raw = restored.snapshot,
           let snapshot = try? Nauclio_V1_GlobalSnapshot(serializedBytes: raw) {
            applyGlobalSnapshot(snapshot, endpointID: endpoint.id)
        }
        rebuildOutboxOverlays()
    }

    private func activateSyncProjection(for endpoint: NauclioEndpoint) {
        if let persisted = syncDiskState.projections[endpoint.id] {
            syncProjection = persisted
        } else {
            syncProjection = NauclioSyncProjection(cursor: syncDiskState.cursor, snapshot: syncDiskState.snapshot)
            syncDiskState.projections[endpoint.id] = syncProjection
            syncDiskState.cursor = nil
            syncDiskState.snapshot = nil
        }
        if let daemonID = endpoint.daemonID {
            for index in syncDiskState.outbox.indices where syncDiskState.outbox[index].endpointID == daemonID {
                syncDiskState.outbox[index].endpointID = endpoint.id
            }
        }
        if let raw = syncProjection.snapshot,
           let snapshot = try? Nauclio_V1_GlobalSnapshot(serializedBytes: raw) {
            applyGlobalSnapshot(snapshot, endpointID: endpoint.id)
        } else {
            updateSelectedState()
        }
    }

    private func persistActiveProjection(endpointID: String) {
        guard endpoint.id == endpointID else { return }
        syncDiskState.projections[endpointID] = syncProjection
    }

    private func startGlobalSync() {
        syncTask?.cancel()
        guard let rpc else { return }
        lastSyncFrameAt = Date()
        let endpointID = endpoint.id
        var request = Nauclio_V1_SyncRequest()
        request.conversationLimit = 0
        request.heartbeatMs = 15_000
        if syncProjection.snapshot != nil,
           let raw = syncProjection.cursor, let cursor = try? Nauclio_V1_SyncCursor(serializedBytes: raw) {
            request.after = cursor
        }
        syncTask = Task { [weak self] in
            do {
                try await rpc.watchSync(request) { [weak self] frame in
                    await self?.applySyncFrame(frame, endpointID: endpointID)
                }
                guard !Task.isCancelled else { return }
                self?.connectionStopped(NauclioStoreConnectionError.syncEnded, client: rpc)
            } catch where Self.isExpectedCancellation(error) { }
            catch { self?.connectionStopped(error, client: rpc) }
        }
    }

    private func applySyncFrame(_ frame: Nauclio_V1_SyncFrame, endpointID: String) async {
        guard endpoint.id == endpointID else { return }
        lastSyncFrameAt = Date()
        if frame.hasSnapshot {
            syncProjection.snapshot = try? frame.snapshot.serializedData()
            applyGlobalSnapshot(frame.snapshot, endpointID: endpointID)
        } else if frame.hasDelta,
                  let raw = syncProjection.snapshot,
                  let current = try? Nauclio_V1_GlobalSnapshot(serializedBytes: raw) {
            let next = GlobalProjectionReducer.applying(frame.delta, to: current)
            syncProjection.snapshot = try? next.serializedData()
            applyGlobalSnapshot(next, endpointID: endpointID)
        }
        if frame.hasCursor {
            syncProjection.cursor = try? frame.cursor.serializedData()
        }
        persistActiveProjection(endpointID: endpointID)
        reconcileOutboxWithProjection()
        try? await syncPersistence.save(syncDiskState)
    }

    private func applyGlobalSnapshot(_ snapshot: Nauclio_V1_GlobalSnapshot, endpointID: String) {
        var global = snapshot.state
        let boardProjection = OptimisticWorkspaceProjection.reconcileBoards(global.boards, pending: pendingBoards)
        global.boards = boardProjection.boards
        pendingBoards = boardProjection.pending
        let projectProjection = OptimisticWorkspaceProjection.reconcileProjects(global.projects, pending: pendingProjects)
        global.projects = projectProjection.projects
        pendingProjects = projectProjection.pending
        let projection = OptimisticCardProjection.reconcile(
            cards: global.cards,
            moves: pendingCardMoves,
            labels: pendingCardLabelUpdates
        )
        global.cards = projection.cards
        pendingCardMoves = projection.moves
        pendingCardLabelUpdates = projection.labels
        movingCardIDs = Set(projection.moves.keys)
        labelUpdatingCardIDs = Set(projection.labels.keys)
        for card in global.cards + global.chats {
            if let previous = notificationStatuses[card.id], previous != card.runtime,
               ["review", "waiting", "completed", "failed"].contains(card.runtime.lowercased()) {
                notify(title: card.title, body: "Status changed to \(card.runtime)")
            }
            notificationStatuses[card.id] = card.runtime
        }
        let previousProjectIDs = Set(projectEndpointIDs.compactMap { $0.value == endpointID ? $0.key : nil })
        for projectID in previousProjectIDs {
            projectDirectory.removeValue(forKey: projectID)
            projectEndpointIDs.removeValue(forKey: projectID)
            navigationBoards.removeValue(forKey: projectID)
            navigationCards.removeValue(forKey: projectID)
        }
        for project in global.projects {
            projectDirectory[project.id] = project
            projectEndpointIDs[project.id] = endpointID
            navigationBoards[project.id] = global.boards.filter { $0.projectID == project.id }
            navigationCards[project.id] = global.cards.filter { $0.projectID == project.id }
        }
        chats.removeAll { previousProjectIDs.contains($0.projectID) }
        chats.append(contentsOf: global.chats)
        chats = Array(chats.reduce(into: [String: Nauclio_V1_Card]()) { $0[$1.id] = $1 }.values).sorted {
            ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt) > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt)
        }
        chatProjects = projects
        updateSelectedState(base: global)
        if projectEndpointIDs[selectedProjectID] == endpointID {
            schedules = snapshot.schedules.filter { $0.projectID == selectedProjectID }
            if selectedScheduleID == nil || !schedules.contains(where: { $0.id == selectedScheduleID }) {
                selectedScheduleID = schedules.first?.id
            }
            if let selectedScheduleID {
                scheduleRuns = snapshot.scheduleRuns.filter { $0.scheduleID == selectedScheduleID }
            } else {
                scheduleRuns = []
            }
            boardSettings = snapshot.settings
        }
        if let selectedID = selectedCardID ?? selectedChatID,
           let projected = snapshot.conversations.first(where: { $0.detail.card.id == selectedID }) {
            conversation = projected
            selectedDetail = projected.detail
            conversationLoading = false
        }
        rebuildOutboxOverlays()
    }

    private func updateSelectedState(base: Nauclio_V1_State? = nil) {
        if selectedProjectID.isEmpty || projectDirectory[selectedProjectID] == nil {
            selectedProjectID = projects.first?.id ?? ""
        }
        var selected = base ?? state
        selected.projects = projects
        selected.project = projectDirectory[selectedProjectID] ?? Nauclio_V1_Project()
        selected.boards = navigationBoards[selectedProjectID] ?? []
        selected.cards = navigationCards[selectedProjectID] ?? []
        selected.chats = chats.filter { $0.projectID == selectedProjectID }
        state = selected
        if selectedBoardID.isEmpty || !selected.boards.contains(where: { $0.id == selectedBoardID }) {
            selectedBoardID = selected.boards.first?.id ?? ""
        }
    }

    private func projectedConversation(cardID: String) -> Nauclio_V1_ConversationSnapshot? {
        guard let raw = syncProjection.snapshot,
              let snapshot = try? Nauclio_V1_GlobalSnapshot(serializedBytes: raw) else { return nil }
        return snapshot.conversations.first { $0.detail.card.id == cardID }
    }

    private func rebuildOutboxOverlays() {
        pendingCardIDs = Set(syncDiskState.outbox.filter { $0.kind != .sendMessage }.map(\.optimisticID))
        pendingMessageIDs = Set(syncDiskState.outbox.filter { $0.kind == .sendMessage }.map(\.optimisticID))
        acceptedOutboxIDs = Set(syncDiskState.outbox.filter { $0.serverID != nil }.map(\.optimisticID))
        failedOutboxIDs = Set(syncDiskState.outbox.filter { $0.lastError != nil }.map(\.optimisticID))
        for entry in syncDiskState.outbox {
            switch entry.kind {
            case .createCard, .createChat:
                guard let request = try? Nauclio_V1_CreateConversationRequest(serializedBytes: entry.request) else { continue }
                var card = Nauclio_V1_Card()
                card.id = entry.optimisticID
                card.scope = entry.kind == .createChat ? "chat" : "board"
                card.projectID = request.projectID
                card.boardID = entry.kind == .createChat ? "" : request.boardID
                card.lane = request.lane
                card.title = request.title
                card.initialPrompt = request.prompt
                card.provider = request.provider
                card.model = request.model
                card.effort = request.effort
                card.runtime = "pending"
                card.createdAt = ISO8601DateFormatter().string(from: entry.createdAt)
                card.updatedAt = card.createdAt
                if entry.kind == .createChat {
                    if !chats.contains(where: { $0.id == card.id }) { chats.insert(card, at: 0) }
                } else if card.projectID == selectedProjectID, !state.cards.contains(where: { $0.id == card.id }) {
                    state.cards.append(card)
                    navigationCards[card.projectID, default: []].append(card)
                }
            case .sendMessage:
                guard let request = try? Nauclio_V1_SendMessageRequest(serializedBytes: entry.request),
                      (selectedCardID ?? selectedChatID) == request.cardID,
                      var snapshot = conversation,
                      !snapshot.conversation.messages.contains(where: { $0.id == entry.optimisticID }) else { continue }
                var message = Nauclio_V1_UiMessage()
                message.id = entry.optimisticID
                message.role = "user"
                message.parts = request.parts
                snapshot.conversation.messages.append(message)
                conversation = snapshot
            }
        }
    }

    private func reconcileOutboxWithProjection() {
        guard let raw = syncProjection.snapshot,
              let snapshot = try? Nauclio_V1_GlobalSnapshot(serializedBytes: raw) else { return }
        let cardIDs = Set((snapshot.state.cards + snapshot.state.chats).map(\.id))
        syncDiskState.outbox.removeAll { entry in
            guard let serverID = entry.serverID else { return false }
            return entry.kind == .sendMessage || cardIDs.contains(serverID)
        }
        rebuildOutboxOverlays()
    }

    private func persistAndDrainOutbox() async {
        rebuildOutboxOverlays()
        try? await syncPersistence.save(syncDiskState)
        startOutboxWorker()
    }

    private func startOutboxWorker() {
        guard outboxTask?.isCancelled != false else { return }
        outboxTask = Task { [weak self] in
            guard let self else { return }
            defer { self.outboxTask = nil }
            while !Task.isCancelled {
                guard let rpc = self.rpc, self.phase.isConnected else { return }
                guard let index = self.syncDiskState.outbox.firstIndex(where: {
                    $0.endpointID == self.endpoint.id && $0.serverID == nil
                }) else { return }
                var entry = self.syncDiskState.outbox[index]
                do {
                    switch entry.kind {
                    case .createCard:
                        let request = try Nauclio_V1_CreateConversationRequest(serializedBytes: entry.request)
                        entry.serverID = try await rpc.createCard(request).id
                    case .createChat:
                        let request = try Nauclio_V1_CreateConversationRequest(serializedBytes: entry.request)
                        entry.serverID = try await rpc.createChat(request).id
                    case .sendMessage:
                        let request = try Nauclio_V1_SendMessageRequest(serializedBytes: entry.request)
                        let response = try await rpc.sendMessage(request)
                        entry.serverID = response.messageID.isEmpty ? entry.optimisticID : response.messageID
                    }
                    entry.lastError = nil
                    if entry.kind == .sendMessage {
                        // SendMessage returning means the durable daemon accepted
                        // the command. Conversation content arrives on its own
                        // per-card stream, not the metadata-only global stream.
                        self.syncDiskState.outbox.remove(at: index)
                    } else {
                        self.syncDiskState.outbox[index] = entry
                    }
                    self.reconcileOutboxWithProjection()
                    try? await self.syncPersistence.save(self.syncDiskState)
                } catch {
                    entry.attempts += 1
                    entry.lastError = error.localizedDescription
                    self.syncDiskState.outbox[index] = entry
                    self.rebuildOutboxOverlays()
                    try? await self.syncPersistence.save(self.syncDiskState)
                    try? await NauclioTaskSleep.seconds(min(30, Double(1 << min(entry.attempts, 4))))
                }
            }
        }
    }

    func refreshState() async {
        guard let rpc else {
            if let raw = syncProjection.snapshot,
               let snapshot = try? Nauclio_V1_GlobalSnapshot(serializedBytes: raw) {
                applyGlobalSnapshot(snapshot, endpointID: endpoint.id)
            }
            return
        }
        do {
            acceptState(try await rpc.state(stateRequest()))
        } catch {
            show(error)
        }
    }

    private func stateRequest() -> Nauclio_V1_GetStateRequest {
        var request = Nauclio_V1_GetStateRequest()
        request.projectID = selectedProjectID
        return request
    }

    private func acceptState(_ received: Nauclio_V1_State) {
        var next = received
        let boardProjection = OptimisticWorkspaceProjection.reconcileBoards(next.boards, pending: pendingBoards)
        next.boards = boardProjection.boards
        pendingBoards = boardProjection.pending
        let projectProjection = OptimisticWorkspaceProjection.reconcileProjects(next.projects, pending: pendingProjects)
        next.projects = projectProjection.projects
        pendingProjects = projectProjection.pending
        let cardProjection = OptimisticCardProjection.reconcile(
            cards: next.cards,
            moves: pendingCardMoves,
            labels: pendingCardLabelUpdates
        )
        next.cards = cardProjection.cards
        pendingCardMoves = cardProjection.moves
        pendingCardLabelUpdates = cardProjection.labels
        movingCardIDs = Set(cardProjection.moves.keys)
        labelUpdatingCardIDs = Set(cardProjection.labels.keys)
        for card in next.cards + next.chats {
            if let previous = notificationStatuses[card.id], previous != card.runtime,
               ["review", "waiting", "completed", "failed"].contains(card.runtime.lowercased()) {
                notify(title: card.title, body: "Status changed to \(card.runtime)")
            }
            notificationStatuses[card.id] = card.runtime
        }
        state = next
        if !next.project.id.isEmpty {
            navigationBoards[next.project.id] = next.boards
            navigationCards[next.project.id] = next.cards
        }
        for project in next.projects {
            projectDirectory[project.id] = project
            projectEndpointIDs[project.id] = endpoint.id
        }
        if selectedProjectID.isEmpty || !next.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = next.project.id.isEmpty ? (next.projects.first?.id ?? "") : next.project.id
        }
        if selectedBoardID.isEmpty || !next.boards.contains(where: { $0.id == selectedBoardID }) {
            selectedBoardID = next.boards.first(where: { $0.projectID == selectedProjectID })?.id ?? next.boards.first?.id ?? ""
        }
        rebuildOutboxOverlays()
    }

    func refreshNavigation() async {
        await refreshState()
    }

    func refreshChats(includeArchived: Bool = true) async {
        guard let rpc else { return }
        do {
            let response = try await rpc.chats(includeArchived: includeArchived)
            for card in response.chats {
                if let previous = notificationStatuses[card.id], previous != card.runtime,
                   ["review", "waiting", "completed", "failed"].contains(card.runtime.lowercased()) {
                    notify(title: card.title, body: "Status changed to \(card.runtime)")
                }
                notificationStatuses[card.id] = card.runtime
            }
            let previousProjectIDs = Set(projectEndpointIDs.compactMap { $0.value == endpoint.id ? $0.key : nil })
            for project in response.projects {
                projectDirectory[project.id] = project
                projectEndpointIDs[project.id] = endpoint.id
            }
            chats.removeAll { previousProjectIDs.contains($0.projectID) }
            chats.append(contentsOf: response.chats)
            chats = Array(chats.reduce(into: [String: Nauclio_V1_Card]()) { $0[$1.id] = $1 }.values).sorted {
                ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt) > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt)
            }
            chatProjects = projects
            updateSelectedState()
            rebuildOutboxOverlays()
            if let selectedChatID, let selected = chats.first(where: { $0.id == selectedChatID }) {
                markChatRead(selected)
            }
        } catch {
            show(error)
        }
    }

    func openConversation(cardID: String, chat: Bool = false) async {
        let card = chats.first(where: { $0.id == cardID })
            ?? navigationCards.values.lazy.compactMap({ $0.first(where: { $0.id == cardID }) }).first
        if let projectID = card?.projectID, !projectID.isEmpty,
           !(await ensureProjectConnection(projectID)) { return }
        selectedCardID = chat ? nil : cardID
        selectedChatID = chat ? cardID : nil
        if chat { newChatProjectID = "" }
        conversationLoading = true
        conversationTask?.cancel()
        if let cached = projectedConversation(cardID: cardID) {
            acceptConversation(cached, chat: chat)
        }
        guard let rpc else {
            conversationLoading = false
            errorMessage = "The project host is not connected."
            return
        }
        do {
            let snapshot = try await rpc.conversation(cardID: cardID)
            guard (selectedCardID ?? selectedChatID) == cardID else { return }
            acceptConversation(snapshot, chat: chat)
            let after = snapshot.conversation.lastSeq
            conversationTask = Task { [weak self] in
                do {
                    try await rpc.watchConversation(cardID: cardID, after: after) { [weak self] update in
                        await self?.applyConversationUpdate(update, cardID: cardID)
                    }
                } catch where Self.isExpectedCancellation(error) { }
                catch {
                    guard let self, (self.selectedCardID ?? self.selectedChatID) == cardID else { return }
                    self.errorMessage = "Conversation updates paused: \(error.localizedDescription)"
                }
            }
        } catch {
            conversationLoading = false
            errorMessage = "Could not open this conversation: \(error.localizedDescription)"
        }
    }

    private func acceptConversation(_ snapshot: Nauclio_V1_ConversationSnapshot, chat: Bool) {
        conversation = snapshot
        selectedDetail = snapshot.detail
        conversationLoading = false
        composerProvider = snapshot.detail.card.provider
        composerModel = snapshot.detail.card.model
        composerEffort = snapshot.detail.card.effort
        let selectedHarness = harnessCatalog.harnesses.first { $0.id == composerProvider }
        composerProviderOptions = ProviderOptionValues.defaults(for: selectedHarness)
        composerProviderOptions.merge(snapshot.detail.card.providerOptions) { _, saved in saved }
        if chat, let card = chats.first(where: { $0.id == snapshot.detail.card.id }) { markChatRead(card) }
    }

    private func applyConversationUpdate(_ update: Nauclio_V1_ConversationUpdate, cardID: String) {
        guard (selectedCardID ?? selectedChatID) == cardID else { return }
        apply(update)
    }

    func closeConversation() {
        if let selectedChatID, let card = chats.first(where: { $0.id == selectedChatID }) { markChatRead(card) }
        conversationTask?.cancel(); conversationTask = nil
        conversation = nil; selectedDetail = nil; selectedCardID = nil; selectedChatID = nil
    }

    private nonisolated static func isExpectedCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return (error as? RPCError)?.code == .cancelled
    }

    private func apply(_ update: Nauclio_V1_ConversationUpdate) {
        if update.hasSnapshot {
            conversation = update.snapshot
            selectedDetail = update.snapshot.detail
            return
        }
        guard var snapshot = conversation else { return }
        var value = snapshot.conversation
        var messages = value.messages.filter { !update.removedMessageIds.contains($0.id) }
        for changed in update.changedMessages {
            if let index = messages.firstIndex(where: { $0.id == changed.id }) { messages[index] = changed }
            else { messages.append(changed) }
        }
        value.messages = messages
        if !update.status.isEmpty { value.status = update.status }
        value.pendingTools = update.pendingTools; value.queue = update.queue
        value.draftAttachments = update.draftAttachments
        value.lastSeq = update.lastSeq; value.updatedAt = update.updatedAt
        value.subagents = update.subagents; value.taskPlans = update.taskPlans
        snapshot.conversation = value
        if update.hasDetail { snapshot.detail = update.detail; selectedDetail = update.detail }
        if update.hasPage { snapshot.page = update.page }
        conversation = snapshot
    }

    func sendComposer() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !composerAttachments.isEmpty), let id = selectedCardID ?? selectedChatID else { return }
        if let projectID = selectedCard?.projectID, !projectID.isEmpty,
           !(await ensureProjectConnection(projectID)) { return }
        composerText = ""
        let attachments = composerAttachments; composerAttachments = []
        var parts = attachments
        if !text.isEmpty { var part = Nauclio_V1_MessagePart(); part.type = "text"; part.text = text; parts.insert(part, at: 0) }
        var request = Nauclio_V1_SendMessageRequest(); request.cardID = id; request.parts = parts
        request.provider = composerProvider.isEmpty ? (selectedCard?.provider ?? "") : composerProvider
        request.model = composerModel.isEmpty ? (selectedCard?.model ?? "") : composerModel
        request.effort = composerEffort.isEmpty ? (selectedCard?.effort ?? "") : composerEffort
        request.providerOptions = composerProviderOptions
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        request.messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            syncDiskState.outbox.append(NauclioOutboxEntry(
                commandID: request.commandID,
                clientID: syncClientID,
                endpointID: endpoint.id,
                kind: .sendMessage,
                request: try request.serializedData(),
                optimisticID: request.messageID,
                attempts: 0,
                createdAt: Date()
            ))
            await persistAndDrainOutbox()
        } catch {
            composerText = text
            composerAttachments = attachments
            show(error)
        }
    }

    func addAttachments(_ urls: [URL]) {
        do { composerAttachments = try attachmentParts(urls, appendingTo: composerAttachments) }
        catch { show(error) }
    }

    func addPastedAttachments(_ providers: [NSItemProvider]) {
        Task {
            do { composerAttachments = try await attachmentParts(providers, appendingTo: composerAttachments) }
            catch { show(error) }
        }
    }

    func attachmentParts(_ urls: [URL], appendingTo existing: [Nauclio_V1_MessagePart] = []) throws -> [Nauclio_V1_MessagePart] {
        guard existing.count + urls.count <= Self.maximumAttachmentCount else {
            throw NauclioAttachmentError.tooMany
        }
        var parts = existing
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false else { throw NauclioAttachmentError.notAFile(url.lastPathComponent) }
            if let size = values.fileSize, size > Self.maximumAttachmentBytes { throw NauclioAttachmentError.fileTooLarge(url.lastPathComponent) }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            parts = try appendingAttachment(
                data: data,
                filename: url.lastPathComponent,
                contentType: values.contentType,
                to: parts
            )
        }
        return parts
    }

    func attachmentParts(_ providers: [NSItemProvider], appendingTo existing: [Nauclio_V1_MessagePart] = []) async throws -> [Nauclio_V1_MessagePart] {
        guard existing.count + providers.count <= Self.maximumAttachmentCount else {
            throw NauclioAttachmentError.tooMany
        }
        var parts = existing
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try await Self.loadFileURL(provider) {
                parts = try attachmentParts([url], appendingTo: parts)
                continue
            }
            guard let identifier = Self.preferredImageTypeIdentifier(for: provider) else {
                throw NauclioAttachmentError.unsupportedPaste
            }
            let sourceData = try await Self.loadData(provider, typeIdentifier: identifier)
            let normalized = try Self.normalizedImage(data: sourceData, type: UTType(identifier))
            let baseName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = "Pasted Image \(parts.count + 1)"
            let resolvedName = baseName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
            let filename = Self.filename(resolvedName, for: normalized.type)
            parts = try appendingAttachment(data: normalized.data, filename: filename, contentType: normalized.type, to: parts)
        }
        return parts
    }

    func appendingAttachment(
        data: Data,
        filename: String,
        contentType: UTType?,
        to existing: [Nauclio_V1_MessagePart] = []
    ) throws -> [Nauclio_V1_MessagePart] {
        guard existing.count < Self.maximumAttachmentCount else { throw NauclioAttachmentError.tooMany }
        guard !data.isEmpty else { throw NauclioAttachmentError.empty(filename) }
        guard data.count <= Self.maximumAttachmentBytes else { throw NauclioAttachmentError.fileTooLarge(filename) }
        guard existing.reduce(0, { $0 + $1.data.count }) + data.count <= Self.maximumAttachmentTotalBytes else {
            throw NauclioAttachmentError.totalTooLarge
        }
        var part = Nauclio_V1_MessagePart()
        part.type = contentType?.conforms(to: .image) == true ? "image" : "file"
        part.mediaType = contentType?.preferredMIMEType ?? "application/octet-stream"
        part.filename = filename
        part.data = data
        return existing + [part]
    }

    /// Attaches whatever attachable content is on the pasteboard to the composer.
    /// Returns false when the pasteboard holds nothing attachable (plain text),
    /// so the caller can let the focused text view handle ⌘V normally.
    @discardableResult
    func attachPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        do {
            guard let parts = try pasteboardAttachmentParts(pasteboard, appendingTo: composerAttachments) else { return false }
            composerAttachments = parts
            return true
        } catch {
            show(error)
            return true
        }
    }

    /// Returns nil when the pasteboard has no files or images to attach.
    func pasteboardAttachmentParts(
        _ pasteboard: NSPasteboard,
        appendingTo existing: [Nauclio_V1_MessagePart] = []
    ) throws -> [Nauclio_V1_MessagePart]? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return try attachmentParts(urls, appendingTo: existing) }
        let payloads = Self.pasteboardImagePayloads(pasteboard)
        guard !payloads.isEmpty else { return nil }
        guard existing.count + payloads.count <= Self.maximumAttachmentCount else {
            throw NauclioAttachmentError.tooMany
        }
        var parts = existing
        for payload in payloads {
            let normalized = try Self.normalizedImage(data: payload.data, type: payload.type)
            let filename = Self.filename("Pasted Image \(parts.count + 1)", for: normalized.type)
            parts = try appendingAttachment(data: normalized.data, filename: filename, contentType: normalized.type, to: parts)
        }
        return parts
    }

    static func normalizedImage(data: Data, type: UTType?) throws -> (data: Data, type: UTType) {
        if type == .png || type == .jpeg || type == .gif || type == .heic {
            return (data, type ?? .png)
        }
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NauclioAttachmentError.invalidImage
        }
        return (png, .png)
    }

    private static func pasteboardImagePayloads(_ pasteboard: NSPasteboard) -> [(data: Data, type: UTType)] {
        let preferred: [UTType] = [.png, .jpeg, .gif, .heic, .tiff]
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            let types = item.types.compactMap { UTType($0.rawValue) }
            let type = preferred.first(where: types.contains) ?? types.first { $0.conforms(to: .image) }
            guard let type, let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { return nil }
            return (data, type)
        }
    }

    private static let maximumAttachmentCount = 4
    private static let maximumAttachmentBytes = 5 * 1_024 * 1_024
    private static let maximumAttachmentTotalBytes = 6 * 1_024 * 1_024

    private static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferred = [UTType.png, .jpeg, .gif, .heic, .tiff]
        if let type = preferred.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            return type.identifier
        }
        return provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
    }

    private static func loadData(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NauclioAttachmentError.unsupportedPaste) }
            }
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = item as? URL { continuation.resume(returning: url); return }
                if let url = item as? NSURL { continuation.resume(returning: url as URL); return }
                if let data = item as? Data,
                   let value = String(data: data, encoding: .utf8),
                   let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func filename(_ value: String, for contentType: UTType) -> String {
        let url = URL(fileURLWithPath: value)
        guard url.pathExtension.isEmpty, let suffix = contentType.preferredFilenameExtension else { return value }
        return value + "." + suffix
    }

    func addComment() async {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = selectedCardID ?? selectedChatID, let rpc else { return }
        var request = Nauclio_V1_AddCommentRequest(); request.cardID = id; request.message = text; request.name = NSFullUserName()
        do {
            _ = try await rpc.addComment(request); commentText = ""
            selectedDetail = try await rpc.card(id: id)
        } catch { show(error) }
    }

    func createConversation(
        title: String,
        prompt: String,
        attachments: [Nauclio_V1_MessagePart] = [],
        chat: Bool,
        provider: String,
        model: String,
        effort: String,
        providerOptions: [String: String] = [:],
        deferred: Bool,
        projectID: String? = nil,
        lane: String? = nil,
        labelIDs: [String] = []
    ) async {
        let destinationProjectID = projectID ?? selectedProjectID
        guard await ensureProjectConnection(destinationProjectID) else { return }
        var request = Nauclio_V1_CreateConversationRequest()
        request.projectID = destinationProjectID; request.boardID = chat ? "" : selectedBoardID
        request.lane = lane ?? selectedBoard?.lanes.first?.id ?? "backlog"; request.title = title; request.prompt = prompt
        request.provider = provider; request.model = model; request.effort = effort; request.deferStart = deferred
        request.providerOptions = providerOptions
        request.attachments = attachments
        request.labelIds = labelIDs
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        do {
            let optimisticID = "local_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            let target = projectEndpointIDs[destinationProjectID].flatMap { id in endpoints.first { $0.id == id } }
            syncDiskState.outbox.append(NauclioOutboxEntry(
                commandID: request.commandID,
                clientID: syncClientID,
                endpointID: target?.id ?? endpoint.id,
                kind: chat ? .createChat : .createCard,
                request: try request.serializedData(),
                optimisticID: optimisticID,
                attempts: 0,
                createdAt: Date()
            ))
            createConversationPresented = false
            await persistAndDrainOutbox()
            let card = (chat ? chats : state.cards).first { $0.id == optimisticID } ?? Nauclio_V1_Card()
            var local = Nauclio_V1_ConversationSnapshot()
            local.detail.card = card
            local.detail.project = projectDirectory[destinationProjectID] ?? Nauclio_V1_Project()
            if !chat { local.detail.board = board(id: request.boardID) ?? Nauclio_V1_Board() }
            local.conversation.cardID = optimisticID
            local.conversation.status = "pending"
            local.conversation.draftAttachments = attachments
            conversation = local
            selectedDetail = local.detail
            selectedCardID = chat ? nil : optimisticID
            selectedChatID = chat ? optimisticID : nil
            section = chat ? .chats : .board
        } catch { show(error) }
    }

    private func markChatRead(_ card: Nauclio_V1_Card) {
        let activity = card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt
        guard !activity.isEmpty, readChatActivity[card.id] != activity else { return }
        readChatActivity[card.id] = activity
        UserDefaults.standard.set(readChatActivity, forKey: "NauclioReadChatActivity")
    }

    func move(_ card: Nauclio_V1_Card, lane: String, position: Int64? = nil) async {
        guard let rpc else { return }
        let original = state.cards.first(where: { $0.id == card.id }) ?? card
        let optimisticPosition = position ?? ((boardCards.filter { $0.id != card.id && $0.lane == lane }.map(\.position).max() ?? 0) + 1_024)

        let operationID = UUID()
        pendingCardMoves[card.id] = OptimisticCardMove(
            operationID: operationID,
            lane: lane,
            position: optimisticPosition,
            confirmsPosition: position != nil || original.lane == lane
        )

        if let index = state.cards.firstIndex(where: { $0.id == card.id }) {
            var next = state
            next.cards[index].lane = lane
            next.cards[index].position = optimisticPosition
            state = next
        }
        movingCardIDs.insert(card.id)

        var request = Nauclio_V1_MoveCardRequest()
        request.cardID = card.id
        request.lane = lane
        if let position { request.position = position }
        do {
            let moved = try await rpc.moveCard(request)
            if var pending = pendingCardMoves[card.id], pending.operationID == operationID {
                pending.position = moved.position
                pending.confirmsPosition = pending.confirmsPosition || original.lane == lane
                pendingCardMoves[card.id] = pending
            } else if pendingCardMoves[card.id] != nil {
                return
            }
            if let index = state.cards.firstIndex(where: { $0.id == moved.id }) {
                var next = state
                next.cards[index] = moved
                state = next
            }
        } catch {
            guard pendingCardMoves[card.id]?.operationID == operationID else { return }
            pendingCardMoves.removeValue(forKey: card.id)
            movingCardIDs.remove(card.id)
            if let index = state.cards.firstIndex(where: { $0.id == original.id }) {
                var next = state
                next.cards[index] = original
                state = next
            }
            show(error)
        }
    }

    func rename(_ card: Nauclio_V1_Card, title: String) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let rpc else { return }
        var request = Nauclio_V1_RenameCardRequest(); request.cardID = card.id; request.title = title
        do { _ = try await rpc.renameCard(request); await refreshState(); await refreshChats() } catch { show(error) }
    }

    func archive(_ card: Nauclio_V1_Card, archived: Bool) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let rpc else { return }
        var request = Nauclio_V1_ArchiveCardRequest(); request.cardID = card.id; request.archived = archived
        do { _ = try await rpc.archiveCard(request); closeConversation(); await refreshState(); await refreshChats() } catch { show(error) }
    }

    func pin(_ card: Nauclio_V1_Card, pinned: Bool) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let rpc else { return }
        var request = Nauclio_V1_PinChatRequest(); request.cardID = card.id; request.pinned = pinned
        do { _ = try await rpc.pinChat(request); await refreshChats() } catch { show(error) }
    }

    func cancel(_ card: Nauclio_V1_Card) async {
        do { try await rpc?.cancelCard(id: card.id); await refreshState() } catch { show(error) }
    }

    func setLabels(_ card: Nauclio_V1_Card, ids: [String]) async {
        guard let rpc else { return }
        let normalized = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        let original = state.cards.first(where: { $0.id == card.id }) ?? card
        guard original.labelIds != normalized else { return }

        let operationID = UUID()
        pendingCardLabelUpdates[card.id] = .init(operationID: operationID, labelIDs: normalized)

        if let index = state.cards.firstIndex(where: { $0.id == card.id }) {
            var next = state
            next.cards[index].labelIds = normalized
            state = next
        }
        labelUpdatingCardIDs.insert(card.id)

        var request = Nauclio_V1_SetCardLabelsRequest(); request.cardID = card.id; request.labelIds = normalized
        do {
            let updated = try await rpc.setCardLabels(request)
            if let pending = pendingCardLabelUpdates[card.id], pending.operationID != operationID { return }
            if let index = state.cards.firstIndex(where: { $0.id == updated.id }) {
                var next = state
                next.cards[index] = updated
                state = next
            }
        } catch {
            guard pendingCardLabelUpdates[card.id]?.operationID == operationID else { return }
            pendingCardLabelUpdates.removeValue(forKey: card.id)
            labelUpdatingCardIDs.remove(card.id)
            if let index = state.cards.firstIndex(where: { $0.id == original.id }) {
                var next = state
                next.cards[index] = original
                state = next
            }
            show(error)
        }
    }

    func loadArchive() async {
        guard let rpc else { return }
        do {
            archivedProjects = try await rpc.archivedProjects().projects
            if !selectedBoardID.isEmpty { archivedCards = try await rpc.archivedCards(boardID: selectedBoardID).cards }
            await refreshChats(includeArchived: true)
        } catch { show(error) }
    }

    func listProjectDirectories(path: String, machineID: String) async throws -> Nauclio_V1_DirectoryListing {
        guard let machine = machines.first(where: { $0.id == machineID }) ?? (endpoint.id == machineID ? endpoint : nil) else {
            throw NSError(domain: "NauclioMachine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select an enrolled machine."])
        }
        guard machine.online else {
            throw NSError(domain: "NauclioMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."])
        }
        var request = Nauclio_V1_ListDirectoriesRequest()
        request.path = path
        if machine.id == endpoint.id, let rpc {
            return try await rpc.listDirectories(request)
        }
        guard let daemonID = machine.daemonID else {
            throw NSError(domain: "NauclioMachine", code: 3, userInfo: [NSLocalizedDescriptionKey: "The project host has no daemon identity."])
        }
        let client = try NauclioRPC(
            endpoint: machine,
            accessToken: await NauclioCredentialStore.token(for: machine),
            route: .relay(daemonID: daemonID)
        )
        let connection = Task { try? await client.run() }
        defer { connection.cancel(); client.shutdown() }
        return try await client.listDirectories(request)
    }

    func createProject(path: String, name: String, summary: String, prompt: String, boardName: String, workflow: String, machineID: String? = nil) async {
        let target: NauclioEndpoint
        if let machineID {
            guard let selected = machines.first(where: { $0.id == machineID }) ?? (endpoint.id == machineID ? endpoint : nil) else {
                show(NSError(domain: "NauclioMachine", code: 1, userInfo: [NSLocalizedDescriptionKey: "The project host is no longer enrolled."]))
                return
            }
            target = selected
        } else {
            target = endpoint
        }
        guard target.online else {
            show(NSError(domain: "NauclioMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(target.name) is offline."]))
            return
        }
        var request = Nauclio_V1_CreateProjectRequest()
        request.mode = "open"; request.path = path; request.name = name; request.summary = summary
        request.prompt = prompt; request.boardName = boardName; request.workflow = workflow
        do {
            let response: Nauclio_V1_CreateProjectResponse
            if target.id == endpoint.id, let rpc {
                response = try await rpc.createProject(request)
            } else {
                guard let daemonID = target.daemonID else {
                    throw NSError(domain: "NauclioMachine", code: 3, userInfo: [NSLocalizedDescriptionKey: "The project host has no daemon identity."])
                }
                let client = try NauclioRPC(
                    endpoint: target,
                    accessToken: await NauclioCredentialStore.token(for: target),
                    route: .relay(daemonID: daemonID)
                )
                let connection = Task { try? await client.run() }
                do {
                    response = try await client.createProject(request)
                    connection.cancel()
                    client.shutdown()
                } catch {
                    connection.cancel()
                    client.shutdown()
                    throw error
                }
            }
            createProjectPresented = false
            if target.id != endpoint.id { await connect(to: target) }
            selectedProjectID = response.project.id; selectedBoardID = response.board.id; section = .board
            await refreshState(); await refreshNavigation(); await refreshMachineDirectory()
        } catch { show(error) }
    }

    func setProjectArchived(id: String, archived: Bool) async {
        guard let rpc else { return }
        var request = Nauclio_V1_ArchiveProjectRequest(); request.projectID = id; request.archived = archived
        do { _ = try await rpc.archiveProject(request); await refreshState(); await refreshNavigation(); await loadArchive() } catch { show(error) }
    }

    func updateProject(name: String, summary: String, prompt: String) async {
        guard let rpc else { return }
        var request = Nauclio_V1_UpdateProjectRequest(); request.projectID = selectedProjectID
        request.name = name; request.summary = summary; request.prompt = prompt
        do { _ = try await rpc.updateProject(request); projectContextPresented = false; await refreshState() } catch { show(error) }
    }

    func createBoard(name: String, workflow: String, description: String, doneArchivePolicy: String) async {
        guard let rpc else { return }
        var request = Nauclio_V1_CreateBoardRequest(); request.projectID = selectedProjectID
        request.name = name; request.workflow = workflow; request.description_p = description; request.doneArchivePolicy = doneArchivePolicy
        do { let board = try await rpc.createBoard(request); createBoardPresented = false; selectedBoardID = board.id; section = .board; await refreshState(); await refreshNavigation() } catch { show(error) }
    }

    func renameBoard(id: String, name: String) async {
        guard let rpc else { return }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var request = Nauclio_V1_RenameBoardRequest(); request.boardID = id; request.name = normalized
        do {
            let updated = try await rpc.renameBoard(request)
            if let index = state.boards.firstIndex(where: { $0.id == updated.id }) {
                var next = state
                next.boards[index] = updated
                state = next
            }
            if var boards = navigationBoards[updated.projectID],
               let index = boards.firstIndex(where: { $0.id == updated.id }) {
                boards[index] = updated
                navigationBoards[updated.projectID] = boards
            }
            renameBoardPresented = false
            renameBoardTargetID = ""
            await refreshState()
            await refreshNavigation()
        } catch { show(error) }
    }

    func setArchivePolicy(_ policy: String) async {
        guard let rpc else { return }
        var request = Nauclio_V1_SetBoardArchivePolicyRequest(); request.boardID = selectedBoardID; request.doneArchivePolicy = policy
        do { _ = try await rpc.setBoardArchivePolicy(request); archivePolicyPresented = false; await refreshState() } catch { show(error) }
    }

    func createLabel(name: String, color: String, instructions: String = "") async {
        guard let rpc else { return }
        var request = Nauclio_V1_CreateBoardLabelRequest(); request.boardID = selectedBoardID; request.name = name; request.color = color; request.instructions = instructions
        do { acceptBoard(try await rpc.createBoardLabel(request)) } catch { show(error) }
    }

    func updateLabel(id: String, name: String, color: String, instructions: String) async {
        guard let rpc else { return }
        var request = Nauclio_V1_UpdateBoardLabelRequest()
        request.boardID = selectedBoardID; request.labelID = id; request.name = name; request.color = color; request.instructions = instructions
        do { acceptBoard(try await rpc.updateBoardLabel(request)) } catch { show(error) }
    }

    func deleteLabel(id: String) async {
        guard let rpc else { return }
        var request = Nauclio_V1_DeleteBoardLabelRequest(); request.boardID = selectedBoardID; request.labelID = id
        do { acceptBoard(try await rpc.deleteBoardLabel(request)) } catch { show(error) }
    }

    func acceptBoard(_ board: Nauclio_V1_Board) {
        pendingBoards[board.id] = board
        var next = state
        if let index = next.boards.firstIndex(where: { $0.id == board.id }) { next.boards[index] = board }
        else if board.projectID == selectedProjectID { next.boards.append(board) }
        state = next
        if var boards = navigationBoards[board.projectID], let index = boards.firstIndex(where: { $0.id == board.id }) {
            boards[index] = board
            navigationBoards[board.projectID] = boards
        }
    }

    func acceptProject(_ project: Nauclio_V1_Project) {
        pendingProjects[project.id] = project
        projectDirectory[project.id] = project
        var next = state
        if let index = next.projects.firstIndex(where: { $0.id == project.id }) { next.projects[index] = project }
        if next.project.id == project.id { next.project = project }
        state = next
    }

    func loadFiles(path: String? = nil) async {
        guard let rpc, !selectedProjectID.isEmpty else { return }
        if let path { filePath = path }
        var request = Nauclio_V1_ListFilesRequest(); request.projectID = selectedProjectID; request.path = filePath; request.showHidden = showHiddenFiles
        do { files = try await rpc.listFiles(request).entries } catch { show(error) }
    }

    func openFile(path: String) async {
        guard let rpc else { return }
        var request = Nauclio_V1_ReadFileRequest(); request.projectID = selectedProjectID; request.path = path
        do { let doc = try await rpc.readFile(request); fileDocument = doc; fileEditorText = doc.content } catch { show(error) }
    }

    func saveFile() async {
        guard let rpc, let doc = fileDocument else { return }
        var request = Nauclio_V1_SaveFileRequest(); request.projectID = selectedProjectID; request.path = doc.path
        request.content = fileEditorText; request.revision = doc.revision
        do {
            var saved = try await rpc.saveFile(request)
            if saved.mimeType.isEmpty { saved.mimeType = doc.mimeType }
            fileDocument = saved
            fileEditorText = saved.content
        } catch { show(error) }
    }

    func createFile(path: String, directory: Bool) async {
        guard let rpc else { return }
        var request = Nauclio_V1_CreateFileRequest(); request.projectID = selectedProjectID; request.path = path; request.kind = directory ? "directory" : "file"
        do { _ = try await rpc.createFile(request); await loadFiles() } catch { show(error) }
    }

    func deleteFile(path: String, recursive: Bool) async {
        guard let rpc else { return }
        var request = Nauclio_V1_DeleteFileRequest(); request.projectID = selectedProjectID; request.path = path; request.recursive = recursive
        do { try await rpc.deleteFile(request); fileDocument = nil; await loadFiles() } catch { show(error) }
    }

    func moveFile(source: String, destination: String) async {
        guard let rpc else { return }
        var request = Nauclio_V1_MoveFileRequest(); request.projectID = selectedProjectID; request.source = source; request.destination = destination
        do { _ = try await rpc.moveFile(request); fileDocument = nil; await loadFiles() } catch { show(error) }
    }

    func loadSchedules() async {
        await refreshState()
    }

    func saveSchedule(id: String?, draft: Nauclio_V1_ScheduleDraft) async {
        guard let rpc else { return }
        var request = Nauclio_V1_SaveScheduleRequest(); request.scheduleID = id ?? ""; request.schedule = draft
        do {
            let saved = try await (id == nil ? rpc.createSchedule(request) : rpc.updateSchedule(request))
            selectedScheduleID = saved.id; await loadSchedules()
        } catch { show(error) }
    }

    func toggleSchedule(_ schedule: Nauclio_V1_Schedule) async {
        do { _ = try await rpc?.setScheduleEnabled(id: schedule.id, enabled: !schedule.enabled); await loadSchedules() } catch { show(error) }
    }

    func runSchedule(_ schedule: Nauclio_V1_Schedule) async {
        do { _ = try await rpc?.runSchedule(id: schedule.id); await loadSchedules() } catch { show(error) }
    }

    func deleteSchedule(_ schedule: Nauclio_V1_Schedule) async {
        do { try await rpc?.deleteSchedule(id: schedule.id); selectedScheduleID = nil; await loadSchedules() } catch { show(error) }
    }

    func updateLimits(global: Int, agents: [String: Int], boards: [String: Int]) async {
        guard let rpc else { return }
        var settings = boardSettings; settings.globalParallelLimit = Int32(global); settings.agentParallelLimits = agents.mapValues(Int32.init); settings.boardParallelLimits = boards.mapValues(Int32.init)
        var request = Nauclio_V1_UpdateSettingsRequest(); request.settings = settings
        do { boardSettings = try await rpc.updateSettings(request) } catch { show(error) }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: "NauclioNotifications") else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func show(_ error: Error) {
        guard !Self.isExpectedCancellation(error) else { return }
        errorMessage = error.localizedDescription
    }
}

enum NauclioAttachmentError: LocalizedError {
    case tooMany
    case fileTooLarge(String)
    case totalTooLarge
    case empty(String)
    case notAFile(String)
    case unsupportedPaste
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .tooMany: "You can attach up to 4 images or files."
        case .fileTooLarge(let name): "\(name) must be at most 5 MB."
        case .totalTooLarge: "Attachments must total at most 6 MB."
        case .empty(let name): "\(name) is empty."
        case .notAFile(let name): "\(name) is not a regular file."
        case .unsupportedPaste: "The clipboard does not contain an image or file that Nauclio can attach."
        case .invalidImage: "The pasted image could not be decoded."
        }
    }
}
