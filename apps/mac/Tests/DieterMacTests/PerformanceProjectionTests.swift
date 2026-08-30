import AppKit
import DieterAPI
import Foundation
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func islandProjectionIgnoresActivityIrrelevantCardChanges() {
    let store = DieterStore(restoreSync: false)
    var card = Dieter_V1_Card()
    card.id = "card-one"
    card.projectID = "project-one"
    card.boardID = "board-one"
    card.runtime = "running"
    card.runtimeUpdatedAt = "2026-08-30T12:00:00.000Z"
    store.navigationCards = [card.projectID: [card]]

    let initialRevision = store.islandActivityProjectionRevision
    #expect(store.islandActivity.runningCount == 1)

    card.workspace.changedFiles = 12
    card.workspace.additions = 500
    store.navigationCards = [card.projectID: [card]]
    #expect(store.islandActivityProjectionRevision == initialRevision)

    card.runtime = "waiting_for_user"
    store.navigationCards = [card.projectID: [card]]
    #expect(store.islandActivityProjectionRevision == initialRevision + 1)
    #expect(store.islandActivity.runningCount == 0)
}

@Test func boardProjectionBuildsLaneAndLabelIndexesOnce() {
    var first = Dieter_V1_Card()
    first.id = "first"
    first.boardID = "board"
    first.lane = "todo"
    first.runtime = "waiting"
    first.title = "Matching card"
    first.labelIds = ["label-one", "label-two"]
    var second = Dieter_V1_Card()
    second.id = "second"
    second.boardID = "board"
    second.lane = "done"
    second.runtime = "completed"
    second.labelIds = ["label-one"]
    var unrelated = Dieter_V1_Card()
    unrelated.id = "unrelated"
    unrelated.boardID = "other"

    let projection = BoardProjection.resolve(
        cards: [first, second, unrelated],
        boardID: "board",
        runtimeFilter: "waiting",
        labelFilter: "label-two",
        query: "matching"
    )

    #expect(projection.cards.map(\.id) == ["first", "second"])
    #expect(projection.displayedCards.map(\.id) == ["first"])
    #expect(projection.displayedCardsByLane["todo"]?.map(\.id) == ["first"])
    #expect(projection.labelCounts == ["label-one": 2, "label-two": 1])
}

@Test func machinePresenceExpirationLeavesEqualDirectoriesUntouched() {
    let now = Date(timeIntervalSince1970: 1_000)
    var endpoint = DieterEndpoint(name: "Machine", host: "localhost", port: 443, secure: true)
    endpoint.daemonID = "daemon"
    endpoint.online = true
    endpoint.lastSeenAt = DieterTimestamp.string(from: now.addingTimeInterval(-5))
    let current = [endpoint]

    #expect(MachinePresenceText.applyingExpirations(to: current, relativeTo: now) == current)
    #expect(MachinePresenceText.nextExpiration(in: current, relativeTo: now) == now.addingTimeInterval(25))

    let expired = MachinePresenceText.applyingExpirations(
        to: current,
        relativeTo: now.addingTimeInterval(31)
    )
    #expect(expired.first?.online == false)
}

