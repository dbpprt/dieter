import Testing
import DieterAPI
import AppKit
import CryptoKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
@testable import DieterMac

@Test func remoteDesktopBindingMessageMatchesDaemonWireFormat() {
    let message = RemoteDesktopSessionTrust.bindingMessage(
        sessionID: "rd_one",
        nonce: "nonce",
        fingerprint: "sha-256 AA:BB",
        expiresAt: "2026-08-25T08:00:00Z",
        offerHash: Data([0, 1, 2])
    )
    #expect(String(data: message, encoding: .utf8) == "dieter-remote-desktop-v1\nrd_one\nnonce\nsha-256 AA:BB\n2026-08-25T08:00:00Z\nAAEC")
}

@Test func remoteDesktopBindingVerifiesAgainstEnrolledEd25519Leaf() throws {
    let offer = "v=0\r\no=test"
    let answer = "v=0\r\na=fingerprint:sha-256 AA:BB\r\n"
    var binding = Dieter_V1_RemoteDesktopSessionBinding()
    binding.clientNonce = "nonce_fixture"
    binding.helperDtlsFingerprint = "sha-256 AA:BB"
    binding.expiresAt = "2099-08-25T08:00:00Z"
    binding.offerSha256 = Data(SHA256.hash(data: Data(offer.utf8)))
    binding.daemonSignature = try #require(Data(base64Encoded: "ctCMwB2SL9Wk9JqpQzgtM+NQxXqUXGGKSSpQ1X2lNX3G3uS8UR7uKe5J8fjZheT1WxX3U5s37saWnSk7dqIADQ=="))
    let certificate = Data(
        """
        -----BEGIN CERTIFICATE-----
        MIIBYTCCAROgAwIBAgIUWcmlQ5i8ry6XFrGSInUHhVtT6bcwBQYDK2VwMCUxIzAh
        BgNVBAMMGkRpZXRlciBSZW1vdGUgRGVza3RvcCBUZXN0MCAXDTI2MDgyNTA2MzAy
        M1oYDzIxMjYwODAxMDYzMDIzWjAlMSMwIQYDVQQDDBpEaWV0ZXIgUmVtb3RlIERl
        c2t0b3AgVGVzdDAqMAUGAytlcAMhAK/kvlcnHBLF7CgDu3bGqnnFqiS1qDddmdfC
        2SuEjBCxo1MwUTAdBgNVHQ4EFgQUTRWfCy1GDKsD0d2TMOQ04Djoy0QwHwYDVR0j
        BBgwFoAUTRWfCy1GDKsD0d2TMOQ04Djoy0QwDwYDVR0TAQH/BAUwAwEB/zAFBgMr
        ZXADQQBccxXAQ41kKXSVZIV/OV/wSiYVreRAZ5kKZDnz//Ks54js7/FFkUoIVBBN
        bpWaGrNlFFB4ASZmaVDTqY2T0psO
        -----END CERTIFICATE-----
        """.utf8
    )
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-25T08:00:00Z"))

    try RemoteDesktopSessionTrust.verify(
        binding: binding, sessionID: "rd_fixture", clientNonce: "nonce_fixture",
        offerSDP: offer, answerSDP: answer, daemonCertificatePEM: certificate,
        now: now
    )
}

@Test func remoteDesktopBindingRejectsExpiryBeforeCertificateVerification() {
    let offer = "v=0\r\no=test"
    let answer = "v=0\r\na=fingerprint:sha-256 AA:BB\r\n"
    var binding = Dieter_V1_RemoteDesktopSessionBinding()
    binding.clientNonce = "nonce"
    binding.helperDtlsFingerprint = "sha-256 AA:BB"
    binding.expiresAt = "2026-08-25T07:00:00Z"
    binding.offerSha256 = Data(SHA256.hash(data: Data(offer.utf8)))
    do {
        try RemoteDesktopSessionTrust.verify(
            binding: binding, sessionID: "rd_one", clientNonce: "nonce",
            offerSDP: offer, answerSDP: answer, daemonCertificatePEM: Data(),
            now: try #require(ISO8601DateFormatter().date(from: "2026-08-25T08:00:00Z"))
        )
        Issue.record("expired binding was accepted")
    } catch RemoteDesktopSessionTrust.Failure.expiredBinding {
        // Expected: expiry is enforced before any untrusted certificate work.
    } catch {
        Issue.record("unexpected binding failure: \(error)")
    }
}

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

@Test func parsesDieterEndpointWithDefaultPort() {
    let endpoint = DieterEndpoint.parse("board.local", name: "Office")
    #expect(endpoint?.name == "Office")
    #expect(endpoint?.host == "board.local")
    #expect(endpoint?.port == 4242)
}

@Test func parsesDieterEndpointWithExplicitPort() {
    let endpoint = DieterEndpoint.parse("127.0.0.1:50051")
    #expect(endpoint?.address == "http://127.0.0.1:50051")
    #expect(DieterEndpoint.parse("127.0.0.1:70000") == nil)
}

@Test func parsesSecureDieterEndpointWithHTTPSDefaultPort() {
    let endpoint = DieterEndpoint.parse("https://dieter.example", name: "Public")
    #expect(endpoint?.host == "dieter.example")
    #expect(endpoint?.port == 443)
    #expect(endpoint?.secure == true)
    #expect(endpoint?.address == "https://dieter.example:443")
}

@Test func transportTargetsDoNotSendIPAddressesAsTLSServerNames() {
    #expect(DieterTransportTarget.hostKind("127.0.0.1") == .ipv4)
    #expect(DieterTransportTarget.hostKind("::1") == .ipv6)
    #expect(DieterTransportTarget.hostKind("fe80::1%en0") == .ipv6)
    #expect(DieterTransportTarget.hostKind("board.dbpprt.com") == .dns)

    #expect(DieterTransportTarget.make(host: "127.0.0.1", port: 4242) is ResolvableTargets.IPv4)
    #expect(DieterTransportTarget.make(host: "::1", port: 4242) is ResolvableTargets.IPv6)
    #expect(DieterTransportTarget.make(host: "board.dbpprt.com", port: 443) is ResolvableTargets.DNS)
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
    #expect(DieterRPC.verifyDaemonCertificateChain(
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

@Test func daemonEndpointKeepsHostnamePresenceAndGatewayCredentialIdentity() throws {
    let endpoint = DieterEndpoint(
        name: "Studio Mac",
        host: "dieter.example",
        port: 443,
        secure: true,
        daemonID: "daemon-1",
        online: false,
        lastSeenAt: "2026-08-18T12:00:00Z",
        version: "2"
    )
    #expect(endpoint.id == "https://dieter.example:443#daemon-1")
    #expect(endpoint.credentialID == "https://dieter.example:443")
    #expect(endpoint.name == "Studio Mac")
    #expect(!endpoint.online)
    #expect(endpoint.gatewayEndpoint.daemonID == nil)
    #expect(endpoint.gatewayEndpoint.credentialID == endpoint.credentialID)
    #expect(DieterRPC.Route.gateway.daemonID == nil)
    #expect(DieterRPC.Route.relay(daemonID: "daemon-1").daemonID == "daemon-1")

    let decoded = try JSONDecoder().decode(DieterEndpoint.self, from: JSONEncoder().encode(endpoint))
    #expect(decoded == endpoint)
}

@Test func credentialFileStorePersistsUpdatesAndRemovalWithUserOnlyPermissions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "board-credential-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "gateway-sessions.json", directoryHint: .notDirectory)
    let credentialID = "https://dieter.example:443"
    let otherCredentialID = "https://other.example:443"

    let store = DieterCredentialFileStore(fileURL: fileURL)
    try await store.save("first", for: credentialID)
    try await store.save("second", for: credentialID)
    try await store.save("other", for: otherCredentialID)

    let reloaded = DieterCredentialFileStore(fileURL: fileURL)
    let reloadedToken = await reloaded.token(for: credentialID)
    let reloadedOtherToken = await reloaded.token(for: otherCredentialID)
    #expect(reloadedToken == "second")
    #expect(reloadedOtherToken == "other")
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryMode = try #require(directoryAttributes[.posixPermissions] as? NSNumber)
    let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
    #expect(directoryMode.intValue == 0o700)
    #expect(fileMode.intValue == 0o600)

    await reloaded.remove(for: credentialID)
    let removedToken = await reloaded.token(for: credentialID)
    let retainedOtherToken = await reloaded.token(for: otherCredentialID)
    #expect(removedToken == nil)
    #expect(retainedOtherToken == "other")
}

