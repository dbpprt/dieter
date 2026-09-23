import AppKit
import Testing
@testable import DieterMac

@Test @MainActor func boardDoubleClickRetainsOriginalActionOnlyForMatchingSecondClick() throws {
    func event(
        _ type: NSEvent.EventType = .leftMouseDown, window: Int = 42, count: Int = 2,
        point: NSPoint = NSPoint(x: 200, y: 200), elapsed: Double = 0.1
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 10 + elapsed,
                windowNumber: window, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }
    let tracker = BoardCardDoubleClickTracker()
    defer { tracker.cancel() }
    var edits = 0
    let first = try event(.leftMouseUp, count: 1, elapsed: 0)
    tracker.arm(after: first) { edits += 1 }
    #expect(tracker.filter(try event()) == nil)
    #expect(edits == 1)
    // No retained action can run a second time.
    let third = try event(count: 3)
    #expect(tracker.filter(third) === third)
    #expect(edits == 1)

    for other in [
        try event(window: 43), try event(count: 1), try event(point: NSPoint(x: 300, y: 200)),
        try event(elapsed: NSEvent.doubleClickInterval + 0.1), try event(.rightMouseDown),
    ] {
        tracker.arm(after: first) { edits += 1 }
        #expect(tracker.filter(other) === other)
        #expect(edits == 1)
        // An intervening unrelated event cancels the remembered target.
        let second = try event()
        #expect(tracker.filter(second) === second)
    }
    tracker.arm(after: nil) { edits += 1 }
    let keyboardActivation = try event()
    #expect(tracker.filter(keyboardActivation) === keyboardActivation)
    #expect(edits == 1)
}

@Test @MainActor func boardDoubleClickUsesInputTimestampsWhenLayoutDelaysDelivery() async throws {
    let tracker = BoardCardDoubleClickTracker()
    defer { tracker.cancel() }
    var edits = 0
    let first = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 10,
            windowNumber: 42, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    let second = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: first.locationInWindow, modifierFlags: [], timestamp: 10.1,
            windowNumber: 42, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
    tracker.arm(after: first) { edits += 1 }
    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
    #expect(tracker.filter(second) == nil)
    #expect(edits == 1)
}
