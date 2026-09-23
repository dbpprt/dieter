import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Testing
@testable import DieterMac

@Test @MainActor func editorPrepareBeforeAttachAndRecreationPreserveText() {
    let session = FileEditorSession()
    session.prepare(documentKey: "A:1", text: "first\nsecond")
    let first = NSTextView()
    session.attach(first, documentKey: "A:1", initialText: "first\nsecond")
    #expect(first.string == "first\nsecond")
    #expect(session.lineCount == 2)
    first.string += "\nunsaved"
    session.didEdit(lineDelta: 1)
    session.detach(first)
    let replacement = NSTextView()
    session.attach(replacement, documentKey: "A:1", initialText: "first\nsecond")
    #expect(replacement.string == "first\nsecond\nunsaved")
    #expect(session.isDirty)
    #expect(session.lineCount == 3)
    // Dismantling the previous native view after the new one attached is harmless.
    session.detach(first)
    #expect(session.currentText() == replacement.string)
    session.markSaved(documentKey: "A:1", submittedText: replacement.string, editRevision: session.revision)
    let afterSave = NSTextView()
    session.attach(afterSave, documentKey: "A:1", initialText: replacement.string)
    #expect(afterSave.string == "first\nsecond\nunsaved")
    #expect(!session.isDirty)
    session.prepare(documentKey: "B:1", text: "another file")
    #expect(afterSave.string == "another file")
    session.prepare(documentKey: "A:1", text: "first\nsecond\nunsaved")
    #expect(session.currentText() == "first\nsecond\nunsaved")
}

private actor DelayedReadProbe {
    var calls: [String] = []
    var cancellations: [String] = []
    func read(_ key: String, delay: Int) async throws -> String {
        calls.append(key)
        do { try await Task.sleep(for: .milliseconds(delay)) } catch { cancellations.append(key); throw error }
        return key
    }
}

@Test @MainActor func ownedReadsShareTransportAndCancelSupersededTargets() async throws {
    let reader = OwnedRead<String>()
    let probe = DelayedReadProbe()
    let first = Task { try await reader.value(key: "A") { try await probe.read("A", delay: 1_000) } }
    while await probe.calls.isEmpty { await Task.yield() }
    let duplicate = Task { try await reader.value(key: "A") { try await probe.read("duplicate", delay: 1_000) } }
    await Task.yield()
    let second = Task { try await reader.value(key: "B") { try await probe.read("B", delay: 50) } }
    #expect(try await second.value == "B")
    do { _ = try await first.value; Issue.record("Superseded read published") } catch {}
    do { _ = try await duplicate.value; Issue.record("Superseded duplicate published") } catch {}
    #expect(await probe.calls == ["A", "B"])
    #expect(await probe.cancellations == ["A"])
    #expect(try await reader.value(key: "A") { try await probe.read("A", delay: 50) } == "A")
}

private actor DelayedScheduleRPC: DieterScheduleRPC {
    var calls = 0
    var fail = false
    let delay: Int
    init(delay: Int) { self.delay = delay }
    func setFailure(_ value: Bool) { fail = value }
    func schedules(projectID: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_SchedulesResponse {
        calls += 1
        let shouldFail = fail
        // Deliberately ignore transport cancellation to test the publication guard.
        try? await Task.sleep(for: .milliseconds(delay))
        if shouldFail { throw RPCError(code: .unavailable, message: "Fixture unavailable") }
        var response = Dieter_V1_SchedulesResponse()
        var schedule = Dieter_V1_Schedule()
        schedule.id = "schedule-\(projectID)"
        schedule.projectID = projectID
        response.schedules = [schedule]
        return response
    }
    func scheduleRuns(id: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_ScheduleRunsResponse {
        Dieter_V1_ScheduleRunsResponse()
    }
}

@Test(arguments: [50, 250, 1_000]) @MainActor func scheduleLoadsAcknowledgeImmediatelyCoalesceAndRecover(_ delay: Int)
    async throws
{
    let rpc = DelayedScheduleRPC(delay: delay)
    let store = DieterStore(scheduleRPCOverride: rpc, restoreSync: false)
    store.selectedProjectID = "A"
    await rpc.setFailure(true)
    let start = Task { await store.loadSchedules() }
    while await rpc.calls == 0 { await Task.yield() }
    #expect(store.schedulesLoading)
    let duplicate = Task { await store.loadSchedules() }
    await start.value
    await duplicate.value
    #expect(await rpc.calls == 1)
    #expect(!store.schedulesLoading)
    #expect(store.schedulesError?.contains("Fixture unavailable") == true)
    #expect(
        SchedulesPresentationState.resolve(
            isLoaded: false, isLoading: false, hasSchedules: false, error: store.schedulesError)
            == .failed(store.schedulesError!))
    await rpc.setFailure(false)
    await store.loadSchedules()
    #expect(store.schedulesError == nil)
    #expect(store.schedulesAreLoaded)
    let old = Task { await store.loadSchedules() }
    while await rpc.calls < 3 { await Task.yield() }
    store.selectedProjectID = "B"
    let newest = Task { await store.loadSchedules() }
    await old.value
    await newest.value
    #expect(store.schedules.map(\.id) == ["schedule-B"])
    #expect(!store.schedulesLoading)
}

@Test func snapshotDecoderInvalidatesSerializedIdentityAndIndexesConversations() async throws {
    let decoder = DieterSnapshotDecoder()
    var snapshot = Dieter_V1_GlobalSnapshot()
    for index in 0..<24 {
        var conversation = Dieter_V1_ConversationSnapshot()
        conversation.detail.card.id = "card-\(index)"
        conversation.detail.card.title = "original"
        snapshot.conversations.append(conversation)
    }
    let first = try snapshot.serializedData()
    #expect(
        await decoder.conversation(cardID: "card-23", endpointID: "A", data: first)?.detail.card.title == "original")
    snapshot.conversations[23].detail.card.title = "new"
    let second = try snapshot.serializedData()
    #expect(await decoder.conversation(cardID: "card-23", endpointID: "A", data: second)?.detail.card.title == "new")
    #expect(
        await decoder.conversation(cardID: "card-23", endpointID: "B", data: first)?.detail.card.title == "original")
    #expect(await decoder.snapshot(endpointID: "A", data: Data([255])) == nil)
}