@Test func offlineMachineLastSeenTextIsCompact() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-18T15:00:00Z"))
    #expect(MachinePresenceText.lastSeen("2026-08-18T14:59:40Z", relativeTo: now) == "Last seen just now")
    #expect(MachinePresenceText.lastSeen("2026-08-18T14:52:00Z", relativeTo: now) == "Last seen 8m ago")
    #expect(MachinePresenceText.lastSeen("2026-08-18T12:00:00Z", relativeTo: now) == "Last seen 3h ago")
    #expect(MachinePresenceText.lastSeen("", relativeTo: now) == "Last seen unknown")
    #expect(MachinePresenceText.freshestAge(["2026-08-18T14:59:55Z"], relativeTo: now) == "5s ago")
    #expect(MachinePresenceText.isFresh("2026-08-18T14:59:31Z", relativeTo: now))
    #expect(!MachinePresenceText.isFresh("2026-08-18T14:59:30Z", relativeTo: now))
    #expect(MachinePresenceText.online(serverOnline: true, lastSeenAt: "", relativeTo: now))
    #expect(!MachinePresenceText.online(serverOnline: false, lastSeenAt: "2026-08-18T14:59:59Z", relativeTo: now))
}

@Test func cardDropOrderingCreatesStableInsertionPositions() {
    let cards = [dragCard("a", position: 1_024), dragCard("b", position: 2_048), dragCard("c", position: 3_072)]

    #expect(BoardDropOrdering.position(before: "a", movingCardID: "c", cards: cards) == 0)
    #expect(BoardDropOrdering.position(before: "c", movingCardID: "a", cards: cards) == 2_560)
    #expect(BoardDropOrdering.position(before: "missing", movingCardID: "a", cards: cards) == nil)
}

@Test func cardDragPayloadRejectsUnrelatedText() {
    let encoded = BoardCardDragPayload(cardID: "c_123", boardID: "b_456", sourceLane: "todo").encoded
    #expect(BoardCardDragPayload(encoded)?.cardID == "c_123")
    #expect(BoardCardDragPayload("ordinary text") == nil)
}

@Test func labelDragPayloadIsScopedToItsBoard() {
    let encoded = BoardLabelDragPayload(labelID: "l_123", boardID: "b_456").encoded
    let payload = BoardLabelDragPayload(encoded)

    #expect(payload?.labelID == "l_123")
    #expect(payload?.boardID == "b_456")
    #expect(BoardLabelDragPayload("ordinary text") == nil)
    #expect(BoardLabelDragPayload("board-label||l_123") == nil)
}

@Test func labelAssignmentDoesNotCreateDuplicates() {
    #expect(BoardLabelAssignment.adding("l_2", to: ["l_1"]) == ["l_1", "l_2"])
    #expect(BoardLabelAssignment.adding("l_1", to: ["l_1", "l_2"]) == ["l_1", "l_2"])
}

@Test func shiftReturnCreatesANewlineAndPlainReturnSends() {
    #expect(ComposerReturnPolicy.sendsMessage(shiftPressed: false))
    #expect(!ComposerReturnPolicy.sendsMessage(shiftPressed: true))
}

@Test func optimisticCardMoveSurvivesAStaleProjectionUntilSyncConfirmsIt() {
    var stale = Dieter_V1_Card()
    stale.id = "card-one"
    stale.lane = "todo"
    stale.position = 1_024
    let move = OptimisticCardMove(
        operationID: UUID(),
        lane: "review",
        position: 2_048,
        confirmsPosition: true
    )

    let projected = OptimisticCardProjection.reconcile(
        cards: [stale],
        moves: [stale.id: move],
        labels: [:]
    )
    #expect(projected.cards[0].lane == "review")
    #expect(projected.cards[0].position == 2_048)
    #expect(projected.moves[stale.id] == move)

    var confirmed = stale
    confirmed.lane = "review"
    confirmed.position = 2_048
    let synchronized = OptimisticCardProjection.reconcile(
        cards: [confirmed],
        moves: projected.moves,
        labels: [:]
    )
    #expect(synchronized.cards[0] == confirmed)
    #expect(synchronized.moves.isEmpty)
}

@Test func optimisticCardLabelsStayVisibleUntilTheSynchronizedCardMatches() {
    var stale = Dieter_V1_Card()
    stale.id = "card-labels"
    stale.labelIds = ["old"]
    let update = OptimisticCardLabels(operationID: UUID(), labelIDs: ["new"])

    let projected = OptimisticCardProjection.reconcile(
        cards: [stale],
        moves: [:],
        labels: [stale.id: update]
    )
    #expect(projected.cards[0].labelIds == ["new"])
    #expect(projected.labels[stale.id] == update)

    var confirmed = stale
    confirmed.labelIds = ["new"]
    let synchronized = OptimisticCardProjection.reconcile(
        cards: [confirmed],
        moves: [:],
        labels: projected.labels
    )
    #expect(synchronized.labels.isEmpty)
}

@Test func boardLabelChangesSurviveAStaleWorkspaceProjection() {
    var stale = Dieter_V1_Board()
    stale.id = "board-one"
    var updated = stale
    var label = Dieter_V1_Label()
    label.id = "label-one"
    label.name = "Backend"
    label.instructions = "Run the backend checks."
    updated.labels = [label]

    let projected = OptimisticWorkspaceProjection.reconcileBoards(
        [stale],
        pending: [updated.id: updated]
    )
    #expect(projected.boards == [updated])
    #expect(projected.pending[updated.id] == updated)

    let synchronized = OptimisticWorkspaceProjection.reconcileBoards(
        [updated],
        pending: projected.pending
    )
    #expect(synchronized.boards == [updated])
    #expect(synchronized.pending.isEmpty)
}

@Test func conversationRefreshTextDistinguishesCachedAndRefreshingState() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(ConversationRefreshText.label(lastRefreshedAt: nil, syncing: true, now: now) == "Refreshing…")
    #expect(ConversationRefreshText.label(
        lastRefreshedAt: now.addingTimeInterval(-20),
        syncing: true,
        now: now
    ) == "Last refreshed just now · Refreshing…")
    #expect(ConversationRefreshText.label(
        lastRefreshedAt: now.addingTimeInterval(-300),
        syncing: false,
        now: now
    ) == "Last refreshed 5m ago")
}

@Test func cursorOnlySyncPersistenceIsThrottledWithoutDelayingProjectionChanges() {
    let initial = Date(timeIntervalSince1970: 1_000)
    #expect(SyncCursorPersistencePolicy.shouldPersist(
        projectionChanged: false,
        lastPersistedAt: nil,
        now: initial
    ))
    #expect(!SyncCursorPersistencePolicy.shouldPersist(
        projectionChanged: false,
        lastPersistedAt: initial,
        now: initial.addingTimeInterval(14)
    ))
    #expect(SyncCursorPersistencePolicy.shouldPersist(
        projectionChanged: false,
        lastPersistedAt: initial,
        now: initial.addingTimeInterval(15)
    ))
    #expect(SyncCursorPersistencePolicy.shouldPersist(
        projectionChanged: true,
        lastPersistedAt: initial,
        now: initial.addingTimeInterval(1)
    ))
}

