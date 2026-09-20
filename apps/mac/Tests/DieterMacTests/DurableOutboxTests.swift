import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import Testing
@testable import DieterMac

private func outboxTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "dieter-outbox-test-\(UUID().uuidString)")
}
private func journal(at root: URL, writer: OutboxJournal.Writer? = nil) -> OutboxJournal {
    OutboxJournal(
        url: root.appending(path: "pending.json"), writer: writer)
}
private func command(_ id: String) -> DieterOutboxEntry {
    .init(
        commandID: id, clientID: "test", endpointID: "machine", kind: .sendMessage,
        request: Data(), optimisticID: "msg_\(id)", attempts: 0, createdAt: Date(timeIntervalSince1970: 1))
}

@Test @MainActor func quickTaskIdentityIsFinalBeforeDeliveryAndTitleGeneration() async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = DurableOutbox(journal: journal(at: root))
    let store = DieterStore(outboxOverride: outbox, restoreSync: false)
    var project = Dieter_V1_Project()
    project.id = "project"
    store.projectDirectory = [project.id: project]
    store.selectedProjectID = project.id
    let enqueued = await store.createConversation(
        title: "Draft task", prompt: "Make this durable", chat: false,
        provider: "codex", model: "gpt-5.6-sol", effort: "high", deferred: false,
        lane: "running", autoGenerateTitle: true)
    #expect(enqueued)
    let entry = try #require(outbox.entries.first)
    let id = try #require(
        DieterOutboxPolicy.expectedConversationID(clientID: entry.clientID, commandID: entry.commandID))
    #expect(entry.optimisticID == id)
    #expect(store.selectedCardID == id)
    #expect(!store.isConversationServerBacked(id))
    await store.openConversation(cardID: id, chat: false)
    #expect(store.conversation?.conversation.cardID == id)
    #expect(store.conversation?.conversation.status == "pending")
    #expect(!store.conversationLoading)

    let target = DieterCore.WorkspaceTarget(endpointID: store.endpoint.id, projectID: "", conversationID: id)
    store.composer.select(target)
    store.composer.draft.text = "Follow-up while the title is generating"
    _ = store.retargetOptimisticConversation(from: id, to: id)
    #expect(store.composer.draft.text == "Follow-up while the title is generating")
    #expect(store.selectedCardID == id)

    var card = try #require(store.state.cards.first { $0.id == id })
    card.title = "Generated short title"
    card.runtime = "running"
    card.initialPromptSentAt = "2026-09-12T12:00:00Z"
    var snapshot = Dieter_V1_GlobalSnapshot()
    snapshot.state.projects = [project]
    snapshot.state.cards = [card]
    store.applyGlobalSnapshot(snapshot, endpointID: store.endpoint.id)
    store.rebuildOutboxOverlays()
    #expect(store.isConversationServerBacked(id))
    #expect(store.state.cards.map(\.id) == [id])
    #expect(store.state.cards.first?.title == "Generated short title")
    #expect(store.selectedCardID == id)
    #expect(store.composer.draft.text == "Follow-up while the title is generating")
}

@Test @MainActor func creationReportsJournalFailureWithoutAcceptingTheTask() async {
    let root = outboxTestRoot()
    let outbox = DurableOutbox(journal: journal(at: root, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
    let store = DieterStore(outboxOverride: outbox, restoreSync: false)
    let accepted = await store.createConversation(
        title: "Keep my draft", prompt: "A task", chat: false,
        provider: "codex", model: "gpt-5.6-sol", effort: "high", deferred: true)
    #expect(!accepted)
    #expect(outbox.entries.isEmpty)
    #expect(store.errorMessage != nil)
}

@Test @MainActor func outboxDiskFailurePreservesDraftAndPreventsAcceptance() async throws {
    let root = outboxTestRoot()
    let outbox = DurableOutbox(journal: journal(at: root, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
    let store = DieterStore(outboxOverride: outbox, restoreSync: false)
    store.selectedChatID = "conversation"
    store.composerText = "Must survive disk failure"
    await store.sendComposer()
    #expect(store.composerText == "Must survive disk failure")
    #expect(outbox.entries.isEmpty)
    #expect(store.pendingMessageIDs.isEmpty)
    #expect(store.outboxTask == nil)
    #expect(store.errorMessage != nil)
}

@Test func outboxConcurrentTransactionsDoNotLoseCommands() async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let value = journal(at: root)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<24 {
            group.addTask { _ = try await value.transaction { $0.append(command("\(index)")) } }
        }
        try await group.waitForAll()
    }
    let reloaded = try await journal(at: root).load()
    #expect(reloaded.entries.count == 24)
    #expect(Set(reloaded.entries.map(\.commandID)).count == 24)
}

@Test func outboxCorruptionIsReportedWithoutReplacingEvidence() async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "pending.json")
    let corrupt = Data("{broken pending commands".utf8)
    try corrupt.write(to: url)
    await #expect(throws: (any Error).self) { try await journal(at: root).load() }
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test @MainActor func composerDraftsStayWithTheirConversationAndSendRevision() {
    let model = ComposerModel()
    let first = DieterCore.WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "A")
    let second = DieterCore.WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "B")
    model.select(first); model.draft.text = "A"
    let pending = model.draft, revision = model.draft.revision
    model.select(second); model.draft.text = "B"
    pending.acceptSend(revision: revision)
    #expect(model.draft.text == "B")
    model.select(first); #expect(model.draft.text.isEmpty)
    model.draft.text = "C"
    let priorRevision = model.draft.revision
    model.draft.text = "D"
    model.draft.acceptSend(revision: priorRevision)
    #expect(model.draft.text == "D")
}

