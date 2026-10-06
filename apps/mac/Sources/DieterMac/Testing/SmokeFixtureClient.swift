#if DIETER_UI_SMOKE
    import DieterAPI
    import DieterTransport
    import Foundation
    import GRPCCore
    import GRPCNIOTransportHTTP2
    import GRPCProtobuf
    import SwiftProtobuf

    /// UI smoke fixtures and native screen tests prepare and inspect an
    /// isolated machine directly (start a process, create a card, read a file
    /// back): host-side work the app leaves to the shared core. A plain gRPC
    /// client to a daemon, either through a gateway's relay or at a fixture's
    /// own address. Debug builds only; the app never uses it.
    final class SmokeFixtureClient: Sendable {
        typealias Transport = HTTP2ClientTransport.Posix
        private let client: GRPCClient<Transport>
        let service: Dieter_V1_DieterService.Client<Transport>
        private let running: Task<Void, Never>

        /// Connects to `origin` (`http[s]://host:port`) with `token`; with a
        /// `daemonID`, the gateway at `origin` relays to that machine.
        init(origin: String, token: String?, daemonID: String? = nil) throws {
            guard let url = URL(string: origin), let host = url.host(percentEncoded: false), let port = url.port
            else { throw RPCError(code: .invalidArgument, message: "Invalid fixture address \(origin)") }
            let transport = try HTTP2ClientTransport.Posix(
                target: DieterTransportTarget.make(host: host, port: port),
                transportSecurity: url.scheme == "https" ? .tls : .plaintext)
            client = GRPCClient(
                transport: transport, interceptors: [FixtureMetadata(token: token, daemonID: daemonID)])
            service = Dieter_V1_DieterService.Client(wrapping: client)
            running = Task { [client] in try? await client.runConnections() }
        }

        deinit { shutdown() }

        func shutdown() {
            client.beginGracefulShutdown()
            running.cancel()
        }

        private static var bounded: CallOptions {
            var options = CallOptions.defaults
            options.timeout = .seconds(15)
            options.maxRequestMessageBytes = 16 * 1_024 * 1_024
            options.maxResponseMessageBytes = 16 * 1_024 * 1_024
            return options
        }

        // MARK: Workspace

        func archivedCards(boardID: String) async throws -> Dieter_V1_CardsResponse {
            try await service.listArchivedCards(
                request: .init(message: .with { $0.boardID = boardID }), options: Self.bounded)
        }

        func chats(includeArchived: Bool = false) async throws -> Dieter_V1_ChatsResponse {
            try await service.listChats(
                request: .init(message: .with { $0.includeArchived = includeArchived }), options: Self.bounded)
        }

        func createCard(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
            try await service.createCard(request: .init(message: request), options: Self.bounded)
        }

        func renameCard(cardID: String, title: String) async throws -> Dieter_V1_Card {
            try await service.renameCard(
                request: .init(
                    message: .with {
                        $0.cardID = cardID; $0.title = title
                    }), options: Self.bounded)
        }

        func markConversationRead(cardID: String, responseSeq: Int64) async throws -> Dieter_V1_Card {
            try await service.markConversationRead(
                request: .init(
                    message: .with {
                        $0.cardID = cardID; $0.responseSeq = responseSeq
                    }), options: Self.bounded)
        }

        func archiveCard(cardID: String) async throws -> Dieter_V1_Card {
            try await service.archiveCard(
                request: .init(
                    message: .with {
                        $0.cardID = cardID; $0.archived = true
                    }), options: Self.bounded)
        }

        func workspace(cardID: String) async throws -> Dieter_V1_Workspace {
            try await service.getWorkspace(request: .init(message: .with { $0.cardID = cardID }), options: Self.bounded)
        }

        func changeset(projectID: String) async throws -> Dieter_V1_Changeset {
            try await service.getChangeset(
                request: .init(message: .with { $0.projectID = projectID }), options: Self.bounded)
        }

        func presentConversationContent(
            _ request: Dieter_V1_PresentConversationContentRequest
        ) async throws -> Dieter_V1_ContentPresentation {
            try await service.presentConversationContent(request: .init(message: request), options: Self.bounded)
        }

        // MARK: Files

        func readFile(_ request: Dieter_V1_ReadFileRequest) async throws -> Dieter_V1_FileDocument {
            try await service.readFile(request: .init(message: request), options: Self.bounded)
        }

        func saveFile(_ request: Dieter_V1_SaveFileRequest) async throws -> Dieter_V1_FileDocument {
            try await service.saveFile(request: .init(message: request), options: Self.bounded)
        }

        func createFile(_ request: Dieter_V1_CreateFileRequest) async throws -> Dieter_V1_FileEntry {
            try await service.createFile(request: .init(message: request), options: Self.bounded)
        }

        // MARK: Terminals and executions

        func terminals(projectID: String = "", cardID: String = "") async throws -> Dieter_V1_TerminalsResponse {
            try await service.listTerminals(
                request: .init(
                    message: .with {
                        $0.projectID = projectID
                        $0.cardID = cardID
                    }), options: Self.bounded)
        }

        func closeTerminal(id: String) async throws {
            _ =
                try await service.closeTerminal(
                    request: .init(message: .with { $0.terminalID = id }), options: Self.bounded)
                as Google_Protobuf_Empty
        }

        func startExecution(_ request: Dieter_V1_StartExecutionRequest) async throws -> Dieter_V1_Execution {
            try await service.startExecution(request: .init(message: request), options: Self.bounded)
        }

        func executions(projectID: String, cardID: String) async throws -> Dieter_V1_ExecutionsResponse {
            try await service.listExecutions(
                request: .init(
                    message: .with {
                        $0.projectID = projectID
                        $0.cardID = cardID
                    }), options: Self.bounded)
        }

        func cancelExecution(id: String) async throws -> Dieter_V1_Execution {
            try await service.cancelExecution(
                request: .init(message: .with { $0.executionID = id }), options: Self.bounded)
        }

        // MARK: Screens

        func remoteDesktopCapabilities() async throws -> Dieter_V1_RemoteDesktopCapabilities {
            try await service.getRemoteDesktopCapabilities(
                request: .init(message: Google_Protobuf_Empty()), options: Self.bounded)
        }

        func remoteDesktopSessions() async throws -> Dieter_V1_RemoteDesktopSessions {
            try await service.listRemoteDesktopSessions(
                request: .init(message: Google_Protobuf_Empty()), options: Self.bounded)
        }

        func remoteDesktopDisplayModes(sessionID: String) async throws -> Dieter_V1_RemoteDesktopDisplayModes {
            try await service.listRemoteDesktopDisplayModes(
                request: .init(message: .with { $0.sessionID = sessionID }), options: Self.bounded)
        }

        /// Streams the session's signals to `receive` until the host closes it.
        func startRemoteDesktop(
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

        func closeRemoteDesktop(sessionID: String) async throws {
            _ =
                try await service.closeRemoteDesktop(
                    request: .init(message: .with { $0.sessionID = sessionID }), options: Self.bounded)
                as Google_Protobuf_Empty
        }
    }

    /// The bearer token, relayed daemon, and client release every Dieter RPC carries.
    private struct FixtureMetadata: ClientInterceptor {
        let token: String?
        let daemonID: String?

        func intercept<Input: Sendable, Output: Sendable>(
            request: StreamingClientRequest<Input>, context: ClientContext,
            next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
        ) async throws -> StreamingClientResponse<Output> {
            var request = request
            request.metadata.addString(DieterRelease.current, forKey: "x-dieter-client-version")
            if let token { request.metadata.addString("Bearer \(token)", forKey: "authorization") }
            if let daemonID { request.metadata.addString(daemonID, forKey: "x-dieter-daemon-id") }
            return try await next(request, context)
        }
    }

    /// One relayed fixture client for the fixture's machine, the first that
    /// can take work, opened on demand and replaced when that machine changes.
    @MainActor final class SmokeFixturePlane {
        static let shared = SmokeFixturePlane()
        private var plane: (machineID: String, client: SmokeFixtureClient)?

        func client(for store: DieterStore) -> SmokeFixtureClient? {
            guard store.phase.isConnected, let machine = store.machines.first(where: store.machineIsAvailable),
                let daemonID = machine.daemonID
            else { return nil }
            if let plane, plane.machineID == machine.id { return plane.client }
            plane?.client.shutdown()
            plane = nil
            let gateway = store.activeGateway
            guard let token = store.accessToken(for: gateway),
                let client = try? SmokeFixtureClient(origin: gateway.address, token: token, daemonID: daemonID)
            else { return nil }
            plane = (machine.id, client)
            return client
        }
    }

    extension DieterStore {
        /// A client to the fixture's machine; see `SmokeFixtureClient`.
        func fixtureRPC() async -> SmokeFixtureClient? { SmokeFixturePlane.shared.client(for: self) }

        /// The launch's `--dieter-access-token-file` session, else the one the
        /// shared core stored for this gateway origin.
        func accessToken(for endpoint: MachineEndpoint) -> String? {
            accessTokenOverride
                ?? CoreFileSecureStore(fileURL: environment.credentialsFile).read(key: endpoint.credentialID)
        }
    }
#endif