@Test func equalInactiveMachineRefreshProducesAnEqualDirectoryProjection() {
    let endpoint = DieterEndpoint(
        name: "Other Mac",
        host: "dieter.example",
        port: 443,
        secure: true,
        daemonID: "daemon-other"
    )
    var project = Dieter_V1_Project()
    project.id = "project-other"
    project.name = "Other project"
    var board = Dieter_V1_Board()
    board.id = "board-other"
    board.projectID = project.id
    var card = Dieter_V1_Card()
    card.id = "card-other"
    card.projectID = project.id
    card.boardID = board.id
    var chat = Dieter_V1_Card()
    chat.id = "chat-other"
    chat.projectID = project.id
    chat.scope = "chat"
    chat.updatedAt = "2026-08-24T10:00:00Z"

    let current = MachineDirectoryProjection(
        projects: [project.id: project],
        projectEndpointIDs: [project.id: endpoint.id],
        boards: [project.id: [board]],
        cards: [project.id: [card]],
        chats: [chat]
    )
    let snapshot = MachineSnapshot(
        endpoint: endpoint,
        connection: MachineConnectionStatus(route: .gateway, latencyMilliseconds: 12),
        projects: [project],
        boards: [board],
        cards: [card],
        chats: [chat]
    )

    #expect(MachineDirectoryReducer.merging(current, snapshots: [snapshot]) == current)
}

@Test func inactiveMachineMergePreservesTheActiveMachineProjection() {
    let activeEndpoint = DieterEndpoint(
        name: "Active Mac",
        host: "dieter.example",
        port: 443,
        secure: true,
        daemonID: "daemon-active"
    )
    let otherEndpoint = DieterEndpoint(
        name: "Other Mac",
        host: "dieter.example",
        port: 443,
        secure: true,
        daemonID: "daemon-other"
    )
    var activeProject = Dieter_V1_Project()
    activeProject.id = "project-active"
    var activeCard = Dieter_V1_Card()
    activeCard.id = "card-active"
    activeCard.projectID = activeProject.id
    var otherProject = Dieter_V1_Project()
    otherProject.id = "project-other"
    var otherChat = Dieter_V1_Card()
    otherChat.id = "chat-other"
    otherChat.projectID = otherProject.id
    otherChat.scope = "chat"

    let current = MachineDirectoryProjection(
        projects: [activeProject.id: activeProject],
        projectEndpointIDs: [activeProject.id: activeEndpoint.id],
        boards: [activeProject.id: []],
        cards: [activeProject.id: [activeCard]],
        chats: []
    )
    let next = MachineDirectoryReducer.merging(current, snapshots: [MachineSnapshot(
        endpoint: otherEndpoint,
        connection: MachineConnectionStatus(route: .gateway, latencyMilliseconds: 8),
        projects: [otherProject],
        boards: [],
        cards: [],
        chats: [otherChat]
    )])

    #expect(next.projects[activeProject.id] == activeProject)
    #expect(next.projectEndpointIDs[activeProject.id] == activeEndpoint.id)
    #expect(next.cards[activeProject.id] == [activeCard])
    #expect(next.projects[otherProject.id] == otherProject)
    #expect(next.chats == [otherChat])
}

private func historyToolMessage(_ id: String) -> Dieter_V1_UiMessage {
    var part = Dieter_V1_MessagePart()
    part.type = "dynamic-tool"
    part.toolCallID = "call_\(id)"
    part.toolName = "Bash"
    var message = Dieter_V1_UiMessage()
    message.id = id
    message.role = "assistant"
    message.parts = [part]
    return message
}

private func historyTextMessage(_ id: String, role: String = "assistant") -> Dieter_V1_UiMessage {
    var part = Dieter_V1_MessagePart()
    part.type = "text"
    part.text = "message \(id)"
    var message = Dieter_V1_UiMessage()
    message.id = id
    message.role = role
    message.parts = [part]
    return message
}

@Test func earlierHistoryAnchorSurvivesToolGroupMergesAcrossPageBoundaries() {
    // Before the earlier page arrives the transcript starts with a tool-only
    // message; the anchor remembers the message id, not the item id.
    let visible = ConversationTimelineItem.group([historyToolMessage("m_20"), historyTextMessage("m_21")])
    let anchorMessageID = visible.first?.messages.first?.id
    #expect(anchorMessageID == "m_20")

    // Prepending an earlier page that ends in tool calls merges the old first
    // item into a differently-identified group; the anchor must resolve to
    // the containing row instead of silently scrolling nowhere.
    let merged = ConversationTimelineItem.group([
        historyTextMessage("m_18", role: "user"),
        historyToolMessage("m_19"),
        historyToolMessage("m_20"),
        historyTextMessage("m_21"),
    ])
    #expect(ConversationScrollBehavior.anchorItem(containing: anchorMessageID, in: merged) == "tools:m_19")

    // Plain message rows use the same identity for ForEach and ScrollViewReader.
    #expect(ConversationScrollBehavior.anchorItem(containing: "m_21", in: merged) == "message:m_21")
    #expect(ConversationScrollBehavior.anchorItem(containing: "gone", in: merged) == nil)
    #expect(ConversationScrollBehavior.anchorItem(containing: nil, in: merged) == nil)
}

@Test @MainActor func watchDeltaWindowSlidesKeepMessagesAsLocalHistory() {
    let store = DieterStore()
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.conversation.messages = [historyTextMessage("m_1"), historyTextMessage("m_2"), historyTextMessage("m_3")]
    store.conversation = snapshot
    store.conversationHistoryStart = 10
    store.conversationHistoryTotal = 13
    store.conversationHistoryHasMore = true

    var update = Dieter_V1_ConversationUpdate()
    update.removedMessageIds = ["m_1"]
    update.changedMessages = [historyTextMessage("m_4")]
    store.apply(update)

    #expect(store.olderConversationMessages.map(\.id) == ["m_1"])
    #expect(store.conversationMessages.map(\.id) == ["m_1", "m_2", "m_3", "m_4"])
    #expect(store.conversationHistoryStart == 10)
    #expect(store.conversationHistoryHasMore)
}

@Test @MainActor func watchSnapshotReplacementSlidesEarlierMessagesIntoHistory() {
    let store = DieterStore()
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.conversation.messages = [historyTextMessage("m_1"), historyTextMessage("m_2"), historyTextMessage("m_3")]
    store.conversation = snapshot
    store.conversationHistoryStart = 0
    store.conversationHistoryTotal = 3

    var replacement = Dieter_V1_ConversationSnapshot()
    replacement.conversation.messages = [historyTextMessage("m_3"), historyTextMessage("m_4")]
    replacement.page.start = 2
    replacement.page.end = 4
    replacement.page.total = 4
    replacement.page.hasMore_p = true
    var update = Dieter_V1_ConversationUpdate()
    update.snapshot = replacement
    store.apply(update)

    #expect(store.olderConversationMessages.map(\.id) == ["m_1", "m_2"])
    #expect(store.conversationMessages.map(\.id) == ["m_1", "m_2", "m_3", "m_4"])
    #expect(store.conversationHistoryStart == 0)
}

@Test @MainActor func watchSnapshotWithoutOverlapResetsHistoryToTheServerPage() {
    let store = DieterStore()
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.conversation.messages = [historyTextMessage("m_1"), historyTextMessage("m_2")]
    store.conversation = snapshot
    store.conversationHistoryStart = 0
    store.conversationHistoryTotal = 2

    var replacement = Dieter_V1_ConversationSnapshot()
    replacement.conversation.messages = [historyTextMessage("m_5"), historyTextMessage("m_6")]
    replacement.page.start = 4
    replacement.page.end = 6
    replacement.page.total = 6
    replacement.page.hasMore_p = true
    var update = Dieter_V1_ConversationUpdate()
    update.snapshot = replacement
    store.apply(update)

    #expect(store.olderConversationMessages.isEmpty)
    #expect(store.conversationMessages.map(\.id) == ["m_5", "m_6"])
    #expect(store.conversationHistoryStart == 4)
    #expect(store.conversationHistoryHasMore)
}

@Test func terminalScreenReducerReplaysResetsAndBoundsReconnectState() {
    let first = TerminalScreenReducer.applying(
        data: Data("first".utf8),
        screenReset: true,
        to: TerminalScreenState(),
        limit: 8
    )
    #expect(String(decoding: first.data, as: UTF8.self) == "first")
    #expect(first.resetRevision == 1)

    let appended = TerminalScreenReducer.applying(
        data: Data("-second".utf8),
        screenReset: false,
        to: first,
        limit: 8
    )
    #expect(String(decoding: appended.data, as: UTF8.self) == "t-second")
    #expect(appended.resetRevision == 2)
    #expect(appended.revision == 2)

    let replayed = TerminalScreenReducer.applying(
        data: Data("fresh".utf8),
        screenReset: true,
        to: appended,
        limit: 8
    )
    #expect(String(decoding: replayed.data, as: UTF8.self) == "fresh")
    #expect(replayed.resetRevision == 3)
}

