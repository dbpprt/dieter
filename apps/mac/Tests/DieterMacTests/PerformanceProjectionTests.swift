import AppKit
import DieterAPI
import Foundation
import SwiftUI
import Testing
@testable import DieterMac

@Test func conversationRenderWindowBoundsTheLiveView() {
    func messages(_ count: Int) -> [Dieter_V1_UiMessage] {
        (0..<count).map { index in
            var message = Dieter_V1_UiMessage()
            message.id = "message-\(index)"
            return message
        }
    }
    let page = ConversationRenderWindow.maximumMessages
    let latest = page * ConversationRenderWindow.latestPages
    let scrollback = page * ConversationRenderWindow.scrollbackPages
    let retained = page * ConversationRenderWindow.retainedPages
    #expect(ConversationRenderWindow.range(messages: messages(20), position: .latest) == 0..<20)
    let long = messages(500)
    #expect(ConversationRenderWindow.range(messages: long, position: .latest) == (500 - latest)..<500)
    #expect(ConversationRenderWindow.range(messages: long, position: .from(messageID: "message-0")) == 0..<retained)
    #expect(
        ConversationRenderWindow.range(messages: long, position: .through(messageID: "message-499"))
            == (500 - retained)..<500)
    // An identity that left the loaded transcript falls back to the live tail.
    #expect(ConversationRenderWindow.range(messages: long, position: .from(messageID: "gone")) == (500 - latest)..<500)

    // Scrolling back grows the window by an overlapping batch and keeps the rows being read.
    let tail = ConversationRenderWindow.range(messages: long, position: .latest)
    let earlier = ConversationRenderWindow.extendingEarlier(messages: long, renderedRange: tail)
    #expect(earlier == .from(messageID: "message-\(500 - latest - scrollback)"))
    #expect(
        ConversationRenderWindow.range(messages: long, position: earlier ?? .latest)
            == (500 - latest - scrollback)..<500)
    #expect(ConversationRenderWindow.extendingEarlier(messages: long, renderedRange: 0..<page) == nil)
    #expect(ConversationRenderWindow.extendingLater(messages: long, renderedRange: tail) == nil)
    let later = ConversationRenderWindow.extendingLater(messages: long, renderedRange: 0..<retained)
    #expect(later == .through(messageID: "message-\(retained + scrollback - 1)"))
    #expect(
        ConversationRenderWindow.range(messages: long, position: later ?? .latest)
            == scrollback..<(retained + scrollback))
}

@Test(.timeLimit(.minutes(1))) @MainActor func terminalOutputAccumulatorCoalescesFrameBursts() async throws {
    let clock = TerminalFrameClock()
    let accumulator = TerminalOutputAccumulator(sleep: { _ in await clock.wait() })
    let (publishes, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { completion.finish() }
    let recorder = TerminalPublishRecorder()
    for _ in 0..<100 {
        await accumulator.enqueue(
            terminalID: "terminal",
            data: Data("x".utf8),
            screenReset: false,
            current: TerminalScreenState()
        ) { id, screen in
            recorder.record(id: id, screen: screen)
            completion.yield(())
        }
    }
    // Actor hops may span multiple real display intervals on a busy host.
    // Advance exactly one interval after all frames have been admitted.
    #expect(recorder.publishCount == 0)
    await clock.advance()
    for await _ in publishes { break }

    #expect(recorder.publishCount == 1)
    #expect(recorder.terminalID == "terminal")
    #expect(recorder.screen.data.count == 100)
    #expect(recorder.screen.revision == 100)
}

@Test func nativeSmokeClickCoordinatesRespectContentOrientation() {
    let bounds = NSRect(x: 0, y: 0, width: 200, height: 100)

    #expect(
        NativeUIEventDispatcher.contentLocation(
            x: 100,
            distanceFromTop: 20,
            contentBounds: bounds,
            isFlipped: true
        ) == NSPoint(x: 100, y: 20))
    #expect(
        NativeUIEventDispatcher.contentLocation(
            x: 100,
            distanceFromTop: 20,
            contentBounds: bounds,
            isFlipped: false
        ) == NSPoint(x: 100, y: 80))
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

private actor TerminalFrameClock {
    private var advanced = false
    private var pending: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !advanced else { return }
        await withCheckedContinuation { pending = $0 }
    }

    func advance() {
        advanced = true
        pending?.resume()
        pending = nil
    }
}
