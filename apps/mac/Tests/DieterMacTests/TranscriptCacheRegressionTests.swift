import DieterAPI
import DieterCore
import Foundation
import Testing
@testable import DieterMac

private func transcript(_ sequence: Int64, time: String = "2026-09-20T12:00:00Z") -> Dieter_V1_ConversationSnapshot {
    var value = Dieter_V1_ConversationSnapshot()
    value.detail.card.id = "chat"
    value.conversation.cardID = "chat"
    value.conversation.lastSeq = sequence
    value.conversation.updatedAt = time
    var message = Dieter_V1_UiMessage()
    message.id = "message-\(sequence)"
    value.conversation.messages = [message]
    value.page.total = Int32(sequence)
    return value
}

@Test func transcriptCacheRejectsDelayedGlobalDeltaButAcceptsMetadata() {
    var current = Dieter_V1_GlobalSnapshot()
    current.conversations = [transcript(20)]
    var delta = Dieter_V1_GlobalDelta()
    var old = transcript(10)
    old.detail.card.title = "Renamed"
    delta.conversations = [old]
    let result = GlobalProjectionReducer.applying(delta, to: current)
    #expect(result.conversations[0].conversation == current.conversations[0].conversation)
    #expect(result.conversations[0].page == current.conversations[0].page)
    #expect(result.conversations[0].detail.card.title == "Renamed")
    delta.conversations = [transcript(21)]
    #expect(GlobalProjectionReducer.applying(delta, to: result).conversations[0].conversation.lastSeq == 21)
    delta.removedConversationIds = ["chat"]
    #expect(GlobalProjectionReducer.applying(delta, to: result).conversations.isEmpty)
}

@Test func transcriptCacheUsesDaemonTimeForSameSequence() {
    let latest = transcript(20, time: "2026-09-20T12:05:00Z")
    #expect(TranscriptFreshness.merging(transcript(20), with: latest).conversation == latest.conversation)
    let newer = transcript(20, time: "2026-09-20T12:06:00Z")
    #expect(TranscriptFreshness.merging(newer, with: latest) == newer)
}

@Test @MainActor func transcriptCacheSurvivesMachineSwitchAndPersistence() async throws {
    let environment = DieterAppEnvironment.testing()
    defer { if let root = environment.storageRoot { try? FileManager.default.removeItem(at: root) } }
    let store = DieterStore(environment: environment, restoreSync: false)
    let machine = store.endpoint
    var initial = Dieter_V1_GlobalSnapshot()
    initial.conversations = [transcript(10)]
    store.syncSnapshot = initial
    store.syncProjection = .init(cursor: nil, snapshot: try initial.serializedData())
    store.syncDiskState.projections[machine.id] = store.syncProjection
    await store.cacheConversation(transcript(20), endpointID: machine.id, refreshedAt: Date())
    try await store.saveSyncPersistence()
    let persisted = await store.syncPersistence.load()
    let persistedData = try #require(persisted.projections[machine.id]?.snapshot)
    #expect(try Dieter_V1_GlobalSnapshot(serializedBytes: persistedData).conversations[0].conversation.lastSeq == 20)
    store.endpoint = DieterEndpoint(name: "Other", host: "localhost", port: 2, daemonID: "other")
    store.syncSnapshot = nil
    #expect(await store.projectedConversation(cardID: "chat", endpointID: machine.id)?.conversation.lastSeq == 20)
    let data = try #require(store.syncDiskState.projections[machine.id]?.snapshot)
    store.endpoint = machine
    store.activateSyncProjection(for: machine, decodedSnapshot: try .init(serializedBytes: data), decodedData: data)
    #expect(await store.projectedConversation(cardID: "chat", endpointID: machine.id)?.conversation.lastSeq == 20)
}

@Test @MainActor func transcriptCacheSurvivesDelayedAndOmittedGlobalSnapshot() async {
    let environment = DieterAppEnvironment.testing()
    defer { if let root = environment.storageRoot { try? FileManager.default.removeItem(at: root) } }
    let store = DieterStore(environment: environment, restoreSync: false)
    var current = Dieter_V1_GlobalSnapshot()
    current.conversations = [transcript(20)]
    store.syncSnapshot = current
    var frame = Dieter_V1_SyncFrame()
    frame.snapshot.conversations = [transcript(10)]
    await store.applySyncFrame(frame, endpointID: store.endpoint.id)
    #expect(store.syncSnapshot?.conversations.first?.conversation.lastSeq == 20)
    frame.snapshot = .init()
    await store.applySyncFrame(frame, endpointID: store.endpoint.id)
    #expect(
        await store.projectedConversation(cardID: "chat", endpointID: store.endpoint.id)?.conversation.lastSeq == 20)
}

@Test @MainActor func transcriptCacheRejectsDelayedReadAndWatchUpdates() async {
    let model = ConversationModel()
    model.selectedChatID = "chat"
    await model.acceptConversation(transcript(20), chat: true)
    await model.acceptConversation(transcript(10), chat: true)
    #expect(model.conversation?.conversation.lastSeq == 20)
    var update = Dieter_V1_ConversationUpdate()
    update.snapshot = transcript(9)
    model.apply(update)
    #expect(model.conversation?.conversation.lastSeq == 20)
    update = .init()
    update.lastSeq = 8
    update.updatedAt = "2026-09-20T12:00:00Z"
    update.removedMessageIds = ["message-20"]
    model.apply(update)
    #expect(model.conversation?.conversation.messages.first?.id == "message-20")
    update = .init()
    update.snapshot = transcript(21)
    model.apply(update)
    #expect(model.conversation?.conversation.lastSeq == 21)
}

@Test @MainActor func transcriptCacheConcurrentInactiveWritesKeepBothChats() async {
    let environment = DieterAppEnvironment.testing()
    defer { if let root = environment.storageRoot { try? FileManager.default.removeItem(at: root) } }
    let store = DieterStore(environment: environment, restoreSync: false)
    var other = transcript(30)
    other.detail.card.id = "other-chat"
    other.conversation.cardID = "other-chat"
    let first = Task { await store.cacheConversation(transcript(20), endpointID: "inactive", refreshedAt: Date()) }
    let second = Task { await store.cacheConversation(other, endpointID: "inactive", refreshedAt: Date()) }
    await first.value
    await second.value
    #expect(await store.projectedConversation(cardID: "chat", endpointID: "inactive")?.conversation.lastSeq == 20)
    #expect(await store.projectedConversation(cardID: "other-chat", endpointID: "inactive")?.conversation.lastSeq == 30)
}