@Test @MainActor func messageOnlySyncReplayDoesNotRecomputeIslandOrRewriteProjection() async {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "dieter-sync-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = DieterSyncPersistence(root: root)
    let store = DieterStore(syncPersistenceOverride: persistence, restoreSync: false)

    var project = Dieter_V1_Project()
    project.id = "project-one"
    project.name = "One"
    var card = Dieter_V1_Card()
    card.id = "card-one"
    card.projectID = project.id
    card.boardID = "board-one"
    card.title = "Streaming conversation"
    card.runtime = "running"
    card.runtimeUpdatedAt = "2026-08-30T12:00:00.000Z"
    var snapshot = Dieter_V1_GlobalSnapshot()
    snapshot.state.projects = [project]
    snapshot.state.cards = [card]
    var initial = Dieter_V1_SyncFrame()
    initial.snapshot = snapshot
    initial.cursor.epoch = "epoch-one"
    initial.cursor.sequence = 1
    await store.applySyncFrame(initial, endpointID: store.endpoint.id)

    let islandRevision = store.islandActivityProjectionRevision
    let initialPersistence = await persistence.metrics()
    #expect(store.islandActivity.runningCount == 1)
    #expect(initialPersistence.acceptedSaveCount == 1)

    store.selectedCardID = card.id
    for sequence in 2...1_001 {
        var message = Dieter_V1_UiMessage()
        message.id = "message-\(sequence)"
        message.role = "assistant"
        var conversation = Dieter_V1_ConversationSnapshot()
        conversation.detail.card = card
        conversation.conversation.cardID = card.id
        conversation.conversation.messages = [message]
        var delta = Dieter_V1_GlobalDelta()
        delta.conversations = [conversation]
        var frame = Dieter_V1_SyncFrame()
        frame.delta = delta
        frame.cursor.epoch = "epoch-one"
        frame.cursor.sequence = UInt64(sequence)
        await store.applySyncFrame(frame, endpointID: store.endpoint.id)
    }

    let finalPersistence = await persistence.metrics()
    #expect(store.islandActivityProjectionRevision == islandRevision)
    #expect(finalPersistence.acceptedSaveCount == 1)

    var heartbeat = Dieter_V1_SyncFrame()
    heartbeat.heartbeat = true
    heartbeat.cursor.epoch = "epoch-one"
    heartbeat.cursor.sequence = 1_002
    await store.applySyncFrame(heartbeat, endpointID: store.endpoint.id)
    let heartbeatPersistence = await persistence.metrics()
    #expect(heartbeatPersistence.acceptedSaveCount == 1)
    while await persistence.metrics().writeCount == 0 { await Task.yield() }
}

@Test func persistenceKeepsOnlyOneSupersedingPendingWrite() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "dieter-sync-coalescing-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = BlockingPersistenceWriter()
    let persistence = DieterSyncPersistence(root: root, writer: writer.write)

    await persistence.scheduleSave(.empty)
    while writer.startedWrites == 0 { await Task.yield() }

    for sequence in 1...99 {
        var state = DieterSyncDiskState.empty
        state.cursor = Data(String(sequence).utf8)
        await persistence.scheduleSave(state)
    }
    var final = DieterSyncDiskState.empty
    final.cursor = Data("latest".utf8)
    let finalSave = Task { try await persistence.save(final) }
    while await persistence.metrics().acceptedSaveCount < 101 { await Task.yield() }
    writer.releaseFirstWrite()
    try await finalSave.value

    let metrics = await persistence.metrics()
    #expect(metrics.acceptedSaveCount == 101)
    #expect(metrics.writeCount == 2)
    #expect(metrics.logicalBytesWritten == 2)
}

@Test func checkpointPersistenceDebouncesAStreamingBurstToOneWrite() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "dieter-sync-debounce-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = RecordingPersistenceWriter()
    let persistence = DieterSyncPersistence(
        root: root,
        writer: writer.write,
        checkpointDelayNanoseconds: 20_000_000
    )

    for sequence in 1...100 {
        var state = DieterSyncDiskState.empty
        state.cursor = Data("\(sequence)".utf8)
        await persistence.scheduleCheckpoint(.init(diskState: state))
    }
    let deadline = Date().addingTimeInterval(1)
    while await persistence.metrics().writeCount == 0, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }

    let metrics = await persistence.metrics()
    #expect(metrics.acceptedSaveCount == 100)
    #expect(metrics.writeCount == 1)
    #expect(writer.lastCursor == Data("100".utf8))
}

@Test func conversationRenderWindowBoundsTheLiveView() {
    #expect(ConversationRenderWindow.range(messageCount: 20, requestedStart: nil) == 0..<20)
    #expect(ConversationRenderWindow.range(messageCount: 500, requestedStart: nil) == 320..<500)
    #expect(ConversationRenderWindow.range(messageCount: 500, requestedStart: 0) == 0..<180)
    #expect(ConversationRenderWindow.range(messageCount: 500, requestedStart: 450) == 320..<500)
}