@Test @MainActor func remoteTerminalRendererMovesTheVisibleCaretWithOutputAndReplayResets() async throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let view = SwiftTerm.TerminalView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 320),
        font: font
    )
    let renderer = RemoteTerminalScreenRenderer()

    var screen = TerminalScreenState()
    screen.data = Data("abc".utf8)
    screen.revision = 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 3)
    #expect(view.terminal.getCursorLocation().y == 0)
    #expect(view.caretFrame.origin.x > 0)
    let firstCaret = view.caretFrame

    screen.data.append(Data("\u{001B}[2D".utf8))
    screen.revision += 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 1)
    #expect(view.caretFrame.origin.x < firstCaret.origin.x)

    screen.data.append(Data("\r\nnext".utf8))
    screen.revision += 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 4)
    #expect(view.terminal.getCursorLocation().y == 1)
    #expect(view.caretFrame.origin.y < firstCaret.origin.y)

    screen.data = Data("reset".utf8)
    screen.revision += 1
    screen.resetRevision += 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 5)
    #expect(view.terminal.getCursorLocation().y == 0)
    #expect(view.caretFrame.origin.y == firstCaret.origin.y)
}

@Test @MainActor func remoteTerminalViewUsesPersistedGeometryBeforeReconnectReplay() async throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let view = RemoteTerminalView(frame: .zero, font: font)
    view.prepareForReplay(columns: 120, rows: 36)

    let renderer = RemoteTerminalScreenRenderer()
    var screen = TerminalScreenState()
    screen.data = Data("persisted prompt stays on one row".utf8)
    screen.revision = 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.cols == 120)
    #expect(view.terminal.rows == 36)
    #expect(view.terminal.getCursorLocation().x == 33)
    #expect(view.terminal.getCursorLocation().y == 0)
}

@Test @MainActor func remoteTerminalViewTracksSetFrameSizeGeometry() async throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let view = RemoteTerminalView(
        frame: NSRect(x: 0, y: 0, width: 900, height: 500),
        font: font
    )
    view.prepareForReplay(columns: 120, rows: 36)
    view.feed(text: "terminal resize remains coherent")

    view.setFrameSize(NSSize(width: 520, height: 260))
    try await Task.sleep(nanoseconds: 50_000_000)

    let narrowColumns = view.terminal.cols
    let narrowRows = view.terminal.rows
    #expect(narrowColumns > 2 && narrowColumns < 120)
    #expect(narrowRows > 1 && narrowRows < 36)
    #expect(view.terminal.getCursorLocation().x == 32)
    #expect(view.terminal.getCursorLocation().x < narrowColumns)

    view.setFrameSize(NSSize(width: 1_100, height: 620))
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.cols > narrowColumns)
    #expect(view.terminal.rows > narrowRows)
    #expect(view.terminal.getCursorLocation().x == 32)
    #expect(view.bounds.intersects(view.caretFrame))
}

@Test func chatActivityTextUsesCompactUnits() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-19T12:00:00Z"))
    #expect(ChatActivityText.compact("2026-08-19T11:59:35Z", relativeTo: now) == "now")
    #expect(ChatActivityText.compact("2026-08-19T11:55:00Z", relativeTo: now) == "5m")
    #expect(ChatActivityText.compact("2026-08-19T10:00:00Z", relativeTo: now) == "2h")
}

@Test func assistantMessagePartsCollapseAdjacentToolCallsIntoGroups() {
    var intro = Dieter_V1_MessagePart()
    intro.type = "text"
    intro.text = "Starting"
    var bash = Dieter_V1_MessagePart()
    bash.type = "dynamic-tool"
    bash.toolName = "Bash"
    var edit = Dieter_V1_MessagePart()
    edit.type = "tool-call"
    edit.toolName = "Edit"
    var result = Dieter_V1_MessagePart()
    result.type = "text"
    result.text = "Finished"
    var browser = Dieter_V1_MessagePart()
    browser.type = "tool"
    browser.toolName = "browser.open"

    let groups = ConversationMessagePartGroup.group([intro, bash, edit, result, browser])

    #expect(groups.count == 4)
    #expect(!groups[0].isToolCallGroup)
    #expect(groups[1].isToolCallGroup)
    #expect(groups[1].parts.map(\.toolName) == ["Bash", "Edit"])
    #expect(!groups[2].isToolCallGroup)
    #expect(groups[3].isToolCallGroup)
}

@Test func hiddenReasoningDoesNotSplitAdjacentToolCallGroups() {
    var reasoning = Dieter_V1_MessagePart()
    reasoning.type = "reasoning"
    reasoning.text = "Thinking about the change"
    var bash = Dieter_V1_MessagePart()
    bash.type = "dynamic-tool"
    bash.toolName = "Bash"
    var edit = Dieter_V1_MessagePart()
    edit.type = "dynamic-tool"
    edit.toolName = "Edit"

    let hidden = ConversationMessagePartGroup.group([reasoning, bash, reasoning, edit], showReasoning: false)
    #expect(hidden.count == 1)
    #expect(hidden[0].isToolCallGroup)
    #expect(hidden[0].parts.map(\.toolName) == ["Bash", "Edit"])

    let shown = ConversationMessagePartGroup.group([reasoning, bash, reasoning, edit], showReasoning: true)
    #expect(shown.count == 4)
    #expect(!shown[0].isToolCallGroup)
    #expect(shown[1].isToolCallGroup)

    var blank = Dieter_V1_MessagePart()
    blank.type = "reasoning"
    blank.text = "  \n"
    let blankShown = ConversationMessagePartGroup.group([bash, blank, edit], showReasoning: true)
    #expect(blankShown.count == 1)
    #expect(blankShown[0].parts.map(\.toolName) == ["Bash", "Edit"])
}

@Test func prefixedToolPartTypesGroupAndDeriveToolNames() {
    var read = Dieter_V1_MessagePart()
    read.type = "tool-Read"
    var bash = Dieter_V1_MessagePart()
    bash.type = "tool-Bash"
    let groups = ConversationMessagePartGroup.group([read, bash])
    #expect(groups.count == 1)
    #expect(groups[0].isToolCallGroup)
    #expect(read.effectiveToolName == "Read")
    #expect(ToolCallGroupSummary(toolNames: [read, bash].map(\.effectiveToolName)).title == "1 command, 1 tool call")
}

@Test func reasoningOnlyMessagesMergeIntoToolTimelineGroupsWhenReasoningHidden() {
    var reasoning = Dieter_V1_MessagePart()
    reasoning.type = "reasoning"
    reasoning.text = "Deliberating"
    var tool = Dieter_V1_MessagePart()
    tool.type = "dynamic-tool"
    tool.toolCallID = "tool_1"
    tool.toolName = "Bash"

    var message = Dieter_V1_UiMessage()
    message.id = "message_1"
    message.role = "assistant"
    message.parts = [reasoning, tool]

    let hidden = ConversationTimelineItem.group([message], showReasoning: false)
    #expect(hidden.count == 1)
    #expect(hidden[0].isToolCallGroup)

    let shown = ConversationTimelineItem.group([message], showReasoning: true)
    #expect(shown.count == 1)
    #expect(!shown[0].isToolCallGroup)
}

@Test func adjacentToolOnlyAssistantMessagesCollapseIntoOneStableTimelineGroup() {
    var firstTool = Dieter_V1_MessagePart()
    firstTool.type = "dynamic-tool"
    firstTool.toolCallID = "tool_1"
    firstTool.toolName = "exec_command"
    var secondTool = Dieter_V1_MessagePart()
    secondTool.type = "tool-call"
    secondTool.toolCallID = "tool_2"
    secondTool.toolName = "apply_patch"
    var text = Dieter_V1_MessagePart()
    text.type = "text"
    text.text = "Implemented."

    var first = Dieter_V1_UiMessage()
    first.id = "message_1"
    first.role = "assistant"
    first.parts = [firstTool]
    var second = Dieter_V1_UiMessage()
    second.id = "message_2"
    second.role = "assistant"
    second.parts = [secondTool]
    var result = Dieter_V1_UiMessage()
    result.id = "message_3"
    result.role = "assistant"
    result.parts = [text]

    let items = ConversationTimelineItem.group([first, second, result])

    #expect(items.count == 2)
    #expect(items[0].id == "tools:message_1")
    #expect(items[0].toolCalls.map(\.part.toolName) == ["exec_command", "apply_patch"])
    #expect(items[1].id == "message:message_3")
}