@Test @MainActor func composerDraftTextSurvivesModelRelaunchForCardsAndChats() {
    let suite = "DieterComposerDrafts.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let card = DieterCore.WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "card")
    let chat = DieterCore.WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "chat")

    var model: ComposerModel? = ComposerModel(defaults: defaults)
    model?.select(card)
    model?.draft.text = "Unsent card draft"
    model?.select(chat)
    model?.draft.text = "Unsent All Chats draft"
    model = nil

    let relaunched = ComposerModel(defaults: defaults)
    relaunched.select(card)
    #expect(relaunched.draft.text == "Unsent card draft")
    relaunched.select(chat)
    #expect(relaunched.draft.text == "Unsent All Chats draft")

    relaunched.draft.acceptSend(revision: relaunched.draft.revision)
    let afterSend = ComposerModel(defaults: defaults)
    afterSend.select(chat)
    #expect(afterSend.draft.text.isEmpty)
    afterSend.select(card)
    #expect(afterSend.draft.text == "Unsent card draft")
}

@Test(arguments: [false, true], [false, true]) @MainActor
func synchronizedCreateRemovesOptimisticRowBeforeOutboxJournalAcknowledgement(chat: Bool, stableID: Bool) async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = DurableOutbox(journal: journal(at: root))
    let store = DieterStore(outboxOverride: outbox, restoreSync: false)
    var project = Dieter_V1_Project()
    project.id = "project"
    store.projectDirectory = [project.id: project]
    store.projectReplicaEndpointIDs = [project.id: store.endpoint.id]
    store.selectedProjectID = project.id
    var request = Dieter_V1_CreateConversationRequest()
    request.projectID = project.id
    request.boardID = chat ? "" : "board"
    request.title = "Identical titles are valid"
    let entry = DieterOutboxEntry(
        commandID: "create-before-reply", clientID: "test", endpointID: store.endpoint.id,
        kind: chat ? .createChat : .createCard, request: try request.serializedData(),
        optimisticID: stableID
            ? try #require(
                DieterOutboxPolicy.expectedConversationID(clientID: "test", commandID: "create-before-reply"))
            : "local_create", attempts: 0, createdAt: Date())
    try await outbox.enqueue(entry)
    store.rebuildOutboxOverlays()
    #expect((chat ? store.chats : store.state.cards).map(\.id) == [entry.optimisticID])
    store.rebuildOutboxOverlays()
    #expect(!store.isConversationServerBacked(entry.optimisticID))

    var accepted = Dieter_V1_Card()
    accepted.id = try #require(
        DieterOutboxPolicy.expectedConversationID(clientID: entry.clientID, commandID: entry.commandID))
    accepted.projectID = project.id
    accepted.boardID = request.boardID
    accepted.scope = chat ? "chat" : "board"
    accepted.title = request.title
    accepted.runtime = "running"
    var unrelated = accepted
    unrelated.id = "c_another_same_title"
    var snapshot = Dieter_V1_GlobalSnapshot()
    snapshot.state.projects = [project]
    if chat { snapshot.state.chats = [accepted, unrelated] } else { snapshot.state.cards = [accepted, unrelated] }

    // This is the synchronous portion of the sync callback, before the
    // following await can acknowledge the command in the outbox journal.
    store.applyGlobalSnapshot(snapshot, endpointID: store.endpoint.id)
    for _ in 0..<3 {
        let rows = chat ? store.chats : store.state.cards
        #expect(rows.count == 2)
        #expect(rows.filter { $0.id == entry.optimisticID }.count == (stableID ? 1 : 0))
        #expect(store.isConversationServerBacked(accepted.id))
        #expect(rows.first { $0.id == accepted.id } == accepted)
        #expect(rows.first { $0.id == unrelated.id } == unrelated)
        #expect(outbox.entries == [entry])
        store.rebuildOutboxOverlays()
    }
}

