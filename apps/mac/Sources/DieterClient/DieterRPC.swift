import Darwin
import DieterAPI
import DieterCore
import Foundation
import Synchronization
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Security
import SwiftProtobuf
import X509

/// One long-lived native HTTP/2 gRPC channel to the loopback Dieter server.
package final class DieterRPC: Sendable {
    package typealias Transport = HTTP2ClientTransport.Posix
    package typealias Service = Dieter_V1_DieterService.Client<Transport>
    package typealias GatewayService = Dieter_Gateway_V1_GatewayService.Client<Transport>

    private let checkoutSelections = Mutex<[String: String]>([:])
    package func selectCheckout(projectID: String, checkoutID: String) {
        checkoutSelections.withLock { $0[projectID] = checkoutID }
    }
    private func checkoutID(projectID: String, cardID: String = "") -> String {
        guard cardID.isEmpty else { return "" }
        return checkoutSelections.withLock { $0[projectID] ?? "" }
    }

    package let endpoint: DieterEndpoint
    /// Whether this data plane actually connects to this Mac's loopback,
    /// independent of the gateway endpoint retained for machine identity.
    package let isLoopbackDataPlane: Bool
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
        isLoopbackDataPlane =
            controlBridge == nil && Self.isLoopbackDataPlane(endpoint: endpoint, route: route, directHost: direct?.host)
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
                    let verified = Self.verifyDaemonCertificateChain(
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
        let interceptors: [any ClientInterceptor] = bearer.map { [$0] } ?? []
        let core = GRPCClient(transport: transport, interceptors: interceptors)
        self.core = core
        self.service = Service(wrapping: core)
        self.gatewayService = GatewayService(wrapping: core)
    }

    package static func isLoopbackDataPlane(endpoint: DieterEndpoint, route: Route, directHost: String?) -> Bool {
        guard route.daemonID == nil, directHost != nil || endpoint.daemonID == nil else { return false }
        let host = (directHost ?? endpoint.host).lowercased()
        if host == "localhost" { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127 }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { bytes in
            bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                || bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127
        }
    }

    package static func verifyDaemonCertificateChain(
        _ derChain: [Data],
        daemonCAPEM: Data,
        daemonID: String
    ) -> Bool {
        guard let leafData = derChain.first,
            SecCertificateCreateWithData(nil, leafData as CFData) != nil,
            let caDER = pemCertificateDER(daemonCAPEM),
            let ca = SecCertificateCreateWithData(nil, caDER as CFData)
        else { return false }
        let chain = derChain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard chain.count == derChain.count else { return false }
        var trust: SecTrust?
        guard
            SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust)
                == errSecSuccess,
            let trust,
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
            SecTrustEvaluateWithError(trust, nil)
        else { return false }
        return certificateHasDaemonIdentity(leafData, daemonID: daemonID)
    }

    /// Match only a URI subject-alternative-name, never a common name, DNS SAN,
    /// substring, or another extension containing the same bytes. X509's DER
    /// parser is available on both iOS and macOS; SecCertificateCopyValues is not.
    package static func certificateHasDaemonIdentity(_ der: Data, daemonID: String) -> Bool {
        guard !daemonID.isEmpty,
            let certificate = try? Certificate(derEncoded: Array(der)),
            let names = try? certificate.extensions.subjectAlternativeNames
        else { return false }
        let expected = "spiffe://board/daemon/\(daemonID)"
        return names.contains { name in
            guard case .uniformResourceIdentifier(let value) = name else { return false }
            return value == expected
        }
    }

    private static func pemCertificateDER(_ pem: Data) -> Data? {
        guard let value = String(data: pem, encoding: .utf8) else { return nil }
        let body =
            value
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: body)
    }

    package func run() async throws {
        try await core.runConnections()
    }

    package func shutdown() {
        core.beginGracefulShutdown()
        controlBridge?.close()
    }

    package func daemons() async throws -> Dieter_Gateway_V1_ListDaemonsResponse {
        let response = try await gatewayService.listDaemons(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
        guard response.gatewayInformation.apiVersion == DieterContract.version else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Update the Dieter gateway and clients together; application contract mismatch.")
        }
        return response
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

    package func revokeDaemon(daemonID: String) async throws {
        var request = Dieter_Gateway_V1_DaemonRef()
        request.daemonID = daemonID
        _ =
            try await gatewayService.revokeDaemon(request: .init(message: request))
            as Google_Protobuf_Empty
    }

    package func renameDaemon(daemonID: String, name: String) async throws -> Dieter_Gateway_V1_Daemon {
        var request = Dieter_Gateway_V1_RenameDaemonRequest()
        request.daemonID = daemonID
        request.name = name
        return try await gatewayService.renameDaemon(request: .init(message: request))
    }

    package func health(timeout: Duration? = nil) async throws -> Dieter_V1_HealthResponse {
        var options = CallOptions.defaults
        options.timeout = timeout
        return try await service.health(
            request: .init(message: Google_Protobuf_Empty()), options: options)
    }

    package func runtimeStatus() async throws -> Dieter_V1_RuntimeStatus {
        try await service.getRuntimeStatus(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func machineInformation() async throws -> Dieter_V1_MachineInformation {
        try await service.getMachineInformation(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func performMachineOperation(
        _ action: Dieter_V1_MachineOperationAction,
        confirmation: String
    ) async throws -> Dieter_V1_MachineOperationResponse {
        var request = Dieter_V1_MachineOperationRequest()
        request.action = action
        request.confirmation = confirmation
        request.idempotencyKey = UUID().uuidString
        return try await service.performMachineOperation(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func promptSettings() async throws -> Dieter_V1_PromptSettings {
        try await service.getPromptSettings(
            request: .init(message: Google_Protobuf_Empty()), options: Self.boundedUnaryCallOptions())
    }

    package func updatePromptSettings(_ request: Dieter_V1_UpdatePromptSettingsRequest) async throws
        -> Dieter_V1_PromptSettings
    {
        try await service.updatePromptSettings(request: .init(message: request))
    }

    package func setProjectPromptTemplate(_ request: Dieter_V1_SetScopedPromptTemplateRequest)
        async throws
        -> Dieter_V1_Project
    {
        try await service.setProjectPromptTemplate(request: .init(message: request))
    }

    package func setBoardPromptTemplate(_ request: Dieter_V1_SetScopedPromptTemplateRequest)
        async throws
        -> Dieter_V1_Board
    {
        try await service.setBoardPromptTemplate(request: .init(message: request))
    }

    package func previewPrompt(_ request: Dieter_V1_PreviewPromptRequest) async throws
        -> Dieter_V1_PromptPreview
    {
        try await service.previewPrompt(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func state(_ request: Dieter_V1_GetStateRequest = .init()) async throws -> Dieter_V1_State {
        try await service.getState(
            request: .init(message: request),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func watchState(
        _ request: Dieter_V1_WatchStateRequest,
        receive: @Sendable @escaping (Dieter_V1_State) async -> Void
    ) async throws {
        try await service.watchState(request: .init(message: request)) { response in
            for try await state in response.messages {
                try Task.checkCancellation()
                await receive(state)
            }
        }
    }

    package func watchSync(
        _ request: Dieter_V1_SyncRequest,
        receive: @Sendable @escaping (Dieter_V1_SyncFrame) async -> Void
    ) async throws {
        try await service.watchSync(
            request: .init(message: request), options: Self.attachmentCallOptions()
        ) {
            response in
            for try await frame in response.messages {
                try Task.checkCancellation()
                await receive(frame)
            }
        }
    }

    package func harnesses() async throws -> Dieter_V1_HarnessCatalog {
        try await service.getHarnesses(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func settings() async throws -> Dieter_V1_Settings {
        try await service.getSettings(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func settingsOptions() async throws -> Dieter_V1_SettingsOptions {
        try await service.getSettingsOptions(
            request: .init(message: Google_Protobuf_Empty()),
            options: Self.boundedUnaryCallOptions()
        )
    }

    package func updateSettings(_ request: Dieter_V1_UpdateSettingsRequest) async throws
        -> Dieter_V1_Settings
    {
        try await service.updateSettings(request: .init(message: request))
    }

    package func listDirectories(_ request: Dieter_V1_ListDirectoriesRequest) async throws
        -> Dieter_V1_DirectoryListing
    {
        try await service.listDirectories(request: .init(message: request))
    }

    package func peerRecord(_ request: Dieter_V1_PeerRecordRef) async throws -> Dieter_V1_PeerRecord {
        try await service.getPeerRecord(request: .init(message: request))
    }
    package func putPeerRecord(_ request: Dieter_V1_PutPeerRecordRequest) async throws -> Dieter_V1_PeerRecord {
        try await service.putPeerRecord(request: .init(message: request))
    }

    package func consolidateProject(source: String, destination: String) async throws -> Dieter_V1_Project {
        var request = Dieter_V1_ConsolidateProjectRequest()
        request.sourceProjectID = source; request.destinationProjectID = destination
        return try await service.consolidateProject(request: .init(message: request))
    }
    package func attachCheckout(_ request: Dieter_V1_AttachCheckoutRequest) async throws -> Dieter_V1_Checkout {
        try await service.attachCheckout(request: .init(message: request))
    }
    package func detachCheckout(_ request: Dieter_V1_CheckoutRef) async throws -> Google_Protobuf_Empty {
        try await service.detachCheckout(request: .init(message: request))
    }

    package func createProject(_ request: Dieter_V1_CreateProjectRequest) async throws
        -> Dieter_V1_CreateProjectResponse
    {
        try await service.createProject(request: .init(message: request))
    }

    package func updateProject(_ request: Dieter_V1_UpdateProjectRequest) async throws
        -> Dieter_V1_Project
    {
        try await service.updateProject(request: .init(message: request))
    }

    package func updateProjectWorkspaceSettings(
        _ request: Dieter_V1_UpdateProjectWorkspaceSettingsRequest
    ) async throws
        -> Dieter_V1_Project
    {
        try await service.updateProjectWorkspaceSettings(request: .init(message: request))
    }

    package func archiveProject(_ request: Dieter_V1_ArchiveProjectRequest) async throws
        -> Dieter_V1_Project
    {
        try await service.archiveProject(request: .init(message: request))
    }

    package func archivedProjects() async throws -> Dieter_V1_ProjectsResponse {
        try await service.listArchivedProjects(
            request: .init(message: Google_Protobuf_Empty()), options: Self.boundedUnaryCallOptions())
    }

    package func createBoard(_ request: Dieter_V1_CreateBoardRequest) async throws -> Dieter_V1_Board {
        try await service.createBoard(request: .init(message: request))
    }

    package func renameBoard(_ request: Dieter_V1_RenameBoardRequest) async throws -> Dieter_V1_Board {
        try await service.renameBoard(request: .init(message: request))
    }

    package func setBoardArchivePolicy(_ request: Dieter_V1_SetBoardArchivePolicyRequest) async throws
        -> Dieter_V1_Board
    {
        try await service.setBoardArchivePolicy(request: .init(message: request))
    }

    package func updateBoardHostnames(_ request: Dieter_V1_UpdateBoardHostnamesRequest) async throws
        -> Dieter_V1_Board
    {
        try await service.updateBoardHostnames(request: .init(message: request))
    }

    package func updateBoardGitSettings(_ request: Dieter_V1_UpdateBoardGitSettingsRequest) async throws
        -> Dieter_V1_Board
    {
        try await service.updateBoardGitSettings(request: .init(message: request))
    }

    package func archivedCards(boardID: String) async throws -> Dieter_V1_CardsResponse {
        var request = Dieter_V1_BoardRef()
        request.boardID = boardID
        return try await service.listArchivedCards(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func createBoardLabel(_ request: Dieter_V1_CreateBoardLabelRequest) async throws
        -> Dieter_V1_Board
    {
        try await service.createBoardLabel(request: .init(message: request))
    }

    package func updateBoardLabel(_ request: Dieter_V1_UpdateBoardLabelRequest) async throws
        -> Dieter_V1_Board
    {
        try await service.updateBoardLabel(request: .init(message: request))
    }

    package func deleteBoardLabel(_ request: Dieter_V1_DeleteBoardLabelRequest) async throws
        -> Dieter_V1_Board
    {
        try await service.deleteBoardLabel(request: .init(message: request))
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

    package func forkChat(_ request: Dieter_V1_ForkChatRequest) async throws -> Dieter_V1_Card {
        try await service.forkChat(request: .init(message: request))
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

    package func toolOutput(_ request: Dieter_V1_GetToolOutputRequest) async throws
        -> Dieter_V1_ToolOutput
    {
        try await service.getToolOutput(
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

    package func markConversationRead(cardID: String, responseSeq: Int64) async throws -> Dieter_V1_Card {
        var request = Dieter_V1_MarkConversationReadRequest()
        request.cardID = cardID
        request.responseSeq = responseSeq
        return try await service.markConversationRead(request: .init(message: request))
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

    package func setCardLabels(_ request: Dieter_V1_SetCardLabelsRequest) async throws -> Dieter_V1_Card {
        try await service.setCardLabels(request: .init(message: request))
    }

    package func cancelCard(id: String) async throws {
        var request = Dieter_V1_GetCardRequest()
        request.cardID = id
        _ = try await service.cancelCard(request: .init(message: request)) as Google_Protobuf_Empty
    }

    package func renameCard(_ request: Dieter_V1_RenameCardRequest) async throws -> Dieter_V1_Card {
        try await service.renameCard(request: .init(message: request))
    }

    package func mergeCard(_ request: Dieter_V1_MergeCardRequest) async throws -> Dieter_V1_Card {
        try await service.mergeCard(request: .init(message: request))
    }

    package func updateCard(_ request: Dieter_V1_UpdateCardRequest) async throws -> Dieter_V1_Card {
        try await service.updateCard(request: .init(message: request))
    }

    package func archiveCard(_ request: Dieter_V1_ArchiveCardRequest) async throws -> Dieter_V1_Card {
        try await service.archiveCard(request: .init(message: request))
    }

    package func pinChat(_ request: Dieter_V1_PinChatRequest) async throws -> Dieter_V1_Card {
        try await service.pinChat(request: .init(message: request))
    }

    package func updateConversationWorkspace(_ request: Dieter_V1_UpdateConversationWorkspaceRequest)
        async throws
        -> Dieter_V1_Card
    {
        try await service.updateConversationWorkspace(request: .init(message: request))
    }

    package func workspace(cardID: String) async throws -> Dieter_V1_Workspace {
        var request = Dieter_V1_ConversationRef()
        request.cardID = cardID
        return try await service.getWorkspace(request: .init(message: request))
    }

    package func projectWorkspaces(projectID: String) async throws -> Dieter_V1_WorkspacesResponse {
        var request = Dieter_V1_ProjectRef()
        request.projectID = projectID
        request.checkoutID = checkoutID(projectID: projectID)
        return try await service.listProjectWorkspaces(request: .init(message: request))
    }

    package func changeset(cardID: String) async throws -> Dieter_V1_Changeset {
        var request = Dieter_V1_GetChangesetRequest()
        request.cardID = cardID
        return try await service.getChangeset(request: .init(message: request))
    }

    package func changeset(projectID: String) async throws -> Dieter_V1_Changeset {
        var request = Dieter_V1_GetChangesetRequest()
        request.projectID = projectID
        request.checkoutID = checkoutID(projectID: projectID)
        return try await service.getChangeset(request: .init(message: request))
    }

    package func fileDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.getFileDiff(request: .init(message: request))
    }

    package func commitDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.getCommitDiff(request: .init(message: request))
    }

    package func addChangeComment(_ request: Dieter_V1_AddChangeCommentRequest) async throws
        -> Dieter_V1_ChangeComment
    {
        try await service.addChangeComment(request: .init(message: request))
    }

    package func changeComments(cardID: String, revision: String = "") async throws
        -> Dieter_V1_ChangeCommentsResponse
    {
        var request = Dieter_V1_ListChangeCommentsRequest()
        request.cardID = cardID
        request.revision = revision
        return try await service.listChangeComments(request: .init(message: request))
    }

    package func scmCapabilities(cardID: String) async throws -> Dieter_V1_SCMCapabilities {
        var request = Dieter_V1_ConversationRef()
        request.cardID = cardID
        return try await service.getSCMCapabilities(request: .init(message: request))
    }

    package func startGitOperation(_ request: Dieter_V1_StartGitOperationRequest) async throws
        -> Dieter_V1_GitOperation
    {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.startGitOperation(request: .init(message: request))
    }

    package func gitOperation(id: String) async throws -> Dieter_V1_GitOperation {
        var request = Dieter_V1_GitOperationRef()
        request.operationID = id
        return try await service.getGitOperation(request: .init(message: request))
    }

    package func cancelGitOperation(id: String) async throws -> Dieter_V1_GitOperation {
        var request = Dieter_V1_GitOperationRef()
        request.operationID = id
        return try await service.cancelGitOperation(request: .init(message: request))
    }

    package func watchGitOperation(
        id: String,
        after sequence: UInt64,
        receive: @Sendable @escaping (Dieter_V1_GitOperationFrame) async -> Void
    ) async throws {
        var request = Dieter_V1_WatchGitOperationRequest()
        request.operationID = id
        request.afterSequence = sequence
        request.heartbeatMs = 1_000
        try await service.watchGitOperation(request: .init(message: request)) { response in
            for try await frame in response.messages {
                try Task.checkCancellation()
                await receive(frame)
            }
        }
    }

    package func listFiles(_ request: Dieter_V1_ListFilesRequest) async throws -> Dieter_V1_FileList {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.listFiles(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func readFile(_ request: Dieter_V1_ReadFileRequest) async throws -> Dieter_V1_FileDocument {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.readFile(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func saveFile(_ request: Dieter_V1_SaveFileRequest) async throws -> Dieter_V1_FileDocument {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.saveFile(request: .init(message: request))
    }

    package func createFile(_ request: Dieter_V1_CreateFileRequest) async throws
        -> Dieter_V1_FileEntry
    {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.createFile(request: .init(message: request))
    }

    package func moveFile(_ request: Dieter_V1_MoveFileRequest) async throws
        -> Dieter_V1_MoveFileResponse
    {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        return try await service.moveFile(request: .init(message: request))
    }

    package func deleteFile(_ request: Dieter_V1_DeleteFileRequest) async throws {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
        _ = try await service.deleteFile(request: .init(message: request)) as Google_Protobuf_Empty
    }

    package func terminals(projectID: String = "", cardID: String = "") async throws
        -> Dieter_V1_TerminalsResponse
    {
        var request = Dieter_V1_ListTerminalsRequest()
        request.projectID = projectID
        request.checkoutID = checkoutID(projectID: projectID)
        request.cardID = cardID
        return try await service.listTerminals(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func createTerminal(_ request: Dieter_V1_CreateTerminalRequest) async throws
        -> Dieter_V1_Terminal
    {
        var request = request
        if request.checkoutID.isEmpty {
            request.checkoutID = checkoutID(projectID: request.projectID, cardID: request.cardID)
        }
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

    package func schedule(id: String) async throws -> Dieter_V1_Schedule {
        var request = Dieter_V1_ScheduleRef(); request.scheduleID = id
        return try await service.getSchedule(request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func schedules(projectID: String, pageSize: Int32 = 50, pageToken: String = "")
        async throws
        -> Dieter_V1_SchedulesResponse
    {
        var request = Dieter_V1_ListSchedulesRequest()
        request.projectID = projectID
        request.pageSize = pageSize
        request.pageToken = pageToken
        return try await service.listSchedules(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func previewSchedule(_ request: Dieter_V1_PreviewScheduleRequest) async throws
        -> Dieter_V1_SchedulePreview
    {
        try await service.previewSchedule(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }

    package func createSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws
        -> Dieter_V1_Schedule
    {
        try await service.createSchedule(request: .init(message: request))
    }

    package func updateSchedule(_ request: Dieter_V1_SaveScheduleRequest) async throws
        -> Dieter_V1_Schedule
    {
        try await service.updateSchedule(request: .init(message: request))
    }

    package func deleteSchedule(id: String) async throws {
        var request = Dieter_V1_ScheduleRef()
        request.scheduleID = id
        _ = try await service.deleteSchedule(request: .init(message: request)) as Google_Protobuf_Empty
    }

    package func runSchedule(id: String) async throws -> Dieter_V1_ScheduleRun {
        var request = Dieter_V1_ScheduleRef()
        request.scheduleID = id
        return try await service.runSchedule(request: .init(message: request))
    }

    package func setScheduleEnabled(id: String, enabled: Bool) async throws -> Dieter_V1_Schedule {
        var request = Dieter_V1_SetScheduleEnabledRequest()
        request.scheduleID = id
        request.enabled = enabled
        return try await service.setScheduleEnabled(request: .init(message: request))
    }

    package func scheduleRuns(id: String, pageSize: Int32 = 50, pageToken: String = "") async throws
        -> Dieter_V1_ScheduleRunsResponse
    {
        var request = Dieter_V1_ListScheduleRunsRequest()
        request.scheduleID = id
        request.pageSize = pageSize
        request.pageToken = pageToken
        return try await service.listScheduleRuns(
            request: .init(message: request), options: Self.boundedUnaryCallOptions())
    }
}

extension DieterRPC: DieterScheduleRPC, DieterChatPinRPC, DieterCardStartRPC {}

package enum DieterTransportTarget {
    package enum HostKind: Equatable {
        case ipv4
        case ipv6
        case dns
    }

    package static func hostKind(_ host: String) -> HostKind {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return .ipv4
        }

        // A scoped IPv6 address (for example, fe80::1%en0) is still a literal
        // address. inet_pton validates the address portion while the resolver
        // receives the original value including its interface scope.
        let ipv6Host =
            host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(
                String.init) ?? host
        var ipv6 = in6_addr()
        if ipv6Host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return .ipv6
        }

        return .dns
    }

    package static func make(host: String, port: Int) -> any ResolvableTarget {
        switch hostKind(host) {
        case .ipv4:
            ResolvableTargets.IPv4(addresses: [.init(host: host, port: port)])
        case .ipv6:
            ResolvableTargets.IPv6(addresses: [.init(host: host, port: port)])
        case .dns:
            ResolvableTargets.DNS(host: host, port: port)
        }
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