@Test func emptyMessageIDsReceiveUniqueStableTimelineFallbacks() {
    var first = Dieter_V1_UiMessage(); first.role = "user"
    var second = Dieter_V1_UiMessage(); second.role = "assistant"
    let items = ConversationTimelineItem.group([first, second])

    #expect(items.map(\.id) == ["message:position:0", "message:position:1"])
    #expect(Set(items.map(\.id)).count == items.count)
}

@Test func toolCallGroupSummaryMatchesCompactEditAndCommandLabels() {
    #expect(ToolCallGroupSummary(toolNames: ["Bash"]).title == "1 command")
    #expect(ToolCallGroupSummary(toolNames: Array(repeating: "Edit", count: 14) + Array(repeating: "exec_command", count: 7)).title == "14 edits, 7 commands")
    #expect(ToolCallGroupSummary(toolNames: ["browser.open", "mcp/custom"]).title == "2 tool calls")
}

@Test func conversationContextUsageReadsHarnessMetadata() throws {
    var message = Dieter_V1_UiMessage()
    message.metadataJson = Data(#"{"usage":{"inputTokens":120,"outputTokens":30,"totalTokens":150},"contextWindowTokens":1000}"#.utf8)
    let usage = try #require(ConversationContextUsage.latest(messages: [message], fallbackWindow: 0))
    #expect(usage.used == 150)
    #expect(usage.window == 1_000)
    #expect(usage.percentage == 15)
}

@Test func conversationPaneWidthIsClampedToItsSupportedRange() {
    #expect(ConversationPaneSizing.clamped(320) == ConversationPaneSizing.minimumWidth)
    #expect(ConversationPaneSizing.clamped(540) == 540)
    #expect(ConversationPaneSizing.clamped(760) == ConversationPaneSizing.maximumWidth)
    #expect(ConversationPaneSizing.resolvedWidth(500, workspaceWidth: 1_200) == 500)
    #expect(ConversationPaneSizing.resolvedWidth(680, workspaceWidth: 1_200) == 504)
}

@Test func kanbanLanesFillTheBoardBeforeFallingBackToHorizontalScrolling() {
    #expect(KanbanLaneSizing.laneWidth(availableWidth: 1_255, laneCount: 4) == 300)
    #expect(KanbanLaneSizing.contentWidth(availableWidth: 1_255, laneCount: 4) == 1_255)
    #expect(KanbanLaneSizing.laneWidth(availableWidth: 680, laneCount: 4) == KanbanLaneSizing.minimumWidth)
    #expect(KanbanLaneSizing.contentWidth(availableWidth: 680, laneCount: 4) == 1_111)
}

@Test func boardCreationOptionsMatchTheServerContract() {
    #expect(BoardWorkflow.allCases.map(\.rawValue) == ["review", "direct"])
    #expect(DoneArchivePolicy.allCases.map(\.rawValue) == [
        "never", "immediately", "after_1_day", "after_7_days", "after_30_days", "after_90_days",
    ])
}

@Test func settingsAreFirstClassNestedNavigationDestinations() {
    #expect(AppSection.allCases.contains(.settings))
    #expect(DieterSettingsSection.allCases.map(\.rawValue) == [
        "General", "Connection", "Prompts", "Notifications", "Agents",
    ])
}

@Test func reasoningTracePreferenceDefaultsOffAndPersistsBothStates() throws {
    let suite = "dieter-reasoning-trace-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(!ReasoningTracePreferences.load(from: defaults))

    ReasoningTracePreferences.save(true, to: defaults)
    #expect(ReasoningTracePreferences.load(from: defaults))

    ReasoningTracePreferences.save(false, to: defaults)
    #expect(!ReasoningTracePreferences.load(from: defaults))
    #expect(defaults.object(forKey: ReasoningTracePreferences.storageKey) != nil)
}

@Test func appearancePreferenceDefaultsToDarkAndRecognizesEveryStoredMode() {
    #expect(DieterAppearance.resolve(nil) == .dark)
    #expect(DieterAppearance.resolve("unknown") == .dark)
    #expect(DieterAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
    #expect(DieterAppearance.resolve("system").colorScheme == nil)
    #expect(DieterAppearance.resolve("light").colorScheme == .light)
    #expect(DieterAppearance.resolve("dark").colorScheme == .dark)
}

@Test func palettePreferenceRecognizesEveryOfficialPackAndDefaultsToArctic() {
    #expect(DieterPalette.resolve(nil) == .arcticConsole)
    #expect(DieterPalette.resolve("unknown") == .arcticConsole)
    #expect(DieterPalette.allCases.map(\.rawValue) == [
        "electric-blue", "jade-operator", "copper-circuit", "ultraviolet-relay",
        "solar-command", "arctic-console", "coral-signal", "acid-terminal",
    ])
    #expect(Set(DieterPalette.allCases.map(\.title)).count == 8)
    #expect(DieterPalette.allCases.allSatisfy { DieterPalette.resolve($0.rawValue) == $0 })
}

@Test func onlyAuthenticationRequiresAConnectionOverlay() {
    #expect(ConnectionPhase.authenticationRequired.needsConnectionOverlay)
    #expect(!ConnectionPhase.connecting.needsConnectionOverlay)
    #expect(!ConnectionPhase.disconnected.needsConnectionOverlay)
    #expect(ConnectionPhase.incompatible(found: "1").label == "Update required")
}

@Test func machineRoutingAutomaticallyUsesAnOnlineTarget() {
    let gateway = DieterEndpoint(name: "Gateway", host: "example.com", port: 443, secure: true)
    let offlinePreferred = DieterEndpoint(
        name: "Studio Mac", host: gateway.host, port: gateway.port, secure: true,
        daemonID: "mac", online: false
    )
    let onlineFallback = DieterEndpoint(
        name: "Build server", host: gateway.host, port: gateway.port, secure: true,
        daemonID: "server", online: true
    )

    #expect(MachineRoutingPolicy.automaticConnectionTarget(
        from: [offlinePreferred, onlineFallback],
        preferredDaemonID: "mac"
    ) == onlineFallback)
    #expect(MachineRoutingPolicy.automaticConnectionTarget(
        from: [offlinePreferred],
        preferredDaemonID: "mac"
    ) == nil)
}

@Test func boardPresentationUsesLoadingStateUntilASelectionCanBeResolved() {
    #expect(BoardPresentationState.resolve(
        hasLoadedWorkspace: false,
        selectedBoardID: "",
        hasSelectedBoard: false
    ) == .loading)
    #expect(BoardPresentationState.resolve(
        hasLoadedWorkspace: true,
        selectedBoardID: "b_loading",
        hasSelectedBoard: false
    ) == .loading)
    #expect(BoardPresentationState.resolve(
        hasLoadedWorkspace: true,
        selectedBoardID: "b_loaded",
        hasSelectedBoard: true
    ) == .loaded)
}

@Test func boardPresentationPreservesTheEmptyStateForABoardlessWorkspace() {
    #expect(BoardPresentationState.resolve(
        hasLoadedWorkspace: true,
        selectedBoardID: "",
        hasSelectedBoard: false
    ) == .empty)
}

@Test func transientRPCFailuresAreEligibleForSilentReconnect() {
    #expect(DieterRPCFailure.isTransient(RPCError(code: .unavailable, message: "stream unexpectedly closed")))
    #expect(DieterRPCFailure.isTransient(RPCError(code: .deadlineExceeded, message: "timed out")))
    #expect(!DieterRPCFailure.isTransient(RPCError(code: .notFound, message: "board missing")))
}

