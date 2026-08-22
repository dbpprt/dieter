import NauclioAPI
import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Security
import SwiftProtobuf

/// One long-lived native HTTP/2 gRPC channel to the loopback Nauclio server.
final class NauclioRPC: Sendable {
    typealias Transport = HTTP2ClientTransport.Posix
    typealias Service = Nauclio_V1_NauclioService.Client<Transport>
    typealias GatewayService = Nauclio_Gateway_V1_GatewayService.Client<Transport>

    let endpoint: NauclioEndpoint
    let core: GRPCClient<Transport>
    let service: Service
    let gatewayService: GatewayService

    private static func attachmentCallOptions() -> CallOptions {
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = 16 * 1_024 * 1_024
        options.maxResponseMessageBytes = 16 * 1_024 * 1_024
        return options
    }

    struct DirectRoute: Sendable {
        let host: String
        let port: Int
        let daemonID: String
        let daemonCAPEM: Data
        let accessToken: String
    }

    enum Route: Equatable, Sendable {
        case gateway
        case relay(daemonID: String)

        var daemonID: String? {
            if case let .relay(daemonID) = self { return daemonID }
            return nil
        }
    }

    init(
        endpoint: NauclioEndpoint,
        accessToken: String? = nil,
        route: Route = .gateway,
        direct: DirectRoute? = nil
    ) throws {
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
            target: NauclioTransportTarget.make(host: host, port: port),
            transportSecurity: security
        )
        let token = direct?.accessToken ?? accessToken
        let daemonID = direct == nil ? route.daemonID : nil
        let interceptors: [any ClientInterceptor] = token.map { [BearerInterceptor(token: $0, daemonID: daemonID)] } ?? []
        let core = GRPCClient(transport: transport, interceptors: interceptors)
        self.core = core
        self.service = Service(wrapping: core)
        self.gatewayService = GatewayService(wrapping: core)
    }

    static func verifyDaemonCertificateChain(
        _ derChain: [Data],
        daemonCAPEM: Data,
        daemonID: String
    ) -> Bool {
        guard let leafData = derChain.first,
              let leaf = SecCertificateCreateWithData(nil, leafData as CFData),
              let caDER = pemCertificateDER(daemonCAPEM),
              let ca = SecCertificateCreateWithData(nil, caDER as CFData) else { return false }
        let chain = derChain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard chain.count == derChain.count else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, [ca] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { return false }
        guard let values = SecCertificateCopyValues(leaf, [kSecOIDSubjectAltName] as CFArray, nil) as? [CFString: Any],
              let subjectAlternativeName = values[kSecOIDSubjectAltName] else { return false }
        return containsCertificateValue("spiffe://board/daemon/\(daemonID)", in: subjectAlternativeName)
    }

    private static func pemCertificateDER(_ pem: Data) -> Data? {
        guard let value = String(data: pem, encoding: .utf8) else { return nil }
        let body = value
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: body)
    }

    private static func containsCertificateValue(_ expected: String, in value: Any) -> Bool {
        if let text = value as? String { return text == expected }
        if let url = value as? URL { return url.absoluteString == expected }
        if let url = value as? NSURL { return url.absoluteString == expected }
        if let values = value as? [Any] { return values.contains { containsCertificateValue(expected, in: $0) } }
        if let values = value as? [CFString: Any] { return values.values.contains { containsCertificateValue(expected, in: $0) } }
        if let values = value as? [String: Any] { return values.values.contains { containsCertificateValue(expected, in: $0) } }
        return false
    }

    func run() async throws {
        try await core.runConnections()
    }

    func shutdown() {
        core.beginGracefulShutdown()
    }

    func daemons() async throws -> Nauclio_Gateway_V1_ListDaemonsResponse {
        try await gatewayService.listDaemons(request: .init(message: Google_Protobuf_Empty()))
    }

    func route(daemonID: String) async throws -> Nauclio_Gateway_V1_DaemonRoute {
        var request = Nauclio_Gateway_V1_DaemonRef(); request.daemonID = daemonID
        return try await gatewayService.resolveDaemonRoute(request: .init(message: request))
    }

    func daemonAccessToken(daemonID: String) async throws -> Nauclio_Gateway_V1_DaemonAccessToken {
        var request = Nauclio_Gateway_V1_ExchangeDaemonTokenRequest(); request.daemonID = daemonID
        return try await gatewayService.exchangeDaemonToken(request: .init(message: request))
    }

    func revokeDaemon(daemonID: String) async throws {
        var request = Nauclio_Gateway_V1_DaemonRef(); request.daemonID = daemonID
        _ = try await gatewayService.revokeDaemon(request: .init(message: request)) as Google_Protobuf_Empty
    }

    func renameDaemon(daemonID: String, name: String) async throws -> Nauclio_Gateway_V1_Daemon {
        var request = Nauclio_Gateway_V1_RenameDaemonRequest(); request.daemonID = daemonID; request.name = name
        return try await gatewayService.renameDaemon(request: .init(message: request))
    }

    func health(timeout: Duration? = nil) async throws -> Nauclio_V1_HealthResponse {
        var options = CallOptions.defaults; options.timeout = timeout
        return try await service.health(request: .init(message: Google_Protobuf_Empty()), options: options)
    }

    func runtimeStatus() async throws -> Nauclio_V1_RuntimeStatus {
        try await service.getRuntimeStatus(request: .init(message: Google_Protobuf_Empty()))
    }

    func promptSettings() async throws -> Nauclio_V1_PromptSettings {
        try await service.getPromptSettings(request: .init(message: Google_Protobuf_Empty()))
    }

    func updatePromptSettings(_ request: Nauclio_V1_UpdatePromptSettingsRequest) async throws -> Nauclio_V1_PromptSettings {
        try await service.updatePromptSettings(request: .init(message: request))
    }

    func setProjectPromptTemplate(_ request: Nauclio_V1_SetScopedPromptTemplateRequest) async throws -> Nauclio_V1_Project {
        try await service.setProjectPromptTemplate(request: .init(message: request))
    }

    func setBoardPromptTemplate(_ request: Nauclio_V1_SetScopedPromptTemplateRequest) async throws -> Nauclio_V1_Board {
        try await service.setBoardPromptTemplate(request: .init(message: request))
    }

    func previewPrompt(_ request: Nauclio_V1_PreviewPromptRequest) async throws -> Nauclio_V1_PromptPreview {
        try await service.previewPrompt(request: .init(message: request))
    }

    func state(_ request: Nauclio_V1_GetStateRequest = .init()) async throws -> Nauclio_V1_State {
        try await service.getState(request: .init(message: request))
    }

    func watchState(
        _ request: Nauclio_V1_WatchStateRequest,
        receive: @Sendable @escaping (Nauclio_V1_State) async -> Void
    ) async throws {
        try await service.watchState(request: .init(message: request)) { response in
            for try await state in response.messages {
                try Task.checkCancellation()
                await receive(state)
            }
        }
    }

    func watchSync(
        _ request: Nauclio_V1_SyncRequest,
        receive: @Sendable @escaping (Nauclio_V1_SyncFrame) async -> Void
    ) async throws {
        try await service.watchSync(request: .init(message: request), options: Self.attachmentCallOptions()) { response in
            for try await frame in response.messages {
                try Task.checkCancellation()
                await receive(frame)
            }
        }
    }

    func harnesses() async throws -> Nauclio_V1_HarnessCatalog {
        try await service.getHarnesses(request: .init(message: Google_Protobuf_Empty()))
    }

    func settings() async throws -> Nauclio_V1_Settings {
        try await service.getSettings(request: .init(message: Google_Protobuf_Empty()))
    }

    func settingsOptions() async throws -> Nauclio_V1_SettingsOptions {
        try await service.getSettingsOptions(request: .init(message: Google_Protobuf_Empty()))
    }

    func updateSettings(_ request: Nauclio_V1_UpdateSettingsRequest) async throws -> Nauclio_V1_Settings {
        try await service.updateSettings(request: .init(message: request))
    }

    func listDirectories(_ request: Nauclio_V1_ListDirectoriesRequest) async throws -> Nauclio_V1_DirectoryListing {
        try await service.listDirectories(request: .init(message: request))
    }

    func createProject(_ request: Nauclio_V1_CreateProjectRequest) async throws -> Nauclio_V1_CreateProjectResponse {
        try await service.createProject(request: .init(message: request))
    }

    func updateProject(_ request: Nauclio_V1_UpdateProjectRequest) async throws -> Nauclio_V1_Project {
        try await service.updateProject(request: .init(message: request))
    }

    func archiveProject(_ request: Nauclio_V1_ArchiveProjectRequest) async throws -> Nauclio_V1_Project {
        try await service.archiveProject(request: .init(message: request))
    }

    func archivedProjects() async throws -> Nauclio_V1_ProjectsResponse {
        try await service.listArchivedProjects(request: .init(message: Google_Protobuf_Empty()))
    }

    func createBoard(_ request: Nauclio_V1_CreateBoardRequest) async throws -> Nauclio_V1_Board {
        try await service.createBoard(request: .init(message: request))
    }

    func renameBoard(_ request: Nauclio_V1_RenameBoardRequest) async throws -> Nauclio_V1_Board {
        try await service.renameBoard(request: .init(message: request))
    }

    func setBoardArchivePolicy(_ request: Nauclio_V1_SetBoardArchivePolicyRequest) async throws -> Nauclio_V1_Board {
        try await service.setBoardArchivePolicy(request: .init(message: request))
    }

    func archivedCards(boardID: String) async throws -> Nauclio_V1_CardsResponse {
        var request = Nauclio_V1_BoardRef(); request.boardID = boardID
        return try await service.listArchivedCards(request: .init(message: request))
    }

    func createBoardLabel(_ request: Nauclio_V1_CreateBoardLabelRequest) async throws -> Nauclio_V1_Board {
        try await service.createBoardLabel(request: .init(message: request))
    }

    func updateBoardLabel(_ request: Nauclio_V1_UpdateBoardLabelRequest) async throws -> Nauclio_V1_Board {
        try await service.updateBoardLabel(request: .init(message: request))
    }

    func deleteBoardLabel(_ request: Nauclio_V1_DeleteBoardLabelRequest) async throws -> Nauclio_V1_Board {
        try await service.deleteBoardLabel(request: .init(message: request))
    }

    func createCard(_ request: Nauclio_V1_CreateConversationRequest) async throws -> Nauclio_V1_Card {
        try await service.createCard(request: .init(message: request), options: Self.attachmentCallOptions())
    }

    func createChat(_ request: Nauclio_V1_CreateConversationRequest) async throws -> Nauclio_V1_Card {
        try await service.createChat(request: .init(message: request), options: Self.attachmentCallOptions())
    }

    func chats(includeArchived: Bool = false) async throws -> Nauclio_V1_ChatsResponse {
        var request = Nauclio_V1_ListChatsRequest(); request.includeArchived = includeArchived
        return try await service.listChats(request: .init(message: request))
    }

    func card(id: String) async throws -> Nauclio_V1_CardDetail {
        var request = Nauclio_V1_GetCardRequest(); request.cardID = id
        return try await service.getCard(request: .init(message: request))
    }

    func conversation(cardID: String, limit: Int32 = 30, before: Int32? = nil) async throws -> Nauclio_V1_ConversationSnapshot {
        var request = Nauclio_V1_GetConversationRequest(); request.cardID = cardID; request.limit = limit
        if let before { request.before = before }
        return try await service.getConversation(request: .init(message: request), options: Self.attachmentCallOptions())
    }

    func watchConversation(
        cardID: String,
        after sequence: Int64,
        receive: @Sendable @escaping (Nauclio_V1_ConversationUpdate) async -> Void
    ) async throws {
        var request = Nauclio_V1_WatchConversationRequest()
        request.cardID = cardID; request.limit = 30; request.intervalMs = 700; request.afterSeq = sequence
        try await service.watchConversation(request: .init(message: request), options: Self.attachmentCallOptions()) { response in
            for try await update in response.messages {
                try Task.checkCancellation()
                await receive(update)
            }
        }
    }

    func toolOutput(_ request: Nauclio_V1_GetToolOutputRequest) async throws -> Nauclio_V1_ToolOutput {
        try await service.getToolOutput(request: .init(message: request))
    }

    func sendMessage(_ request: Nauclio_V1_SendMessageRequest) async throws -> Nauclio_V1_SendMessageResponse {
        try await service.sendMessage(request: .init(message: request), options: Self.attachmentCallOptions())
    }

    func addComment(_ request: Nauclio_V1_AddCommentRequest) async throws -> Nauclio_V1_Comment {
        try await service.addComment(request: .init(message: request))
    }

    func moveCard(_ request: Nauclio_V1_MoveCardRequest) async throws -> Nauclio_V1_Card {
        try await service.moveCard(request: .init(message: request))
    }

    func setCardLabels(_ request: Nauclio_V1_SetCardLabelsRequest) async throws -> Nauclio_V1_Card {
        try await service.setCardLabels(request: .init(message: request))
    }

    func cancelCard(id: String) async throws {
        var request = Nauclio_V1_GetCardRequest(); request.cardID = id
        _ = try await service.cancelCard(request: .init(message: request)) as Google_Protobuf_Empty
    }

    func renameCard(_ request: Nauclio_V1_RenameCardRequest) async throws -> Nauclio_V1_Card {
        try await service.renameCard(request: .init(message: request))
    }

    func archiveCard(_ request: Nauclio_V1_ArchiveCardRequest) async throws -> Nauclio_V1_Card {
        try await service.archiveCard(request: .init(message: request))
    }

    func pinChat(_ request: Nauclio_V1_PinChatRequest) async throws -> Nauclio_V1_Card {
        try await service.pinChat(request: .init(message: request))
    }

    func listFiles(_ request: Nauclio_V1_ListFilesRequest) async throws -> Nauclio_V1_FileList {
        try await service.listFiles(request: .init(message: request))
    }

    func readFile(_ request: Nauclio_V1_ReadFileRequest) async throws -> Nauclio_V1_FileDocument {
        try await service.readFile(request: .init(message: request))
    }

    func saveFile(_ request: Nauclio_V1_SaveFileRequest) async throws -> Nauclio_V1_FileDocument {
        try await service.saveFile(request: .init(message: request))
    }

    func createFile(_ request: Nauclio_V1_CreateFileRequest) async throws -> Nauclio_V1_FileEntry {
        try await service.createFile(request: .init(message: request))
    }

    func moveFile(_ request: Nauclio_V1_MoveFileRequest) async throws -> Nauclio_V1_MoveFileResponse {
        try await service.moveFile(request: .init(message: request))
    }

    func deleteFile(_ request: Nauclio_V1_DeleteFileRequest) async throws {
        _ = try await service.deleteFile(request: .init(message: request)) as Google_Protobuf_Empty
    }

    func terminals(projectID: String = "") async throws -> Nauclio_V1_TerminalsResponse {
        var request = Nauclio_V1_ListTerminalsRequest(); request.projectID = projectID
        return try await service.listTerminals(request: .init(message: request))
    }

    func createTerminal(_ request: Nauclio_V1_CreateTerminalRequest) async throws -> Nauclio_V1_Terminal {
        try await service.createTerminal(request: .init(message: request))
    }

    func watchTerminal(
        id: String,
        after sequence: UInt64,
        receive: @Sendable @escaping (Nauclio_V1_TerminalFrame) async -> Void
    ) async throws {
        var request = Nauclio_V1_WatchTerminalRequest()
        request.terminalID = id; request.afterSequence = sequence; request.heartbeatMs = 15_000
        try await service.watchTerminal(request: .init(message: request), options: Self.attachmentCallOptions()) { response in
            for try await frame in response.messages {
                try Task.checkCancellation()
                await receive(frame)
            }
        }
    }

    func writeTerminal(id: String, data: Data) async throws -> Nauclio_V1_Terminal {
        var request = Nauclio_V1_TerminalInputRequest(); request.terminalID = id; request.data = data
        return try await service.writeTerminal(request: .init(message: request))
    }

    func resizeTerminal(id: String, columns: Int, rows: Int) async throws -> Nauclio_V1_Terminal {
        var request = Nauclio_V1_ResizeTerminalRequest()
        request.terminalID = id; request.columns = Int32(columns); request.rows = Int32(rows)
        return try await service.resizeTerminal(request: .init(message: request))
    }

    func renameTerminal(id: String, name: String) async throws -> Nauclio_V1_Terminal {
        var request = Nauclio_V1_RenameTerminalRequest(); request.terminalID = id; request.name = name
        return try await service.renameTerminal(request: .init(message: request))
    }

    func closeTerminal(id: String) async throws {
        var request = Nauclio_V1_TerminalRef(); request.terminalID = id
        _ = try await service.closeTerminal(request: .init(message: request)) as Google_Protobuf_Empty
    }

    func schedules(projectID: String) async throws -> Nauclio_V1_SchedulesResponse {
        var request = Nauclio_V1_ListSchedulesRequest(); request.projectID = projectID
        return try await service.listSchedules(request: .init(message: request))
    }

    func previewSchedule(_ request: Nauclio_V1_PreviewScheduleRequest) async throws -> Nauclio_V1_SchedulePreview {
        try await service.previewSchedule(request: .init(message: request))
    }

    func createSchedule(_ request: Nauclio_V1_SaveScheduleRequest) async throws -> Nauclio_V1_Schedule {
        try await service.createSchedule(request: .init(message: request))
    }

    func updateSchedule(_ request: Nauclio_V1_SaveScheduleRequest) async throws -> Nauclio_V1_Schedule {
        try await service.updateSchedule(request: .init(message: request))
    }

    func deleteSchedule(id: String) async throws {
        var request = Nauclio_V1_ScheduleRef(); request.scheduleID = id
        _ = try await service.deleteSchedule(request: .init(message: request)) as Google_Protobuf_Empty
    }

    func runSchedule(id: String) async throws -> Nauclio_V1_ScheduleRun {
        var request = Nauclio_V1_ScheduleRef(); request.scheduleID = id
        return try await service.runSchedule(request: .init(message: request))
    }

    func setScheduleEnabled(id: String, enabled: Bool) async throws -> Nauclio_V1_Schedule {
        var request = Nauclio_V1_SetScheduleEnabledRequest(); request.scheduleID = id; request.enabled = enabled
        return try await service.setScheduleEnabled(request: .init(message: request))
    }

    func scheduleRuns(id: String, limit: Int32 = 50) async throws -> Nauclio_V1_ScheduleRunsResponse {
        var request = Nauclio_V1_ListScheduleRunsRequest(); request.scheduleID = id; request.limit = limit
        return try await service.listScheduleRuns(request: .init(message: request))
    }
}

enum NauclioTransportTarget {
    enum HostKind: Equatable {
        case ipv4
        case ipv6
        case dns
    }

    static func hostKind(_ host: String) -> HostKind {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return .ipv4
        }

        // A scoped IPv6 address (for example, fe80::1%en0) is still a literal
        // address. inet_pton validates the address portion while the resolver
        // receives the original value including its interface scope.
        let ipv6Host = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        var ipv6 = in6_addr()
        if ipv6Host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return .ipv6
        }

        return .dns
    }

    static func make(host: String, port: Int) -> any ResolvableTarget {
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

private struct BearerInterceptor: ClientInterceptor {
    let token: String
    let daemonID: String?
    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>, context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.addString("Bearer \(token)", forKey: "authorization")
        if let daemonID { request.metadata.addString(daemonID, forKey: "x-nauclio-daemon-id") }
        return try await next(request, context)
    }
}
