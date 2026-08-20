import Testing
import NauclioAPI
import AppKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import UniformTypeIdentifiers
@testable import NauclioMac

@Test func unreachableEndpointSurvivesConnectionBackoffAndShutdown() async throws {
    let endpoint = try #require(NauclioEndpoint.parse("127.0.0.1:1"))
    let client = try NauclioRPC(endpoint: endpoint)
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

@Test func parsesNauclioEndpointWithDefaultPort() {
    let endpoint = NauclioEndpoint.parse("board.local", name: "Office")
    #expect(endpoint?.name == "Office")
    #expect(endpoint?.host == "board.local")
    #expect(endpoint?.port == 4242)
}

@Test func parsesNauclioEndpointWithExplicitPort() {
    let endpoint = NauclioEndpoint.parse("127.0.0.1:50051")
    #expect(endpoint?.address == "http://127.0.0.1:50051")
    #expect(NauclioEndpoint.parse("127.0.0.1:70000") == nil)
}

@Test func parsesSecureNauclioEndpointWithHTTPSDefaultPort() {
    let endpoint = NauclioEndpoint.parse("https://nauclio.example", name: "Public")
    #expect(endpoint?.host == "nauclio.example")
    #expect(endpoint?.port == 443)
    #expect(endpoint?.secure == true)
    #expect(endpoint?.address == "https://nauclio.example:443")
}

@Test func transportTargetsDoNotSendIPAddressesAsTLSServerNames() {
    #expect(NauclioTransportTarget.hostKind("127.0.0.1") == .ipv4)
    #expect(NauclioTransportTarget.hostKind("::1") == .ipv6)
    #expect(NauclioTransportTarget.hostKind("fe80::1%en0") == .ipv6)
    #expect(NauclioTransportTarget.hostKind("board.dbpprt.com") == .dns)

    #expect(NauclioTransportTarget.make(host: "127.0.0.1", port: 4242) is ResolvableTargets.IPv4)
    #expect(NauclioTransportTarget.make(host: "::1", port: 4242) is ResolvableTargets.IPv6)
    #expect(NauclioTransportTarget.make(host: "board.dbpprt.com", port: 443) is ResolvableTargets.DNS)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NAUCLIO_LIVE_DIRECT_PORT"] != nil))
func liveDirectRouteCompletesTLSAndReachesDaemonAuthentication() async throws {
    struct StoredIdentity: Decodable {
        let id: String
        let daemonCaPem: Data
    }

    let port = try #require(Int(ProcessInfo.processInfo.environment["NAUCLIO_LIVE_DIRECT_PORT"] ?? ""))
    let identityURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".nauclio/daemon/identity.json")
    let identity = try JSONDecoder().decode(StoredIdentity.self, from: Data(contentsOf: identityURL))
    let endpoint = NauclioEndpoint(name: "Live direct route", host: "127.0.0.1", port: port, daemonID: identity.id)
    let client = try NauclioRPC(
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

@Test func daemonEndpointKeepsHostnamePresenceAndGatewayCredentialIdentity() throws {
    let endpoint = NauclioEndpoint(
        name: "Studio Mac",
        host: "nauclio.example",
        port: 443,
        secure: true,
        daemonID: "daemon-1",
        online: false,
        lastSeenAt: "2026-08-18T12:00:00Z",
        version: "2"
    )
    #expect(endpoint.id == "https://nauclio.example:443#daemon-1")
    #expect(endpoint.credentialID == "https://nauclio.example:443")
    #expect(endpoint.name == "Studio Mac")
    #expect(!endpoint.online)
    #expect(endpoint.gatewayEndpoint.daemonID == nil)
    #expect(endpoint.gatewayEndpoint.credentialID == endpoint.credentialID)
    #expect(NauclioRPC.Route.gateway.daemonID == nil)
    #expect(NauclioRPC.Route.relay(daemonID: "daemon-1").daemonID == "daemon-1")

    let decoded = try JSONDecoder().decode(NauclioEndpoint.self, from: JSONEncoder().encode(endpoint))
    #expect(decoded == endpoint)
}

@Test func credentialFileStorePersistsUpdatesAndRemovalWithUserOnlyPermissions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "board-credential-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "gateway-sessions.json", directoryHint: .notDirectory)
    let credentialID = "https://nauclio.example:443"
    let otherCredentialID = "https://other.example:443"

    let store = NauclioCredentialFileStore(fileURL: fileURL)
    try await store.save("first", for: credentialID)
    try await store.save("second", for: credentialID)
    try await store.save("other", for: otherCredentialID)

    let reloaded = NauclioCredentialFileStore(fileURL: fileURL)
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

@Test func conversationScrollBehaviorUsesANearBottomThreshold() {
    #expect(ConversationScrollBehavior.isNearBottom(visibleMaxY: 928, contentHeight: 1_000))
    #expect(!ConversationScrollBehavior.isNearBottom(visibleMaxY: 927, contentHeight: 1_000))
    #expect(ConversationScrollBehavior.isNearBottom(visibleMaxY: 500, contentHeight: 400))
}

@Test func conversationScrollBehaviorDistinguishesUserNavigationFromContentGrowth() {
    let initial = ConversationViewport(offsetY: 400, visibleMaxY: 900, contentHeight: 1_000)
    let userScrolled = ConversationViewport(offsetY: 250, visibleMaxY: 750, contentHeight: 1_000)
    let messageArrived = ConversationViewport(offsetY: 400, visibleMaxY: 900, contentHeight: 1_180)

    #expect(ConversationScrollBehavior.isUserNavigation(from: initial, to: userScrolled))
    #expect(!ConversationScrollBehavior.isUserNavigation(from: initial, to: messageArrived))
}

@Test func chatActivityTextUsesCompactUnits() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-19T12:00:00Z"))
    #expect(ChatActivityText.compact("2026-08-19T11:59:35Z", relativeTo: now) == "now")
    #expect(ChatActivityText.compact("2026-08-19T11:55:00Z", relativeTo: now) == "5m")
    #expect(ChatActivityText.compact("2026-08-19T10:00:00Z", relativeTo: now) == "2h")
}

@Test func assistantMessagePartsCollapseAdjacentToolCallsIntoGroups() {
    var intro = Nauclio_V1_MessagePart()
    intro.type = "text"
    intro.text = "Starting"
    var bash = Nauclio_V1_MessagePart()
    bash.type = "dynamic-tool"
    bash.toolName = "Bash"
    var edit = Nauclio_V1_MessagePart()
    edit.type = "tool-call"
    edit.toolName = "Edit"
    var result = Nauclio_V1_MessagePart()
    result.type = "text"
    result.text = "Finished"
    var browser = Nauclio_V1_MessagePart()
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

@Test func adjacentToolOnlyAssistantMessagesCollapseIntoOneStableTimelineGroup() {
    var firstTool = Nauclio_V1_MessagePart()
    firstTool.type = "dynamic-tool"
    firstTool.toolCallID = "tool_1"
    firstTool.toolName = "exec_command"
    var secondTool = Nauclio_V1_MessagePart()
    secondTool.type = "tool-call"
    secondTool.toolCallID = "tool_2"
    secondTool.toolName = "apply_patch"
    var text = Nauclio_V1_MessagePart()
    text.type = "text"
    text.text = "Implemented."

    var first = Nauclio_V1_UiMessage()
    first.id = "message_1"
    first.role = "assistant"
    first.parts = [firstTool]
    var second = Nauclio_V1_UiMessage()
    second.id = "message_2"
    second.role = "assistant"
    second.parts = [secondTool]
    var result = Nauclio_V1_UiMessage()
    result.id = "message_3"
    result.role = "assistant"
    result.parts = [text]

    let items = ConversationTimelineItem.group([first, second, result])

    #expect(items.count == 2)
    #expect(items[0].id == "tools:message_1")
    #expect(items[0].toolCalls.map(\.part.toolName) == ["exec_command", "apply_patch"])
    #expect(items[1].id == "message:message_3")
}

@Test func toolCallGroupSummaryMatchesCompactEditAndCommandLabels() {
    #expect(ToolCallGroupSummary(toolNames: ["Bash"]).title == "1 command")
    #expect(ToolCallGroupSummary(toolNames: Array(repeating: "Edit", count: 14) + Array(repeating: "exec_command", count: 7)).title == "14 edits, 7 commands")
    #expect(ToolCallGroupSummary(toolNames: ["browser.open", "mcp/custom"]).title == "2 tool calls")
}

@Test func conversationContextUsageReadsHarnessMetadata() throws {
    var message = Nauclio_V1_UiMessage()
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
    #expect(KanbanLaneSizing.laneWidth(availableWidth: 680, laneCount: 4) == 156.25)
    #expect(KanbanLaneSizing.contentWidth(availableWidth: 680, laneCount: 4) == 680)
    #expect(KanbanLaneSizing.laneWidth(availableWidth: 520, laneCount: 4) == KanbanLaneSizing.minimumWidth)
    #expect(KanbanLaneSizing.contentWidth(availableWidth: 520, laneCount: 4) == 655)
}

@Test func boardCreationOptionsMatchTheServerContract() {
    #expect(BoardWorkflow.allCases.map(\.rawValue) == ["review", "direct"])
    #expect(DoneArchivePolicy.allCases.map(\.rawValue) == [
        "never", "immediately", "after_1_day", "after_7_days", "after_30_days", "after_90_days",
    ])
}

@Test func settingsAreFirstClassNestedNavigationDestinations() {
    #expect(AppSection.allCases.contains(.settings))
    #expect(NauclioSettingsSection.allCases.map(\.rawValue) == [
        "General", "Connection", "Prompts", "Notifications", "Agents",
    ])
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

@Test func globalProjectionAndOutboxSurviveRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "board-sync-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = NauclioSyncPersistence(root: root)

    var cursor = Nauclio_V1_SyncCursor()
    cursor.epoch = "epoch-one"
    cursor.sequence = 42
    cursor.projectionVersion = 1
    var project = Nauclio_V1_Project()
    project.id = "p_one"
    project.name = "One"
    var snapshot = Nauclio_V1_GlobalSnapshot()
    snapshot.state.projects = [project]
    var request = Nauclio_V1_SendMessageRequest()
    request.cardID = "c_one"
    request.commandID = "command-one"
    request.clientID = "mac-one"
    request.messageID = "msg_one"
    let entry = NauclioOutboxEntry(
        commandID: request.commandID,
        clientID: request.clientID,
        daemonID: "daemon-one",
        kind: .sendMessage,
        request: try request.serializedData(),
        optimisticID: request.messageID,
        attempts: 0,
        createdAt: Date(timeIntervalSince1970: 1)
    )
    try await persistence.save(.init(cursor: try cursor.serializedData(), snapshot: try snapshot.serializedData(), outbox: [entry]))

    let restored = await NauclioSyncPersistence(root: root).load()
    let cursorData = try #require(restored.cursor)
    let snapshotData = try #require(restored.snapshot)
    let restoredCursor = try Nauclio_V1_SyncCursor(serializedBytes: cursorData)
    let restoredSnapshot = try Nauclio_V1_GlobalSnapshot(serializedBytes: snapshotData)
    #expect(restoredCursor.sequence == 42)
    #expect(restoredSnapshot.state.projects.first?.id == "p_one")
    #expect(restored.outbox.first?.optimisticID == "msg_one")
}

