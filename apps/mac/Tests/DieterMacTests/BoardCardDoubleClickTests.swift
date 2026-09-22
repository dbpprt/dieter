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