@Test func offlineConnectionLabelsUseCompactRelativeAges() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(SyncFreshnessPresentation.lastConnectedLabel(lastConnectedAt: nil, now: now) == "Last connected unknown")
    #expect(SyncFreshnessPresentation.lastConnectedLabel(lastConnectedAt: now.addingTimeInterval(-59), now: now) == "Last connected just now")
    #expect(SyncFreshnessPresentation.lastConnectedLabel(lastConnectedAt: now.addingTimeInterval(-60), now: now) == "Last connected 1m ago")
    #expect(SyncFreshnessPresentation.lastConnectedLabel(lastConnectedAt: now.addingTimeInterval(-3_600), now: now) == "Last connected 1h ago")
}

@Test @MainActor func cachedBoardSelectionSwitchesTheVisibleProjectWithoutAnRPC() {
    let store = DieterStore()
    var firstProject = Dieter_V1_Project()
    firstProject.id = "p_first"
    firstProject.name = "First"
    var secondProject = Dieter_V1_Project()
    secondProject.id = "p_second"
    secondProject.name = "Second"
    var firstBoard = Dieter_V1_Board()
    firstBoard.id = "b_first"
    firstBoard.projectID = firstProject.id
    var secondBoard = Dieter_V1_Board()
    secondBoard.id = "b_second"
    secondBoard.projectID = secondProject.id
    var secondCard = Dieter_V1_Card()
    secondCard.id = "c_second"
    secondCard.projectID = secondProject.id
    secondCard.boardID = secondBoard.id

    store.projectDirectory = [firstProject.id: firstProject, secondProject.id: secondProject]
    store.navigationBoards = [firstProject.id: [firstBoard], secondProject.id: [secondBoard]]
    store.navigationCards = [firstProject.id: [], secondProject.id: [secondCard]]
    store.selectedProjectID = firstProject.id
    store.selectedBoardID = firstBoard.id
    store.state.project = firstProject
    store.state.boards = [firstBoard]

    store.selectCachedBoard(secondBoard.id, projectID: secondProject.id)

    #expect(store.selectedProjectID == secondProject.id)
    #expect(store.selectedBoard?.id == secondBoard.id)
    #expect(store.state.project.id == secondProject.id)
    #expect(store.boardCards.map(\.id) == [secondCard.id])
}

@Test func projectFileLanguageDetectionCoversCommonSourceFormats() {
    #expect(ProjectFileLanguage.detect(filename: "BoardView.swift") == .swift)
    #expect(ProjectFileLanguage.detect(filename: "main.go") == .go)
    #expect(ProjectFileLanguage.detect(filename: "client.tsx") == .typescript)
    #expect(ProjectFileLanguage.detect(filename: "settings.yaml") == .yaml)
    #expect(ProjectFileLanguage.detect(filename: "Dockerfile") == .shell)
    #expect(ProjectFileLanguage.detect(filename: "LICENSE") == .plain)
}

@Test func projectFilePresentationRecognizesImagesAndPreservesBytes() {
    #expect(ProjectFilePresentation.isImage(filename: "preview.png", mimeType: ""))
    #expect(ProjectFilePresentation.isImage(filename: "asset", mimeType: "image/webp"))
    #expect(!ProjectFilePresentation.isImage(filename: "main.swift", mimeType: "text/plain"))
    #expect(ProjectFilePresentation.bytes(binary: true, content: "ignored", data: Data([0, 1, 2])) == Data([0, 1, 2]))
    #expect(ProjectFilePresentation.bytes(binary: false, content: "hello", data: Data()) == Data("hello".utf8))
}

@Test func projectFileNavigationReturnsEachParentThroughTheProjectRoot() {
    #expect(ProjectFileNavigation.parentPath(of: "apps/mac/Sources") == "apps/mac")
    #expect(ProjectFileNavigation.parentPath(of: "apps/mac") == "apps")
    #expect(ProjectFileNavigation.parentPath(of: "apps") == "")
    #expect(ProjectFileNavigation.parentPath(of: "") == "")
}

@Test func labelColorPaletteContainsValidDistinctHexColors() {
    #expect(LabelColorPalette.colors.count >= 8)
    #expect(Set(LabelColorPalette.colors).count == LabelColorPalette.colors.count)
    #expect(LabelColorPalette.colors.allSatisfy { SwiftUI.Color(hex: $0) != nil })
}

@Test func labelColorPaletteSerializesCustomColorsAsHex() {
    #expect(LabelColorPalette.hex(for: SwiftUI.Color(red: 1, green: 0.5, blue: 0)) == "#ff8000")
}

@Test func projectFileNavigationTracksBackwardAndForwardFolderHistory() {
    var navigation = ProjectFileNavigation()
    #expect(!navigation.canGoBack)
    #expect(!navigation.canGoForward)

    navigation.recordNavigation(from: "", to: "apps")
    navigation.recordNavigation(from: "apps", to: "apps/mac")
    #expect(navigation.goBack(from: "apps/mac") == "apps")
    #expect(navigation.canGoBack)
    #expect(navigation.canGoForward)
    #expect(navigation.goBack(from: "apps") == "")
    #expect(!navigation.canGoBack)
    #expect(navigation.goForward(from: "") == "apps")

    navigation.recordNavigation(from: "apps", to: "docs")
    #expect(!navigation.canGoForward)
    navigation.reset()
    #expect(!navigation.canGoBack)
    #expect(!navigation.canGoForward)
}

@Test func globalProjectionAndOutboxSurviveRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "board-sync-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = DieterSyncPersistence(root: root)

    var cursor = Dieter_V1_SyncCursor()
    cursor.epoch = "epoch-one"
    cursor.sequence = 42
    cursor.projectionVersion = 1
    var project = Dieter_V1_Project()
    project.id = "p_one"
    project.name = "One"
    var snapshot = Dieter_V1_GlobalSnapshot()
    snapshot.state.projects = [project]
    var request = Dieter_V1_SendMessageRequest()
    request.cardID = "c_one"
    request.commandID = "command-one"
    request.clientID = "mac-one"
    request.messageID = "msg_one"
    let entry = DieterOutboxEntry(
        commandID: request.commandID,
        clientID: request.clientID,
        endpointID: "https://dieter.example:443#daemon-one",
        kind: .sendMessage,
        request: try request.serializedData(),
        optimisticID: request.messageID,
        attempts: 0,
        createdAt: Date(timeIntervalSince1970: 1)
    )
    let endpointID = "https://dieter.example:443#daemon-one"
    let refreshedAt = Date(timeIntervalSince1970: 100)
    try await persistence.save(.init(
        projections: [endpointID: .init(cursor: try cursor.serializedData(), snapshot: try snapshot.serializedData())],
        conversationRefreshedAt: [endpointID: ["c_one": refreshedAt]],
        outbox: [entry]
    ))

    let restored = await DieterSyncPersistence(root: root).load()
    let projection = try #require(restored.projections[endpointID])
    let cursorData = try #require(projection.cursor)
    let snapshotData = try #require(projection.snapshot)
    let restoredCursor = try Dieter_V1_SyncCursor(serializedBytes: cursorData)
    let restoredSnapshot = try Dieter_V1_GlobalSnapshot(serializedBytes: snapshotData)
    #expect(restoredCursor.sequence == 42)
    #expect(restoredSnapshot.state.projects.first?.id == "p_one")
    #expect(restored.conversationRefreshedAt[endpointID]?["c_one"] == refreshedAt)
    #expect(restored.outbox.first?.optimisticID == "msg_one")
    #expect(restored.outbox.first?.endpointID == endpointID)
}

