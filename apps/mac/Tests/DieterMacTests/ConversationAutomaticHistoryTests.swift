import DieterAPI
import Foundation
import SharedCore
import Testing
@testable import DieterMac

private func automaticHistoryMessage(_ index: Int) -> Dieter_V1_UiMessage {
    fixtureMessage("message-\(index)", text: "Message \(index)")
}

/// The core pages history; the model shows it as earlier messages ahead of
/// the live window and reports a page once the update carrying it arrives.
@MainActor private final class HistoryCore {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    var earlier: Range<Int>
    let live: Range<Int>
    var browsing = false

    init(earlier: Range<Int>, live: Range<Int>) {
        self.earlier = earlier
        self.live = live
        model.core = core
        model.selectedChatID = "chat"
        model.observe("chat")
        publish()
    }

    func publish() {
        core.emitConversation("chat") { slice in
            slice.messages = (Array(earlier) + Array(live)).map(automaticHistoryMessage)
            slice.earlierCount = Int32(earlier.count)
            slice.page = .with {
                $0.start = Int32(live.lowerBound)
                $0.end = Int32(live.upperBound)
                $0.total = Int32(live.upperBound)
            }
            slice.hasEarlier_p = (earlier.isEmpty ? live.lowerBound : earlier.lowerBound) > 0
            slice.browsingEarlier = browsing
        }
    }
}

@Test @MainActor func historyPagesExtendOnceTheirUpdateArrivesAndReturnToTheLiveWindow() async {
    let fixture = HistoryCore(earlier: 3_000..<3_000, live: 3_000..<3_030)
    let model = fixture.model
    #expect(model.conversationMessages.map(\.id) == (3_000..<3_030).map { "message-\($0)" })
    #expect(model.olderConversationMessages.isEmpty)
    #expect(model.conversationHistoryHasMore)

    // The core publishes the page before it answers.
    fixture.core.asyncHandler = { command in
        guard case .loadEarlierMessages = command.command else { return .with { $0.done = ClientDone() } }
        fixture.earlier = 2_940..<3_000
        fixture.publish()
        return .with { $0.pageLoaded = .with { $0.loaded = true } }
    }
    #expect(await model.loadEarlierMessages())
    #expect(model.olderConversationMessages.map(\.id) == (2_940..<3_000).map { "message-\($0)" })
    #expect(model.conversation?.conversation.messages.count == 30, "the live window stays separate")

    // An update that lands after the reply is still awaited.
    fixture.core.asyncHandler = { command in
        guard case .loadEarlierMessages = command.command else { return .with { $0.done = ClientDone() } }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            fixture.earlier = 2_880..<3_000
            fixture.browsing = true
            fixture.publish()
        }
        return .with { $0.pageLoaded = .with { $0.loaded = true } }
    }
    #expect(await model.loadEarlierMessages())
    #expect(model.olderConversationMessages.count == 120)
    #expect(model.browsingEarlierHistory)

    // Nothing more to load answers at once.
    fixture.core.asyncHandler = { _ in .with { $0.pageLoaded = .with { $0.loaded = false } } }
    #expect(!(await model.loadLaterMessages()))

    model.returnToLatest()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.core.commands.contains { if case .returnToLatest = $0.command { true } else { false } })
    fixture.earlier = 3_000..<3_000
    fixture.browsing = false
    fixture.publish()
    #expect(model.olderConversationMessages.isEmpty)
    #expect(!model.browsingEarlierHistory)
    #expect(model.conversationMessages.map(\.id) == (3_000..<3_030).map { "message-\($0)" })
    model.observe(nil)
}

@Test @MainActor func aPageForAConversationNoLongerShownIsNotReported() async {
    let fixture = HistoryCore(earlier: 60..<60, live: 60..<90)
    let model = fixture.model
    var release: CheckedContinuation<Void, Never>?
    fixture.core.asyncHandler = { _ in
        await withCheckedContinuation { release = $0 }
        return .with { $0.pageLoaded = .with { $0.loaded = true } }
    }
    let request = Task { await model.loadEarlierMessages() }
    for _ in 0..<1_000 where release == nil { await Task.yield() }
    #expect(release != nil)
    model.observe(nil)
    release?.resume()
    #expect(!(await request.value))
}
