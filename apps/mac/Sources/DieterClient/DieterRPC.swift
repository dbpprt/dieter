import DieterAPI
import DieterCore
import DieterTransport
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

/// One long-lived native HTTP/2 gRPC channel to the loopback Dieter server.
package final class DieterRPC: Sendable {
    package typealias Transport = HTTP2ClientTransport.Posix
    package typealias Service = Dieter_V1_DieterService.Client<Transport>
    package typealias GatewayService = Dieter_Gateway_V1_GatewayService.Client<Transport>

    package let endpoint: DieterEndpoint
    package let core: GRPCClient<Transport>
    package let service: Service
    package let gatewayService: GatewayService
    package let directCredential: DirectAccessCredential?
    private let controlBridge: ControlRTCBridge?

    package static func attachmentCallOptions(bounded: Bool = false) -> CallOptions {
        var options = CallOptions.defaults
        if bounded { options.timeout = .seconds(15) }
        options.maxRequestMessageBytes = 16 * 1_024 * 1_024
        options.maxResponseMessageBytes = 16 * 1_024 * 1_024
        return options
    }

    package static func boundedUnaryCallOptions() -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(15)
        return options
    }

    private static func remoteDesktopControlCallOptions() -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(3)
        return options
    }

    package struct DirectRoute: Sendable {
        package init(
            host: String,
            port: Int,
            daemonID: String,
            daemonCAPEM: Data,
            accessToken: String,
            expiresAt: String = "",
            daemonGeneration: UInt64 = 0
        ) {
            self.host = host
            self.port = port
            self.daemonID = daemonID
            self.daemonCAPEM = daemonCAPEM
            self.accessToken = accessToken
            self.expiresAt = expiresAt
            self.daemonGeneration = daemonGeneration
        }
        let host: String
        let port: Int
        let daemonID: String
        let daemonCAPEM: Data
        let accessToken: String
        let expiresAt: String
        let daemonGeneration: UInt64
    }

    package enum Route: Equatable, Sendable {
        case gateway
        case relay(daemonID: String)

        package var daemonID: String? {
            if case .relay(let daemonID) = self { return daemonID }
            return nil
        }
    }

    package init(
        endpoint: DieterEndpoint,
        accessToken: String? = nil,
        route: Route = .gateway,
        direct: DirectRoute? = nil,
        controlBridge: ControlRTCBridge? = nil
    ) throws {
        self.controlBridge = controlBridge
        self.endpoint = endpoint
        let host = direct?.host ?? endpoint.host
        let port = direct?.port ?? endpoint.port
        let security: HTTP2ClientTransport.Posix.TransportSecurity
        if let direct {
            security = .tls { config in
                config.trustRoots = .certificates([.bytes(Array(direct.daemonCAPEM), format: .pem)])
                // Direct candidates use IP targets, while daemon certificates
                // carry an exact SPIFFE URI SAN. Verify both the enrolled CA
                // chain and that daemon identity here.
                config.serverCertificateVerification = .noHostnameVerification
                config.verifySignatureAlgorithms = [.ed25519]
                let daemonID = direct.daemonID
                let daemonCAPEM = direct.daemonCAPEM
                config.customVerificationCallback = { certificates, promise in
                    let derChain = certificates.compactMap { try? Data($0.toDERBytes()) }
                    let verified = DaemonCertificatePinning.verify(
                        derChain,
                        daemonCAPEM: daemonCAPEM,
                        daemonID: daemonID
                    )
                    promise.succeed(verified ? .certificateVerified(.init(nil)) : .failed)
                }
            }
        } else {
            security = endpoint.secure ? .tls : .plaintext
        }
        let transport: Transport = try .http2NIOPosix(
            target: DieterTransportTarget.make(host: host, port: port),
            transportSecurity: security
        )
        let directCredential = direct.map {
            DirectAccessCredential(
                token: $0.accessToken,
                expiresAt: $0.expiresAt,
                daemonGeneration: $0.daemonGeneration
            )
        }
        self.directCredential = directCredential
        let daemonID = direct == nil ? route.daemonID : nil
        let bearer: BearerInterceptor?
        if let directCredential {
            bearer = BearerInterceptor(source: .renewable(directCredential), daemonID: daemonID)
        } else if let accessToken {
            bearer = BearerInterceptor(source: .fixed(accessToken), daemonID: daemonID)
        } else {
            bearer = nil
        }
        var interceptors: [any ClientInterceptor] = [ReleaseVersionInterceptor()]
        if let bearer { interceptors.append(bearer) }
        let core = GRPCClient(transport: transport, interceptors: interceptors)
        self.core = core
        self.service = Service(wrapping: core)
        self.gatewayService = GatewayService(wrapping: core)
    }

    package func run() async throws {
        try await core.runConnections()
    }

    package func shutdown() {
        core.beginGracefulShutdown()
        controlBridge?.close()
    }

    package func daemons() async throws -> Dieter_Gateway_V1_ListDaemonsResponse {
        try await gatewayService.listDaemons(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func compatibility() async throws -> Dieter_Gateway_V1_CompatibilityResponse {
        var request = Dieter_Gateway_V1_CompatibilityRequest()
        request.releaseVersion = DieterRelease.current
        request.component = .client
        return try await gatewayService.getCompatibility(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func providerQuotas() async throws -> Dieter_Gateway_V1_ListProviderQuotasResponse {
        try await gatewayService.listProviderQuotas(
            request: .init(message: Dieter_Gateway_V1_ListProviderQuotasRequest()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func refreshProviderQuotas() async throws -> Dieter_Gateway_V1_RefreshProviderQuotasResponse {
        try await gatewayService.refreshProviderQuotas(
            request: .init(message: Dieter_Gateway_V1_RefreshProviderQuotasRequest()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func setProviderQuotaSummaryInclusion(
        provider: Dieter_Gateway_V1_ProviderQuotaProvider,
        accountKey: String,
        included: Bool
    ) async throws -> Dieter_Gateway_V1_SetProviderQuotaSummaryInclusionResponse {
        var request = Dieter_Gateway_V1_SetProviderQuotaSummaryInclusionRequest()
        request.provider = provider
        request.accountKey = accountKey
        request.included = included
        return try await gatewayService.setProviderQuotaSummaryInclusion(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func consumeProviderQuotaReset(
        accountKey: String,
        idempotencyKey: String
    ) async throws -> Dieter_Gateway_V1_ConsumeProviderQuotaResetResponse {
        var request = Dieter_Gateway_V1_ConsumeProviderQuotaResetRequest()
        request.provider = .openaiCodex
        request.accountKey = accountKey
        request.idempotencyKey = idempotencyKey
        return try await gatewayService.consumeProviderQuotaReset(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func route(daemonID: String) async throws -> Dieter_Gateway_V1_DaemonRoute {
        var request = Dieter_Gateway_V1_DaemonRef()
        request.daemonID = daemonID
        return try await gatewayService.resolveDaemonRoute(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func rtcConfiguration(daemonID: String) async throws -> Dieter_Gateway_V1_RTCConfiguration {
        var request = Dieter_Gateway_V1_DaemonRef()
        request.daemonID = daemonID
        return try await gatewayService.getRTCConfiguration(request: .init(message: request))
    }

    package func daemonAccessToken(daemonID: String) async throws
        -> Dieter_Gateway_V1_DaemonAccessToken
    {
        var request = Dieter_Gateway_V1_ExchangeDaemonTokenRequest()
        request.daemonID = daemonID
        return try await gatewayService.exchangeDaemonToken(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func health(timeout: Duration? = nil) async throws -> Dieter_V1_HealthResponse {
        var options = CallOptions.defaults
        options.timeout = timeout
        return try await service.health(
            request: .init(message: Google_Protobuf_Empty()), options: options)
    }

    package func machineInformation() async throws -> Dieter_V1_MachineInformation {
        try await service.getMachineInformation(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func state(_ request: Dieter_V1_GetStateRequest = .init()) async throws -> Dieter_V1_State {
        try await service.getState(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func harnesses() async throws -> Dieter_V1_HarnessCatalog {
        try await service.getHarnesses(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func archivedCards(boardID: String) async throws -> Dieter_V1_CardsResponse {
        var request = Dieter_V1_BoardRef()
        request.boardID = boardID
        return try await service.listArchivedCards(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func createCard(_ request: Dieter_V1_CreateConversationRequest) async throws
        -> Dieter_V1_Card
    {
        try await service.createCard(
            request: .init(message: request), options: Self.attachmentCallOptions())
    }

    package func createChat(_ request: Dieter_V1_CreateConversationRequest) async throws
        -> Dieter_V1_Card
    {
        try await service.createChat(
            request: .init(message: request), options: Self.attachmentCallOptions())
    }

    package func chats(includeArchived: Bool = false) async throws -> Dieter_V1_ChatsResponse {
        var request = Dieter_V1_ListChatsRequest()
        request.includeArchived = includeArchived
        return try await service.listChats(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func card(id: String) async throws -> Dieter_V1_CardDetail {
        var request = Dieter_V1_GetCardRequest()
        request.cardID = id
        return try await service.getCard(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func conversation(cardID: String, limit: Int32 = 30, before: Int32? = nil) async throws
        -> Dieter_V1_ConversationSnapshot
    {
        var request = Dieter_V1_GetConversationRequest()
        request.cardID = cardID
        request.limit = limit
        if let before { request.before = before }
        return try await service.getConversation(
            request: .init(message: request), options: Self.attachmentCallOptions(bounded: true))
    }

    package func watchConversation(
        cardID: String,
        after sequence: Int64,
        receive: @Sendable @escaping (Dieter_V1_ConversationUpdate) async -> Void
    ) async throws {
        var request = Dieter_V1_WatchConversationRequest()
        request.cardID = cardID
        request.limit = 30
        request.intervalMs = 700
        request.afterSeq = sequence
        try await service.watchConversation(
            request: .init(message: request), options: Self.attachmentCallOptions()
        ) {
            response in
            for try await update in response.messages {
                try Task.checkCancellation()
                await receive(update)
            }
        }
    }

    package func presentConversationContent(_ request: Dieter_V1_PresentConversationContentRequest) async throws
        -> Dieter_V1_ContentPresentation
    {
        try await service.presentConversationContent(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func sendMessage(_ request: Dieter_V1_SendMessageRequest) async throws
        -> Dieter_V1_SendMessageResponse
    {
        try await service.sendMessage(
            request: .init(message: request), options: Self.attachmentCallOptions())
    }

    package func removeQueuedMessage(cardID: String, messageID: String) async throws
        -> Dieter_V1_QueuedMessage
    {
        var request = Dieter_V1_RemoveQueuedMessageRequest()
        request.cardID = cardID
        request.messageID = messageID
        return try await service.removeQueuedMessage(request: .init(message: request))
    }

    package func moveCard(_ request: Dieter_V1_MoveCardRequest) async throws -> Dieter_V1_Card {
        try await service.moveCard(request: .init(message: request))
    }

    package func startCard(_ request: Dieter_V1_StartCardRequest) async throws -> Dieter_V1_StartCardResponse {
        try await service.startCard(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func cancelCard(id: String) async throws {
        var request = Dieter_V1_GetCardRequest()
        request.cardID = id
        _ = try await service.cancelCard(request: .init(message: request)) as Google_Protobuf_Empty
    }

    package func archiveCard(_ request: Dieter_V1_ArchiveCardRequest) async throws -> Dieter_V1_Card {
        try await service.archiveCard(request: .init(message: request))
    }

    package func workspace(cardID: String) async throws -> Dieter_V1_Workspace {
        var request = Dieter_V1_ConversationRef()
        request.cardID = cardID
        return try await service.getWorkspace(request: .init(message: request))
    }

    package func changeset(projectID: String) async throws -> Dieter_V1_Changeset {
        var request = Dieter_V1_GetChangesetRequest()
        request.projectID = projectID
        return try await service.getChangeset(request: .init(message: request))
    }

    package func listFiles(_ request: Dieter_V1_ListFilesRequest) async throws -> Dieter_V1_FileList {
        return try await service.listFiles(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func readFile(_ request: Dieter_V1_ReadFileRequest) async throws -> Dieter_V1_FileDocument {
        return try await service.readFile(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func saveFile(_ request: Dieter_V1_SaveFileRequest) async throws -> Dieter_V1_FileDocument {
        return try await service.saveFile(request: .init(message: request))
    }

    package func createFile(_ request: Dieter_V1_CreateFileRequest) async throws
        -> Dieter_V1_FileEntry
    {
        return try await service.createFile(request: .init(message: request))
    }

    package func terminals(projectID: String = "", cardID: String = "") async throws
        -> Dieter_V1_TerminalsResponse
    {
        var request = Dieter_V1_ListTerminalsRequest()
        request.projectID = projectID
        request.cardID = cardID
        return try await service.listTerminals(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func createTerminal(_ request: Dieter_V1_CreateTerminalRequest) async throws
        -> Dieter_V1_Terminal
    {
        return try await service.createTerminal(request: .init(message: request))
    }

    package func watchTerminal(
        id: String,
        after sequence: UInt64,
        receive: @Sendable @escaping (Dieter_V1_TerminalFrame) async -> Void
    ) async throws {
        var request = Dieter_V1_WatchTerminalRequest()
        request.terminalID = id
        request.afterSequence = sequence
        request.heartbeatMs = 15_000
        try await service.watchTerminal(
            request: .init(message: request), options: Self.attachmentCallOptions()
        ) {
            response in
            for try await frame in response.messages {
                try Task.checkCancellation()
                await receive(frame)
            }
        }
    }

    package func writeTerminal(id: String, data: Data) async throws -> Dieter_V1_Terminal {
        var request = Dieter_V1_TerminalInputRequest()
        request.terminalID = id
        request.data = data
        return try await service.writeTerminal(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func resizeTerminal(id: String, columns: Int, rows: Int) async throws
        -> Dieter_V1_Terminal
    {
        var request = Dieter_V1_ResizeTerminalRequest()
        request.terminalID = id
        request.columns = Int32(columns)
        request.rows = Int32(rows)
        return try await service.resizeTerminal(request: .init(message: request))
    }

    package func renameTerminal(id: String, name: String) async throws -> Dieter_V1_Terminal {
        var request = Dieter_V1_RenameTerminalRequest()
        request.terminalID = id
        request.name = name
        return try await service.renameTerminal(request: .init(message: request))
    }

    package func closeTerminal(id: String) async throws {
        var request = Dieter_V1_TerminalRef()
        request.terminalID = id
        _ = try await service.closeTerminal(request: .init(message: request)) as Google_Protobuf_Empty
    }

    package func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities {
        try await service.getRemoteDesktopCapabilities(request: .init(message: Google_Protobuf_Empty()))
    }

    package func startRemoteDesktop(
        _ request: Dieter_V1_StartRemoteDesktopRequest,
        receive: @Sendable @escaping (Dieter_V1_RemoteDesktopSignal) async throws -> Void
    ) async throws {
        try await service.startRemoteDesktop(request: .init(message: request)) { response in
            for try await signal in response.messages {
                try Task.checkCancellation()
                try await receive(signal)
            }
        }
    }

    package func sendRemoteDesktopSignal(_ signal: Dieter_V1_RemoteDesktopSignal) async throws {
        _ =
            try await service.sendRemoteDesktopSignal(
                request: .init(message: signal), options: Self.remoteDesktopControlCallOptions()
            ) as Google_Protobuf_Empty
    }

    package func remoteDesktopSession(sessionID: String) async throws -> Dieter_V1_RemoteDesktopSessionState {
        var request = Dieter_V1_RemoteDesktopRef(); request.sessionID = sessionID
        return try await service.getRemoteDesktopSession(request: .init(message: request))
    }
    package func updateRemoteDesktopSession(_ request: Dieter_V1_UpdateRemoteDesktopSessionRequest) async throws
        -> Dieter_V1_RemoteDesktopSessionState
    {
        try await service.updateRemoteDesktopSession(request: .init(message: request))
    }

    package func remoteDesktopSessions() async throws -> Dieter_V1_RemoteDesktopSessions {
        try await service.listRemoteDesktopSessions(request: .init(message: Google_Protobuf_Empty()))
    }

    package func setRemoteDesktopControl(sessionID: String, take: Bool) async throws
        -> Dieter_V1_RemoteDesktopSessionState
    {
        var request = Dieter_V1_RemoteDesktopControlRequest()
        request.sessionID = sessionID; request.takeControl = take
        return try await service.setRemoteDesktopControl(request: .init(message: request))
    }

    package func remoteDesktopDisplayModes(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes {
        var request = Dieter_V1_RemoteDesktopRef(); request.sessionID = sessionID
        return try await service.listRemoteDesktopDisplayModes(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func setRemoteDesktopDisplayMode(_ request: Dieter_V1_SetRemoteDesktopDisplayModeRequest) async throws
        -> Dieter_V1_RemoteDesktopDisplayModes
    {
        try await service.setRemoteDesktopDisplayMode(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
    package func restoreRemoteDesktopDisplayMode(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes
    {
        var request = Dieter_V1_RemoteDesktopRef(); request.sessionID = sessionID
        return try await service.restoreRemoteDesktopDisplayMode(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func closeRemoteDesktop(sessionID: String) async throws {
        var request = Dieter_V1_RemoteDesktopRef()
        request.sessionID = sessionID
        _ =
            try await service.closeRemoteDesktop(
                request: .init(message: request), options: Self.remoteDesktopControlCallOptions()
            ) as Google_Protobuf_Empty
    }

}

private enum BearerSource: Sendable {
    case fixed(String)
    case renewable(DirectAccessCredential)

    var token: String {
        switch self {
        case .fixed(let token): token
        case .renewable(let credential): credential.snapshot().token
        }
    }
}

private struct BearerInterceptor: ClientInterceptor {
    let source: BearerSource
    let daemonID: String?
    package func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>, context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<
            Output
        >
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.addString("Bearer \(source.token)", forKey: "authorization")
        if let daemonID { request.metadata.addString(daemonID, forKey: "x-dieter-daemon-id") }
        return try await next(request, context)
    }
}

private struct ReleaseVersionInterceptor: ClientInterceptor {
    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>, context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.addString(DieterRelease.current, forKey: "x-dieter-client-version")
        return try await next(request, context)
    }
}
