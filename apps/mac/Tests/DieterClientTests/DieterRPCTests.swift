import DieterAPI
import DieterClient
import DieterCore
import Foundation
import GRPCCore
import Testing

@Test func unreachableEndpointSurvivesConnectionBackoffAndShutdown() async throws {
    let endpoint = try #require(DieterEndpoint.parse("127.0.0.1:1"))
    let client = try DieterRPC(endpoint: endpoint)
    let connection = Task {
        try? await client.run()
    }

    do {
        _ = try await client.health(timeout: .milliseconds(250))
        Issue.record("A closed loopback port unexpectedly accepted the health RPC")
    } catch {
        // The expected failure moves the transport into its connection-backoff path.
    }

    try await Task.sleep(nanoseconds: 2_000_000_000)
    connection.cancel()
    client.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_LIVE_DIRECT_PORT"] != nil))
func liveDirectRouteCompletesTLSAndReachesDaemonAuthentication() async throws {
    struct StoredIdentity: Decodable {
        let id: String
        let certificatePem: Data
        let daemonCaPem: Data
    }

    let port = try #require(Int(ProcessInfo.processInfo.environment["DIETER_LIVE_DIRECT_PORT"] ?? ""))
    let identityURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dieter/daemon/identity.json")
    let identity = try JSONDecoder().decode(StoredIdentity.self, from: Data(contentsOf: identityURL))
    let certificateBody = try #require(String(data: identity.certificatePem, encoding: .utf8))
        .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
        .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
        .components(separatedBy: .whitespacesAndNewlines)
        .joined()
    let certificateDER = try #require(Data(base64Encoded: certificateBody))
    #expect(
        DaemonCertificatePinning.verify(
            [certificateDER],
            daemonCAPEM: identity.daemonCaPem,
            daemonID: identity.id
        ))
    let endpoint = DieterEndpoint(name: "Live direct route", host: "127.0.0.1", port: port, daemonID: identity.id)
    let client = try DieterRPC(
        endpoint: endpoint,
        direct: .init(
            host: endpoint.host,
            port: endpoint.port,
            daemonID: identity.id,
            daemonCAPEM: identity.daemonCaPem,
            accessToken: "deliberately-invalid-test-token"
        )
    )
    let connection = Task { try? await client.run() }
    defer {
        connection.cancel()
        client.shutdown()
    }

    do {
        _ = try await client.health(timeout: .seconds(2))
        Issue.record("The daemon unexpectedly accepted an invalid direct-route token")
    } catch let error as RPCError {
        // Unauthenticated is the direct daemon's application-level response.
        // Reaching it proves IP target selection, TLS, CA validation, HTTP/2,
        // and gRPC framing all completed successfully.
        #expect(error.code == .unauthenticated)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_LIVE_DIRECT_PORT"] != nil))
func liveDirectRouteRejectsTheWrongDaemonIdentity() async throws {
    struct StoredIdentity: Decodable {
        let id: String
        let daemonCaPem: Data
    }

    let port = try #require(Int(ProcessInfo.processInfo.environment["DIETER_LIVE_DIRECT_PORT"] ?? ""))
    let identityURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dieter/daemon/identity.json")
    let identity = try JSONDecoder().decode(StoredIdentity.self, from: Data(contentsOf: identityURL))
    let endpoint = DieterEndpoint(name: "Wrong identity", host: "127.0.0.1", port: port, daemonID: "wrong-daemon")
    let client = try DieterRPC(
        endpoint: endpoint,
        direct: .init(
            host: endpoint.host,
            port: endpoint.port,
            daemonID: "wrong-daemon",
            daemonCAPEM: identity.daemonCaPem,
            accessToken: "deliberately-invalid-test-token"
        )
    )
    let connection = Task { try? await client.run() }
    defer {
        connection.cancel()
        client.shutdown()
    }

    do {
        _ = try await client.health(timeout: .seconds(2))
        Issue.record("A direct route accepted a certificate for another daemon")
    } catch let error as RPCError {
        #expect(error.code != .unauthenticated)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_LIVE_ATTACHMENT_PORT"] != nil))
func liveAttachmentDraftRoundTripsThroughTheLocalDaemon() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["DIETER_LIVE_ATTACHMENT_PORT"] ?? ""))
    let endpoint = try #require(DieterEndpoint.parse("127.0.0.1:\(port)", name: "Attachment fixture"))
    let client = try DieterRPC(endpoint: endpoint)
    let connection = Task { try? await client.run() }
    defer {
        connection.cancel()
        client.shutdown()
    }

    let state = try await client.state()
    let board = try #require(state.boards.first { board in board.lanes.contains { $0.id == "todo" } })
    let catalog = try await client.harnesses()
    let harness = try #require(catalog.harnesses.first)
    var attachment = Dieter_V1_MessagePart()
    attachment.type = "image"
    attachment.mediaType = "image/png"
    attachment.filename = "fixture.png"
    attachment.data = Data("mac attachment fixture".utf8)
    var request = Dieter_V1_CreateConversationRequest()
    request.projectID = board.projectID
    request.boardID = board.id
    request.lane = "todo"
    request.title = "Attachment transport fixture"
    request.prompt = "Keep this deferred and verify its attachment."
    request.provider = harness.id
    request.model = harness.defaultModel
    request.deferStart = true
    request.attachments = [attachment]

    var created: Dieter_V1_Card?
    do {
        let card = try await client.createCard(request)
        created = card
        let snapshot = try await client.conversation(cardID: card.id)
        let stored = try #require(snapshot.conversation.draftAttachments.first)
        #expect(stored.filename == "fixture.png")
        #expect(stored.mediaType == "image/png")
        #expect(stored.data == Data("mac attachment fixture".utf8))
        var archive = Dieter_V1_ArchiveCardRequest()
        archive.cardID = card.id
        archive.archived = true
        _ = try await client.archiveCard(archive)
        created = nil
    } catch {
        if let created {
            var archive = Dieter_V1_ArchiveCardRequest()
            archive.cardID = created.id
            archive.archived = true
            _ = try? await client.archiveCard(archive)
        }
        throw error
    }
}

@Test func relayRoutesCarryTheirDaemon() {
    #expect(DieterRPC.Route.gateway.daemonID == nil)
    #expect(DieterRPC.Route.relay(daemonID: "daemon-1").daemonID == "daemon-1")
}