private actor DelayedOutboxDelivery: OutboxRPC {
    private var pending: CheckedContinuation<Dieter_V1_SendMessageResponse, Never>?
    var requests: [Dieter_V1_SendMessageRequest] = []
    var started: Bool { pending != nil }
    func createCard(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        throw CancellationError()
    }
    func createChat(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        throw CancellationError()
    }
    func sendMessage(_ request: Dieter_V1_SendMessageRequest) async throws -> Dieter_V1_SendMessageResponse {
        requests.append(request)
        return await withCheckedContinuation { pending = $0 }
    }
    func finish() {
        var response = Dieter_V1_SendMessageResponse(); response.messageID = "server-message"
        pending?.resume(returning: response); pending = nil
    }
}

private actor ContendedOutboxDelivery: OutboxRPC {
    func createCard(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        throw CancellationError()
    }
    func createChat(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        throw CancellationError()
    }
    func sendMessage(_ request: Dieter_V1_SendMessageRequest) async throws -> Dieter_V1_SendMessageResponse {
        throw RPCError(code: .aborted, message: "conversation teardown is still in progress")
    }
}

private actor StorageOutboxDelivery: OutboxRPC {
    var requests: [Dieter_V1_SendMessageRequest] = []
    let failure: RPCError
    init(failure: RPCError) { self.failure = failure }
    func createCard(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        throw CancellationError()
    }
    func createChat(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        throw CancellationError()
    }
    func sendMessage(_ request: Dieter_V1_SendMessageRequest) async throws -> Dieter_V1_SendMessageResponse {
        requests.append(request)
        if requests.count == 1 { throw failure }
        return .with { $0.messageID = request.messageID }
    }
}

@Test(arguments: [
    RPCError(
        code: .resourceExhausted,
        message: "insufficient free disk space to start an agent turn: 122 MiB available; 2048 MiB required"),
    RPCError(code: .resourceExhausted, message: "write fixture: no space left on device"),
    RPCError(code: .resourceExhausted, message: "write fixture: disk quota exceeded"),
    RPCError(code: .resourceExhausted, message: "write fixture: disc quota exceeded"),
]) @MainActor
func storageBlockedMessageSurvivesRelaunchAndRetriesWithSameIdentity(failure: RPCError) async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 100)
    let rpc = StorageOutboxDelivery(failure: failure)
    let outbox = DurableOutbox(journal: journal(at: root))
    var entry = command("storage-once")
    let request = Dieter_V1_SendMessageRequest.with {
        $0.cardID = "card"; $0.clientID = entry.clientID
        $0.commandID = entry.commandID; $0.messageID = entry.optimisticID
        $0.parts = [
            .with {
                $0.type = "text"; $0.text = "Keep this message"
            }
        ]
    }
    entry.request = try request.serializedData()
    try await outbox.enqueue(entry)
    outbox.start(
        reachable: { ["machine"] }, acquire: { _ in OutboxTransport(rpc: rpc, release: {}) },
        committed: { _ in Issue.record("Storage-blocked message was committed") },
        failed: { _, _ in outbox.workerTask?.cancel() }, storageFailed: { Issue.record($0) },
        clock: ClientClock(now: { now }, sleep: { _ in throw CancellationError() }))
    await outbox.workerTask?.value
    let saved = try #require(try await journal(at: root).load().entries.first)
    #expect(saved.state == .retrying)
    #expect(saved.nextAttemptAt == now.addingTimeInterval(60))
    #expect(saved.request == entry.request)
    #expect(!DieterRPCFailure.isTransient(failure))
    #expect(
        MachineOutboxSummary.summaries(for: [saved])["machine"]?.toastPhase(machineOnline: true) == .waitingForStorage)
    #expect(DieterOutboxPolicy.nextIndex(in: [saved], endpointID: "machine", now: now.addingTimeInterval(59)) == nil)

    let relaunched = DurableOutbox(journal: journal(at: root))
    try await relaunched.restore()
    relaunched.start(
        reachable: { ["machine"] }, acquire: { _ in OutboxTransport(rpc: rpc, release: {}) },
        committed: { _ in }, failed: { _, error in Issue.record(error) }, storageFailed: { Issue.record($0) },
        clock: ClientClock(now: { now.addingTimeInterval(60) }, sleep: { _ in throw CancellationError() }))
    await relaunched.workerTask?.value
    #expect(await rpc.requests == [request, request])
    #expect(relaunched.entries.isEmpty)
    #expect(try await journal(at: root).load().entries.isEmpty)
    #expect(MachineOutboxSummary.summaries(for: relaunched.entries).isEmpty)
}

