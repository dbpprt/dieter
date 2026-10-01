#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import Observation
    import SharedCore

    struct IOSCoreFailure: Error, LocalizedError, Sendable {
        let kind: ClientFailure.Kind
        let message: String
        var errorDescription: String? { message }
    }

    /// SwiftUI's observation adapter. All routing, sync, reduction, retention,
    /// durable intent, and recovery remain inside the shared Kotlin core.
    @MainActor
    @Observable
    final class IOSCoreStore {
        static let filesScope = "ios-files"
        static let terminalsScope = "ios-terminals"

        private(set) var session = ClientSessionSlice()
        private(set) var workspace = ClientWorkspaceSlice()
        private(set) var outbox = ClientOutboxSlice()
        private(set) var activity = ClientActivitySlice()
        private(set) var metadata = ClientMetadataSlice()
        private(set) var quotas = ClientQuotasSlice()
        private(set) var telemetry = ClientTelemetrySlice()
        private(set) var files = ClientFilesSlice()
        private(set) var terminals = ClientTerminalsSlice()
        private(set) var terminalScreens: [String: IOSTerminalScreenState] = [:]
        private(set) var conversations: [String: ClientConversationSlice] = [:]
        private(set) var resubscriptions = 0

        @ObservationIgnored private let shared: DieterShared
        @ObservationIgnored let client: LiveCoreClient
        @ObservationIgnored let screenMedia: IOSScreenMedia
        @ObservationIgnored private var subscriptions: [String: SliceSubscription] = [:]

        init(defaults: UserDefaults = .standard) {
            let stateDirectory = Self.stateDirectory()
            try? FileManager.default.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let media = IOSScreenMedia()
            screenMedia = media
            let fixture = IOSScreenFixture.fromEnvironment()
            let shared = DieterShared(
                configuration: SharedConfiguration(
                    stateDirectory: stateDirectory.path,
                    clientVersion: DieterRelease.current,
                    oauthRedirectUri: "dieter-mac://oauth/callback",
                    clientIdPrefix: "ios",
                    legacyClientId: defaults.string(forKey: "DieterIOSClientID"),
                    includeLoopbackRoutes: false,
                    compactTranscripts: true,
                    screenClientName: "iOS",
                    desktopScreens: false),
                extensions: SharedExtensions(
                    rpc: CoreRpcBridge(),
                    secureStore: IOSCoreSecureStore(),
                    settings: CoreDefaultsSettings(defaults: defaults),
                    http: CoreURLSessionHttp(),
                    signatures: CoreCryptoKitSignatures(),
                    logger: CoreOSLogger(subsystem: "com.dbpprt.dieter.ios"),
                    notifications: nil,
                    controlChannels: CoreControlChannels(),
                    screenMedia: media,
                    clipboard: nil,
                    screenFixture: fixture))
            self.shared = shared
            client = LiveCoreClient(shared: shared)
            subscribe(.session)
            subscribe(.workspace)
            subscribe(.outbox)
            subscribe(.activity)
            subscribe(.metadata)
            subscribe(.quotas)
            subscribe(.telemetry)
            subscribe(.files, scope: Self.filesScope)
            subscribe(.terminals, scope: Self.terminalsScope)
        }

        var clientID: String { shared.clientId }
        var needsLegacyImport: Bool { shared.needsLegacyImport }

        func start() { shared.start() }

        func importLegacy(gateway: String?, token: String?, preferredMachine: String?) async throws {
            _ = try await shared.importLegacy(
                input: SharedAppleLegacyInput(
                    endpointsJson: nil, activeEndpointJson: nil, tokensJson: nil,
                    iosGateway: gateway, iosToken: token, iosPreferredMachine: preferredMachine,
                    pendingCommandsJson: nil, sharedKvAccount: nil, sharedKvDaemon: nil,
                    sharedKvJson: nil, draftsJson: nil, quickTaskChoicesJson: nil,
                    creationWorkspaceMode: nil, terminalSelections: [:],
                    notificationsEnabled: nil, isIos: true))
        }

        @discardableResult
        func dispatch(_ command: ClientCommand) async throws -> ClientResult {
            try await client.dispatch(command)
        }

        func observeConversation(_ cardID: String) { subscribe(.conversation, scope: cardID) }

        func stopObservingConversation(_ cardID: String) {
            subscriptions.removeValue(forKey: key(.conversation, cardID))?.close()
            conversations[cardID] = nil
        }

        func shutdown() async {
            subscriptions.values.forEach { $0.close() }
            subscriptions.removeAll()
            try? await shared.shutdown()
        }

        private func key(_ slice: ClientSlice, _ scope: String) -> String {
            "\(slice.rawValue)|\(scope)"
        }

        private func subscribe(_ slice: ClientSlice, scope: String = "") {
            let subscriptionKey = key(slice, scope)
            subscriptions.removeValue(forKey: subscriptionKey)?.close()
            subscriptions[subscriptionKey] = SliceSubscription(
                client: client, slice: slice, scope: scope,
                onReset: { [weak self] in
                    guard let self else { return }
                    self.resubscriptions += 1
                    if slice == .conversation { self.conversations[scope] = nil }
                },
                onUpdate: { [weak self] update in self?.apply(update) })
        }

        private func apply(_ update: ClientUpdate) {
            switch update.value {
            case .session(let slice): session = slice
            case .workspace(let slice): workspace = slice
            case .workspaceDelta(let delta): apply(delta)
            case .outbox(let slice): outbox = slice
            case .activity(let slice): activity = slice
            case .metadata(let slice): metadata = slice
            case .quotas(let slice): quotas = slice
            case .telemetry(let slice): telemetry = slice
            case .files(let slice): files = slice
            case .terminals(let slice):
                terminals = slice
                let live = Set(slice.terminals.map(\.id))
                terminalScreens = terminalScreens.filter { live.contains($0.key) }
                for output in slice.output {
                    var screen = terminalScreens[output.terminalID] ?? IOSTerminalScreenState()
                    screen.apply(data: output.data, reset: output.reset)
                    terminalScreens[output.terminalID] = screen
                }
            case .conversation(let slice): conversations[update.scope] = normalized(slice)
            case .conversationDelta(let delta): apply(delta, scope: update.scope)
            case .failure(let failure):
                if update.slice == .conversation, var conversation = conversations[update.scope] {
                    conversation.error = failure.message
                    conversations[update.scope] = conversation
                }
            default: break
            }
        }

        private func apply(_ delta: ClientWorkspaceDelta) {
            workspace.projects = delta.projects
            workspace.boards = delta.boards
            workspace.cards = KeyedList.apply(
                workspace.cards, upserted: delta.upsertedCards, removed: delta.removedCardIds,
                order: delta.orderChanged ? delta.cardOrder : nil, key: \.id)
            workspace.pendingCardIds = delta.pendingCardIds
            workspace.loaded = delta.loaded
            workspace.projectReplicas = delta.projectReplicas
            workspace.retiredBoards = delta.retiredBoards
            workspace.settings = delta.settings
        }

        private func apply(_ delta: ClientConversationDelta, scope: String) {
            guard var slice = conversations[scope] else {
                subscriptions[key(.conversation, scope)]?.resubscribe()
                return
            }
            slice.cardID = delta.cardID
            slice.daemonID = delta.daemonID
            slice.card = delta.card
            slice.conversation = delta.conversation
            slice.messages = KeyedList.apply(
                slice.messages, upserted: delta.upsertedMessages, removed: delta.removedMessageIds,
                order: delta.orderChanged ? delta.messageOrder : nil, key: \.id)
            slice.loading = delta.loading
            slice.syncing = delta.syncing
            slice.error = delta.error
            slice.pending = delta.pending
            slice.hasEarlier_p = delta.hasEarlier_p
            slice.loadingEarlier = delta.loadingEarlier
            slice.browsingEarlier = delta.browsingEarlier
            slice.awaitingReply = delta.awaitingReply
            slice.retrying = delta.retrying
            slice.refreshedAtMillis = delta.refreshedAtMillis
            slice.turnFailure = delta.turnFailure
            slice.project = delta.project
            slice.board = delta.board
            slice.page = delta.page
            slice.earlierCount = delta.earlierCount
            slice.state = delta.state
            conversations[scope] = normalized(slice)
        }

        private func normalized(_ value: ClientConversationSlice) -> ClientConversationSlice {
            var value = value
            value.conversation.messages = value.messages
            return value
        }

        private static func stateDirectory() -> URL {
            let root =
                (try? FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true))
                ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            return root.appending(path: "com.dbpprt.dieter.ios/core", directoryHint: .isDirectory)
        }
    }
#endif