@Test func cleanSyncClearsEveryProjectionAndPreservesOutbox() throws {
    let firstEndpointID = "https://one.example:443#daemon-one"
    let secondEndpointID = "https://two.example:443#daemon-two"
    let entry = DieterOutboxEntry(
        commandID: "command-one",
        clientID: "mac-one",
        endpointID: firstEndpointID,
        kind: .sendMessage,
        request: Data([1, 2, 3]),
        optimisticID: "message-one",
        attempts: 0,
        createdAt: Date(timeIntervalSince1970: 1)
    )
    var state = DieterSyncDiskState(
        projections: [
            firstEndpointID: .init(cursor: Data([1]), snapshot: Data([2])),
            secondEndpointID: .init(cursor: Data([3]), snapshot: Data([4])),
        ],
        cursor: Data([5]),
        snapshot: Data([6]),
        conversationRefreshedAt: [firstEndpointID: ["c_one": Date(timeIntervalSince1970: 10)]],
        outbox: [entry]
    )

    state.clearProjections()

    #expect(state.projections.isEmpty)
    #expect(state.cursor == nil)
    #expect(state.snapshot == nil)
    #expect(state.conversationRefreshedAt.isEmpty)
    #expect(state.outbox.count == 1)
    #expect(state.outbox.first?.commandID == entry.commandID)
}

@Test func permanentOutboxFailureDoesNotBlockLaterCreate() throws {
    let endpointID = "gateway#daemon"
    var send = Dieter_V1_SendMessageRequest()
    send.cardID = "c_missing"
    var create = Dieter_V1_CreateConversationRequest()
    create.projectID = "p_one"
    let failed = DieterOutboxEntry(
        commandID: "send", clientID: "mac", endpointID: endpointID, kind: .sendMessage,
        request: try send.serializedData(), optimisticID: "msg_one", attempts: 535,
        lastError: "gRPC notFound: card not found", state: .failed, createdAt: Date(timeIntervalSince1970: 1)
    )
    let later = DieterOutboxEntry(
        commandID: "create", clientID: "mac", endpointID: endpointID, kind: .createChat,
        request: try create.serializedData(), optimisticID: "local_chat", attempts: 0,
        createdAt: Date(timeIntervalSince1970: 2)
    )

    #expect(DieterOutboxPolicy.nextIndex(in: [failed, later], endpointID: endpointID) == 1)
}

@Test func backedOffOutboxHeadDoesNotStarveReadyEntry() throws {
    let endpointID = "gateway#daemon"
    var send = Dieter_V1_SendMessageRequest(); send.cardID = "c_one"
    var delayed = DieterOutboxEntry(
        commandID: "first", clientID: "mac", endpointID: endpointID, kind: .sendMessage,
        request: try send.serializedData(), optimisticID: "msg_one", attempts: 1,
        createdAt: Date(timeIntervalSince1970: 1)
    )
    delayed.state = .retrying
    delayed.nextAttemptAt = Date(timeIntervalSince1970: 200)
    let ready = DieterOutboxEntry(
        commandID: "second", clientID: "mac", endpointID: endpointID, kind: .sendMessage,
        request: try send.serializedData(), optimisticID: "msg_two", attempts: 0,
        createdAt: Date(timeIntervalSince1970: 2)
    )

    #expect(DieterOutboxPolicy.nextIndex(in: [delayed, ready], endpointID: endpointID, now: Date(timeIntervalSince1970: 100)) == 1)
}

@Test func createSuccessRetargetsDependentQueuedMessages() throws {
    var request = Dieter_V1_SendMessageRequest()
    request.cardID = "local_chat"
    let send = DieterOutboxEntry(
        commandID: "send", clientID: "mac", endpointID: "endpoint", kind: .sendMessage,
        request: try request.serializedData(), optimisticID: "msg_one", attempts: 0, createdAt: Date()
    )
    var entries = [send]

    try DieterOutboxPolicy.retargetDependencies(in: &entries, from: "local_chat", to: "c_server")

    #expect(try Dieter_V1_SendMessageRequest(serializedBytes: entries[0].request).cardID == "c_server")
}

@Test func localConversationIDsNeverQualifyForServerFetch() {
    #expect(!DieterConversationID.isServerBacked("local_chat"))
    #expect(DieterConversationID.isServerBacked("c_server"))
}

@Test func rpcErrorsExposeStatusAndMessage() {
    let error = RPCError(code: .notFound, message: "card c_missing was not found")

    #expect(DieterRPCFailure.isPermanent(error))
    #expect(DieterRPCFailure.message(for: error) == "gRPC notFound: card c_missing was not found")
    #expect(!DieterRPCFailure.message(for: error).contains("RPCError error 1"))
}

@Test func cancelledConversationOpenRetriesOnceWithoutReportingStaleFailures() {
    let cancelled = RPCError(code: .cancelled, message: "request cancelled")

    #expect(DieterConversationOpenFailurePolicy.disposition(
        for: cancelled,
        selectionMatches: true,
        cancellationRetries: 0
    ) == .retry)
    #expect(DieterConversationOpenFailurePolicy.disposition(
        for: cancelled,
        selectionMatches: true,
        cancellationRetries: 1
    ) == .report)
    #expect(DieterConversationOpenFailurePolicy.disposition(
        for: RPCError(code: .notFound, message: "missing"),
        selectionMatches: false,
        cancellationRetries: 0
    ) == .ignore)
}

@Test func globalProjectionReducerAppliesMetadataChangesAndTombstones() {
    var retained = Dieter_V1_Project(); retained.id = "p_keep"; retained.name = "Before"
    var removed = Dieter_V1_Project(); removed.id = "p_remove"
    var oldCard = Dieter_V1_Card(); oldCard.id = "c_remove"; oldCard.projectID = retained.id
    var snapshot = Dieter_V1_GlobalSnapshot()
    snapshot.state.projects = [retained, removed]
    snapshot.state.cards = [oldCard]

    retained.name = "After"
    var added = Dieter_V1_Project(); added.id = "p_add"; added.name = "Added"
    var chat = Dieter_V1_Card(); chat.id = "chat_add"; chat.projectID = added.id
    var settings = Dieter_V1_Settings(); settings.globalParallelLimit = 7
    var delta = Dieter_V1_GlobalDelta()
    delta.projects = [retained, added]
    delta.removedProjectIds = [removed.id]
    delta.removedCardIds = [oldCard.id]
    delta.chats = [chat]
    delta.settings = settings

    let reduced = GlobalProjectionReducer.applying(delta, to: snapshot)
    #expect(reduced.state.projects.map(\.id) == ["p_keep", "p_add"])
    #expect(reduced.state.projects.first?.name == "After")
    #expect(reduced.state.cards.isEmpty)
    #expect(reduced.state.chats.map(\.id) == ["chat_add"])
    #expect(reduced.settings.globalParallelLimit == 7)
}

@Test func emptyGlobalDeltaDoesNotChangeProjection() {
    var snapshot = Dieter_V1_GlobalSnapshot()
    var project = Dieter_V1_Project(); project.id = "p_keep"
    snapshot.state.projects = [project]
    let delta = Dieter_V1_GlobalDelta()

    #expect(!GlobalProjectionReducer.changesProjection(delta))
    #expect(GlobalProjectionReducer.applying(delta, to: snapshot) == snapshot)

    var changed = delta
    changed.removedProjectIds = [project.id]
    #expect(GlobalProjectionReducer.changesProjection(changed))
}

@Test func globalProjectionReducerAppliesConversationChangesAndTombstones() {
    var retained = Dieter_V1_ConversationSnapshot(); retained.detail.card.id = "c_keep"
    var removed = Dieter_V1_ConversationSnapshot(); removed.detail.card.id = "c_remove"
    var snapshot = Dieter_V1_GlobalSnapshot(); snapshot.conversations = [retained, removed]
    retained.conversation.lastSeq = 9
    var added = Dieter_V1_ConversationSnapshot(); added.detail.card.id = "c_add"
    var delta = Dieter_V1_GlobalDelta()
    delta.conversations = [retained, added]
    delta.removedConversationIds = ["c_remove"]

    let reduced = GlobalProjectionReducer.applying(delta, to: snapshot)
    #expect(reduced.conversations.map { $0.detail.card.id } == ["c_keep", "c_add"])
    #expect(reduced.conversations.first?.conversation.lastSeq == 9)
}