@Test func markdownPreparationRunsOffMainAndBoundsEagerContent() async throws {
    let source =
        "| First | Second |\n| --- | --- |\n" + (0..<100).map { "| row \($0) | **value** |" }.joined(separator: "\n")
    let result = try await BackgroundPreparation.run { () -> (Bool, [ConversationMarkdownBlock]) in
        (Thread.isMainThread, try ConversationRenderCache.prepare(source))
    }
    #expect(!result.0)
    guard case .table(let table) = result.1.first else { Issue.record("Table not parsed"); return }
    #expect(table.rows.count == 100)
    #expect(table.columnWidths.count == 2)
    #expect(table.columnWidths.allSatisfy { $0 >= 80 && $0 <= 220 })
    #expect(ConversationRenderCache.cachedBlocks(source) == result.1)
    var message = Dieter_V1_UiMessage()
    var part = Dieter_V1_MessagePart()
    part.type = "text"
    part.text = String(repeating: "x", count: 10_000)
    message.parts = [part]
    let messages = (0..<180).map { index in
        var copy = message
        copy.id = "message-\(index)"
        return copy
    }
    let tail = ConversationRenderWindow.range(messages: messages, position: .latest)
    #expect(tail.upperBound == 180)
    #expect(tail.count == 9)
    // Six retained pages of 32 KB hold nineteen 10 KB messages.
    let earlier = ConversationRenderWindow.range(messages: messages, position: .from(messageID: "message-0"))
    #expect(earlier == 0..<19)
    let pagedEarlier = ConversationRenderWindow.extendingEarlier(messages: messages, renderedRange: 100..<101)
    #expect(pagedEarlier == .from(messageID: "message-94"))
    let pagedLater = ConversationRenderWindow.extendingLater(messages: messages, renderedRange: 100..<101)
    #expect(pagedLater == .through(messageID: "message-106"))
    #expect(
        ConversationRenderWindow.range(messages: messages, position: pagedLater ?? .latest)
            == 88..<107)
}

@Test(arguments: ["text bytes", "message parts", "message count"])
func detachedConversationRenderWindowRetainsReadMessagesWhenTheTailAdvances(budget: String) {
    let originalCount: Int
    switch budget {
    case "text bytes": originalCount = 17
    case "message parts": originalCount = 13
    default: originalCount = ConversationRenderWindow.maximumMessages * ConversationRenderWindow.latestPages + 1
    }
    let textLength = budget == "text bytes" ? 6_000 : 1
    let partCount = budget == "message parts" ? 60 : 1
    func message(_ index: Int) -> Dieter_V1_UiMessage {
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text = String(repeating: "x", count: textLength)
        var message = Dieter_V1_UiMessage()
        message.id = "message-\(index)"
        message.role = "assistant"
        message.parts = Array(repeating: part, count: partCount)
        return message
    }
    var messages = (0..<originalCount).map(message)
    let readingRange = ConversationRenderWindow.range(messages: messages, position: .latest)
    let readingIDs = messages[readingRange].map(\.id)
    #expect(readingRange.lowerBound > 0)

    // Scrolling away pins the displayed start before another answer arrives.
    // Appends must not replace those rows just because the live tail exceeds a
    // rendering budget; changing only the scroll offset cannot prevent that.
    let pinnedPosition = ConversationRenderWindow.detached(
        from: .latest, messages: messages, renderedRange: readingRange)
    #expect(pinnedPosition == .from(messageID: readingIDs[0]))
    for index in originalCount..<(originalCount + 3) {
        messages.append(message(index))
        let latest = ConversationRenderWindow.range(messages: messages, position: .latest)
        let pinned = ConversationRenderWindow.range(messages: messages, position: pinnedPosition)
        #expect(latest.lowerBound > readingRange.lowerBound)
        #expect(latest.upperBound == messages.count)
        #expect(pinned.lowerBound == readingRange.lowerBound)
        #expect(Array(messages[pinned].map(\.id).prefix(readingIDs.count)) == readingIDs)
        let pages = ConversationRenderWindow.retainedPages
        #expect(pinned.count <= ConversationRenderWindow.maximumMessages * pages)
        #expect(messages[pinned].reduce(0) { $0 + $1.parts.count } <= ConversationRenderWindow.maximumParts * pages)
        #expect(
            messages[pinned].flatMap(\.parts).reduce(0) { $0 + $1.text.utf8.count }
                <= ConversationRenderWindow.maximumTextBytes * pages)
    }
    // Prepended history shifts every index; the pinned identity does not move.
    let shifted = [message(-1)] + messages
    #expect(
        ConversationRenderWindow.range(messages: shifted, position: pinnedPosition).lowerBound
            == readingRange.lowerBound + 1)
    // Jump to latest releases the pin and restores the bounded current tail.
    let resumed = ConversationRenderWindow.range(messages: messages, position: .latest)
    #expect(messages[resumed].last?.id == messages.last?.id)
    #expect(resumed.lowerBound > readingRange.lowerBound)
}