@Test func unrelatedResourceLimitsAndInvalidInputAreNotDiskPressure() {
    for message in ["concurrent stream limit reached", "global capacity exceeded", "invalid model"] {
        #expect(!DieterRPCFailure.isInsufficientStorage(message))
        #expect(DieterOutboxPolicy.backoff(after: 1, lastError: message) == 2)
    }
    #expect(DieterRPCFailure.isPermanent(RPCError(code: .invalidArgument, message: "invalid model")))
    #expect(DieterRPCFailure.isPermanent(RPCError(code: .permissionDenied, message: "no space left on device")))
}

@Test @MainActor func admissionContentionKeepsSendMessageQueuedForRetry() async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = DurableOutbox(journal: journal(at: root))
    var request = Dieter_V1_SendMessageRequest()
    request.cardID = "card"
    request.clientID = "test"
    request.commandID = "continue-once"
    request.messageID = "msg_continue_once"
    request.parts = [
        .with {
            $0.type = "text"; $0.text = "continue"
        }
    ]
    var entry = command(request.commandID)
    entry.request = try request.serializedData()
    try await outbox.enqueue(entry)
    outbox.start(
        reachable: { ["machine"] },
        acquire: { _ in OutboxTransport(rpc: ContendedOutboxDelivery(), release: {}) },
        committed: { _ in Issue.record("Contended message was committed") },
        failed: { _, _ in outbox.workerTask?.cancel() }, storageFailed: { Issue.record($0) })
    await outbox.workerTask?.value
    let saved = try #require(try await journal(at: root).load().entries.first)
    #expect(saved.commandID == request.commandID)
    #expect(saved.state == .retrying)
    #expect(saved.attempts == 1)
    #expect(saved.nextAttemptAt != nil)
}

@Test(arguments: ["chat", "running", "deferred", "todo"]) @MainActor
func savedDraftDoesNotAcknowledgeRequiredFirstTurn(mode: String) async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = DurableOutbox(journal: journal(at: root))
    let store = DieterStore(outboxOverride: outbox, restoreSync: false)
    var project = Dieter_V1_Project()
    project.id = "project"
    store.projectDirectory = [project.id: project]
    store.projectReplicaEndpointIDs = [project.id: store.endpoint.id]
    store.selectedProjectID = project.id
    let chat = mode == "chat" || mode == "deferred"
    let requiresStart = mode == "chat" || mode == "running"
    var request = Dieter_V1_CreateConversationRequest()
    request.projectID = project.id
    request.boardID = chat ? "" : "board"
    request.lane = mode == "running" ? "running" : "todo"
    request.deferStart = mode == "deferred"
    var entry = DieterOutboxEntry(
        commandID: "storage-retry", clientID: "test", endpointID: store.endpoint.id,
        kind: chat ? .createChat : .createCard, request: try request.serializedData(),
        optimisticID: "local_create", attempts: 1, createdAt: Date())
    entry.state = .retrying
    entry.lastError = "insufficient free disk space to start an agent turn"
    try await outbox.enqueue(entry)
    var draft = Dieter_V1_Card()
    draft.id = try #require(
        DieterOutboxPolicy.expectedConversationID(clientID: entry.clientID, commandID: entry.commandID))
    draft.projectID = request.projectID
    draft.boardID = request.boardID
    draft.scope = chat ? "chat" : "board"
    draft.runtime = "idle"
    var snapshot = Dieter_V1_GlobalSnapshot()
    snapshot.state.projects = [project]
    if chat { snapshot.state.chats = [draft] } else { snapshot.state.cards = [draft] }
    store.applyGlobalSnapshot(snapshot, endpointID: store.endpoint.id)
    store.syncSnapshot = snapshot
    await store.reconcileOutboxWithProjection()

    if requiresStart {
        #expect(outbox.entries == [entry])
        #expect(store.pendingCardIDs.contains(draft.id))
        #expect(store.failedCreationError(draft.id) == entry.lastError)
        #expect(store.failedCreationError(entry.optimisticID) == entry.lastError)
        #expect((chat ? store.chats : store.state.cards).map(\.id) == [draft.id])
        #expect(try await journal(at: root).load().entries == [entry])

        draft.initialPromptSentAt = "2026-09-11T20:30:00Z"
        draft.runtime = "running"
        if chat { snapshot.state.chats = [draft] } else { snapshot.state.cards = [draft] }
        store.applyGlobalSnapshot(snapshot, endpointID: store.endpoint.id)
        store.syncSnapshot = snapshot
        await store.reconcileOutboxWithProjection()
    }
    #expect(outbox.entries.isEmpty)
    #expect(!store.pendingCardIDs.contains(draft.id))
    #expect(store.failedCreationError(draft.id) == nil)
}