@Test func directorySnapshotInvalidatesItsPreviousSyncCursor() throws {
    var cursor = Dieter_V1_SyncCursor()
    cursor.epoch = "epoch-one"
    cursor.sequence = 42
    var previous = Dieter_V1_GlobalSnapshot()
    var settings = Dieter_V1_Settings()
    settings.globalParallelLimit = 7
    previous.settings = settings
    var stale = Dieter_V1_Card()
    stale.id = "stale-card"
    previous.state.cards = [stale]

    var fresh = Dieter_V1_Card()
    fresh.id = "fresh-card"
    let replaced = DieterSyncProjectionCache.replacingMetadata(
        in: .init(cursor: try cursor.serializedData(), snapshot: try previous.serializedData()),
        projects: [],
        boards: [],
        cards: [fresh],
        chats: []
    )

    #expect(replaced.cursor == nil)
    let data = try #require(replaced.snapshot)
    let snapshot = try Dieter_V1_GlobalSnapshot(serializedBytes: data)
    #expect(snapshot.state.cards.map(\.id) == ["fresh-card"])
    #expect(snapshot.settings.globalParallelLimit == 7)
}

@Test func syncStreamLivenessRestartsAfterThreeMissedHeartbeats() {
    let lastFrame = Date(timeIntervalSince1970: 1_000)
    #expect(!SyncStreamLiveness.shouldRestart(
        lastFrameAt: lastFrame,
        now: lastFrame.addingTimeInterval(SyncStreamLiveness.timeout - 0.01)
    ))
    #expect(SyncStreamLiveness.shouldRestart(
        lastFrameAt: lastFrame,
        now: lastFrame.addingTimeInterval(SyncStreamLiveness.timeout)
    ))
    #expect(SyncStreamLiveness.shouldRestart(lastFrameAt: nil, now: lastFrame))
}

@Test func messageDeliveryReceiptsFollowOutboxAndSyncAcknowledgements() {
    #expect(MessageDeliveryState(pending: true, accepted: false, failed: false) == .local)
    #expect(MessageDeliveryState(pending: true, accepted: true, failed: false) == .accepted)
    #expect(MessageDeliveryState(pending: false, accepted: false, failed: false) == .synced)
    #expect(MessageDeliveryState(pending: true, accepted: false, failed: true) == .failed)
}

@Test @MainActor func macAttachmentSelectionPreservesBytesAndEnforcesTheSharedLimit() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "dieter-mac-attachments-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appending(path: "fixture.png")
    let document = root.appending(path: "notes.txt")
    try Data("png fixture".utf8).write(to: image)
    try Data("hello".utf8).write(to: document)

    let store = DieterStore()
    let parts = try store.attachmentParts([image, document])
    #expect(parts.count == 2)
    #expect(parts[0].filename == "fixture.png")
    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].data == Data("png fixture".utf8))
    #expect(parts[1].filename == "notes.txt")

    var rejected = false
    do {
        _ = try store.attachmentParts([image], appendingTo: Array(repeating: parts[0], count: 4))
    } catch {
        rejected = true
    }
    #expect(rejected)
}

@Test @MainActor func pastedMacImageBecomesAPngAttachmentWithoutALocalFileURL() async throws {
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
    let store = DieterStore()

    let parts = try await store.attachmentParts([provider])

    #expect(parts.count == 1)
    #expect(parts[0].type == "image")
    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].filename == "Pasted Image 1.png")
    #expect(parts[0].data == png)
}

@Test @MainActor func pastedMacTIFFScreenshotIsNormalizedToPortablePNG() async throws {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemPurple.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let provider = NSItemProvider(item: tiff as NSData, typeIdentifier: UTType.tiff.identifier)
    let store = DieterStore()

    let parts = try await store.attachmentParts([provider])

    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].filename == "Pasted Image 1.png")
    #expect(NSImage(data: parts[0].data) != nil)
}

@Test @MainActor func pasteboardImageDataBecomesAComposerAttachment() throws {
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setData(png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
    let store = DieterStore()

    let parts = try #require(try store.pasteboardAttachmentParts(pasteboard))

    #expect(parts.count == 1)
    #expect(parts[0].type == "image")
    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].filename == "Pasted Image 1.png")
    #expect(parts[0].data == png)
}

@Test @MainActor func pasteboardWithOnlyTextIsLeftForTheFocusedTextView() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("plain text", forType: .string)
    let store = DieterStore()

    #expect(try store.pasteboardAttachmentParts(pasteboard) == nil)
    #expect(!store.attachPasteboard(pasteboard))
    #expect(store.composerAttachments.isEmpty)
}

@Test func creatingTodoCardsDoesNotOpenTheirConversation() {
    #expect(!DieterStore.shouldOpenCreatedConversation(chat: false, lane: "todo"))
    #expect(!DieterStore.shouldOpenCreatedConversation(chat: false, lane: "Todo"))
    #expect(DieterStore.shouldOpenCreatedConversation(chat: false, lane: "running"))
    #expect(DieterStore.shouldOpenCreatedConversation(chat: true, lane: "todo"))
}

@Test @MainActor func pasteboardFileURLsAttachTheUnderlyingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "dieter-mac-pasteboard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "diagram.png")
    try Data("png fixture".utf8).write(to: file)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    let store = DieterStore()

    #expect(store.attachPasteboard(pasteboard))
    #expect(store.composerAttachments.count == 1)
    #expect(store.composerAttachments[0].filename == "diagram.png")
    #expect(store.composerAttachments[0].data == Data("png fixture".utf8))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_LIVE_ATTACHMENT_PORT"] != nil))
func liveMacAttachmentDraftRoundTripsThroughTheLocalDaemon() async throws {
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
    attachment.filename = "mac-fixture.png"
    attachment.data = Data("mac attachment fixture".utf8)
    var request = Dieter_V1_CreateConversationRequest()
    request.projectID = board.projectID
    request.boardID = board.id
    request.lane = "todo"
    request.title = "Mac attachment transport fixture"
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
        #expect(stored.filename == "mac-fixture.png")
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

private func dragCard(_ id: String, position: Int64) -> Dieter_V1_Card {
    var card = Dieter_V1_Card()
    card.id = id
    card.position = position
    return card
}

@Test func sidebarProjectPreferencesReorderAndReconcileAvailableProjects() {
    var preferences = SidebarProjectNavigationPreferences(projectOrder: ["p_two", "p_missing", "p_one"])

    #expect(preferences.orderedIDs(from: ["p_one", "p_two", "p_three"]) == ["p_two", "p_one", "p_three"])
    let movedToFront = preferences.move("p_three", before: "p_two", availableIDs: ["p_one", "p_two", "p_three"])
    #expect(movedToFront)
    #expect(preferences.orderedIDs(from: ["p_one", "p_two", "p_three"]) == ["p_three", "p_two", "p_one"])
    let movedToEnd = preferences.move("p_three", before: nil, availableIDs: ["p_one", "p_two", "p_three"])
    #expect(movedToEnd)
    #expect(preferences.orderedIDs(from: ["p_one", "p_two", "p_three"]) == ["p_two", "p_one", "p_three"])
    #expect(preferences.orderedIDs(from: ["p_one", "p_four"]) == ["p_one", "p_four"])
    let ignoredSelfMove = preferences.move("p_one", before: "p_one", availableIDs: ["p_one", "p_two"])
    #expect(!ignoredSelfMove)
}

@Test func sidebarProjectPreferencesPersistOrderAndExpandedStateAcrossReload() throws {
    let suite = "dieter-sidebar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // Projects are compressed by default; only explicit expansions persist.
    var preferences = SidebarProjectNavigationPreferences()
    #expect(!preferences.isExpanded("p_two"))
    _ = preferences.move("p_three", before: "p_one", availableIDs: ["p_one", "p_two", "p_three"])
    preferences.toggleExpanded("p_two")
    preferences.save(to: defaults)

    let restored = SidebarProjectNavigationPreferences.load(from: defaults)
    #expect(restored.orderedIDs(from: ["p_one", "p_two", "p_three"]) == ["p_three", "p_one", "p_two"])
    #expect(restored.isExpanded("p_two"))
    #expect(!restored.isExpanded("p_one"))
}

@Test func sidebarProjectDragPayloadRejectsOtherStringDrops() {
    let payload = SidebarProjectDragPayload(projectID: "p_one")
    #expect(SidebarProjectDragPayload(payload.encoded) == payload)
    #expect(SidebarProjectDragPayload("not-a-sidebar-project") == nil)
    #expect(SidebarProjectDragPayload("dieter:sidebar-project:") == nil)
}