@Test func diffProjectionIndexesCommentsWhileBuildingRows() {
    let patch = """
    diff --git a/Sample.swift b/Sample.swift
    --- a/Sample.swift
    +++ b/Sample.swift
    @@ -1,2 +1,2 @@
    -let old = 1
    +let new = 2
     print(new)
    """
    var oldComment = Dieter_V1_ChangeComment()
    oldComment.id = "old"
    oldComment.side = "old"
    oldComment.line = 1
    var newComment = Dieter_V1_ChangeComment()
    newComment.id = "new"
    newComment.side = "new"
    newComment.line = 1

    let projection = WorkspaceDiffProjection.build(
        patch: patch,
        path: "Sample.swift",
        commitSHA: "",
        split: false,
        comments: [oldComment, newComment]
    )

    #expect(!projection.rows.isEmpty)
    #expect(projection.commentsByLine[.init(side: "old", line: 1)]?.map(\.id) == ["old"])
    #expect(projection.commentsByLine[.init(side: "new", line: 1)]?.map(\.id) == ["new"])
}

@Test func syntaxHighlightPlanningIsValueTypedAndBackgroundSafe() async {
    let source = "let answer: Int = 42 // meaning"
    let plan = await Task.detached {
        FileSyntaxHighlightPlanner.build(source: source, language: .swift)
    }.value

    #expect(plan.location == 0)
    #expect(plan.length == (source as NSString).length)
    #expect(plan.runs.contains { $0.style == .keywordBold })
    #expect(plan.runs.contains { $0.style == .number })
    #expect(plan.runs.contains { $0.style == .comment })
}

@Test @MainActor func terminalOutputAccumulatorCoalescesFrameBursts() async throws {
    let accumulator = TerminalOutputAccumulator(frameIntervalNanoseconds: 20_000_000)
    let recorder = TerminalPublishRecorder()
    for _ in 0..<100 {
        await accumulator.enqueue(
            terminalID: "terminal",
            data: Data("x".utf8),
            screenReset: false,
            current: TerminalScreenState()
        ) { id, screen in
            recorder.record(id: id, screen: screen)
        }
    }
    await accumulator.waitForPendingPublishes()

    #expect(recorder.publishCount == 1)
    #expect(recorder.terminalID == "terminal")
    #expect(recorder.screen.data.count == 100)
    #expect(recorder.screen.revision == 100)
}

@Test func fileEditorLineCountingDoesNotNeedAnAppKitBuffer() {
    #expect(FileEditorSession.countLines(in: "") == 1)
    #expect(FileEditorSession.countLines(in: "one\ntwo\nthree") == 3)
}

@Test @MainActor func nativeSmokeClicksUseTopRelativeCoordinatesInFlippedHostingViews() async throws {
    let recorder = NativeClickRecorder()
    let hosting = NSHostingView(rootView: Button("Press") { recorder.clicked = true }
        .frame(width: 200, height: 100))
    #expect(hosting.isFlipped)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    defer { window.close() }

    NativeUIEventDispatcher.click(window: window, x: 100, distanceFromTop: 50)
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(recorder.clicked)
}

private final class BlockingPersistenceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let firstWriteGate = DispatchSemaphore(value: 0)
    private var writes = 0

    var startedWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func write(_ value: DieterSyncDiskState, _ fileURL: URL) throws -> Int {
        lock.lock()
        writes += 1
        let write = writes
        lock.unlock()
        if write == 1 { firstWriteGate.wait() }
        return 1
    }

    func releaseFirstWrite() {
        firstWriteGate.signal()
    }
}

private final class RecordingPersistenceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor: Data?

    var lastCursor: Data? {
        lock.lock()
        defer { lock.unlock() }
        return cursor
    }

    func write(_ value: DieterSyncDiskState, _ fileURL: URL) throws -> Int {
        lock.lock()
        cursor = value.cursor
        lock.unlock()
        return value.cursor?.count ?? 0
    }
}

@MainActor
private final class TerminalPublishRecorder {
    var publishCount = 0
    var terminalID = ""
    var screen = TerminalScreenState()

    func record(id: String, screen: TerminalScreenState) {
        publishCount += 1
        terminalID = id
        self.screen = screen
    }
}

@MainActor
private final class NativeClickRecorder {
    var clicked = false
}