private actor UnstartedCreationDelivery: OutboxRPC {
    func createCard(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        var card = Dieter_V1_Card()
        card.id = "saved-draft"
        card.runtime = "idle"
        return card
    }
    func createChat(_ request: Dieter_V1_CreateConversationRequest) async throws -> Dieter_V1_Card {
        try await createCard(request)
    }
    func sendMessage(_ request: Dieter_V1_SendMessageRequest) async throws -> Dieter_V1_SendMessageResponse {
        throw CancellationError()
    }
}

@Test @MainActor func outboxRejectsLegacyDaemonAcknowledgementForUnstartedChat() async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = DurableOutbox(journal: journal(at: root))
    var request = Dieter_V1_CreateConversationRequest()
    request.prompt = "Start this chat"
    let entry = DieterOutboxEntry(
        commandID: "unstarted", clientID: "test", endpointID: "machine", kind: .createChat,
        request: try request.serializedData(), optimisticID: "local_unstarted", attempts: 0, createdAt: Date())
    try await outbox.enqueue(entry)
    var failed = false
    outbox.start(
        reachable: { ["machine"] },
        acquire: { _ in OutboxTransport(rpc: UnstartedCreationDelivery(), release: {}) },
        committed: { _ in Issue.record("An unstarted chat was acknowledged") },
        failed: { _, _ in failed = true }, storageFailed: { Issue.record($0) })
    await outbox.workerTask?.value
    let saved = try #require(try await journal(at: root).load().entries.first)
    #expect(failed)
    #expect(saved.serverID == nil)
    #expect(saved.state == .failed)
    #expect(saved.lastError?.contains("first turn was not started") == true)
}

@Test @MainActor func retiredOutboxWorkerPersistsAcknowledgementWithoutPublishingIntoSuccessor() async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = DurableOutbox(journal: journal(at: root)), rpc = DelayedOutboxDelivery()
    var request = Dieter_V1_SendMessageRequest(); request.cardID = "card_A"; request.commandID = "stable-command";
    request.clientID = "test"
    var entry = command("stable-command"); entry.request = try request.serializedData()
    try await outbox.enqueue(entry)
    var published = false, released = 0
    outbox.start(
        reachable: { ["machine"] },
        acquire: { _ in
            OutboxTransport(rpc: rpc, release: { released += 1 })
        }, committed: { _ in published = true }, failed: { _, error in Issue.record(error) },
        storageFailed: { Issue.record($0) })
    for _ in 0..<10_000 {
        if await rpc.started { break }
        await Task.yield()
    }
    #expect(await rpc.started)
    let worker = outbox.workerTask
    worker?.cancel()
    outbox.workerGeneration &+= 1
    await rpc.finish()
    await worker?.value
    #expect(!published)
    #expect(released == 1)
    #expect(try await journal(at: root).load().entries.isEmpty)
    #expect(await rpc.requests.map(\.commandID) == ["stable-command"])
}

@Test func existingOutboxAboveAdmissionLimitCanDrainWithoutAcceptingMoreCommands() async throws {
    let root = outboxTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let commands = (0..<(OutboxJournal.entryLimit + 2)).map { command("saved-\($0)") }
    var snapshot = OutboxJournal.Snapshot()
    snapshot.entries = commands
    try JSONEncoder().encode(snapshot).write(to: root.appending(path: "pending.json"))
    let value = journal(at: root)
    #expect(try await value.load().entries.count == commands.count)
    let drained = try await value.transaction { $0.removeFirst() }
    #expect(drained.0.entries.count == commands.count - 1)
    await #expect(throws: OutboxStorageError.self) {
        _ = try await value.transaction { $0.append(command("new")) }
    }
    #expect(try await journal(at: root).load().entries.count == commands.count - 1)
}