@Test func messageDeliveryReceiptsFollowOutboxAndSyncAcknowledgements() {
    #expect(MessageDeliveryState(pending: true, accepted: false, failed: false) == .local)
    #expect(MessageDeliveryState(pending: true, accepted: true, failed: false) == .accepted)
    #expect(MessageDeliveryState(pending: false, accepted: false, failed: false) == .synced)
    #expect(MessageDeliveryState(pending: true, accepted: false, failed: true) == .failed)
}

@Test @MainActor func macAttachmentSelectionPreservesBytesAndEnforcesTheSharedLimit() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "nauclio-mac-attachments-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appending(path: "fixture.png")
    let document = root.appending(path: "notes.txt")
    try Data("png fixture".utf8).write(to: image)
    try Data("hello".utf8).write(to: document)

    let store = NauclioStore()
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
    let store = NauclioStore()

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
    let store = NauclioStore()

    let parts = try await store.attachmentParts([provider])

    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].filename == "Pasted Image 1.png")
    #expect(NSImage(data: parts[0].data) != nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NAUCLIO_LIVE_ATTACHMENT_PORT"] != nil))
func liveMacAttachmentDraftRoundTripsThroughTheLocalDaemon() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["NAUCLIO_LIVE_ATTACHMENT_PORT"] ?? ""))
    let endpoint = try #require(NauclioEndpoint.parse("127.0.0.1:\(port)", name: "Attachment fixture"))
    let client = try NauclioRPC(endpoint: endpoint)
    let connection = Task { try? await client.run() }
    defer {
        connection.cancel()
        client.shutdown()
    }

    let state = try await client.state()
    let board = try #require(state.boards.first { board in board.lanes.contains { $0.id == "todo" } })
    let catalog = try await client.harnesses()
    let harness = try #require(catalog.harnesses.first)
    var attachment = Nauclio_V1_MessagePart()
    attachment.type = "image"
    attachment.mediaType = "image/png"
    attachment.filename = "mac-fixture.png"
    attachment.data = Data("mac attachment fixture".utf8)
    var request = Nauclio_V1_CreateConversationRequest()
    request.projectID = board.projectID
    request.boardID = board.id
    request.lane = "todo"
    request.title = "Mac attachment transport fixture"
    request.prompt = "Keep this deferred and verify its attachment."
    request.provider = harness.id
    request.model = harness.defaultModel
    request.deferStart = true
    request.attachments = [attachment]

    var created: Nauclio_V1_Card?
    do {
        let card = try await client.createCard(request)
        created = card
        let snapshot = try await client.conversation(cardID: card.id)
        let stored = try #require(snapshot.conversation.draftAttachments.first)
        #expect(stored.filename == "mac-fixture.png")
        #expect(stored.mediaType == "image/png")
        #expect(stored.data == Data("mac attachment fixture".utf8))
        var archive = Nauclio_V1_ArchiveCardRequest()
        archive.cardID = card.id
        archive.archived = true
        _ = try await client.archiveCard(archive)
        created = nil
    } catch {
        if let created {
            var archive = Nauclio_V1_ArchiveCardRequest()
            archive.cardID = created.id
            archive.archived = true
            _ = try? await client.archiveCard(archive)
        }
        throw error
    }
}

private func dragCard(_ id: String, position: Int64) -> Nauclio_V1_Card {
    var card = Nauclio_V1_Card()
    card.id = id
    card.position = position
    return card
}
