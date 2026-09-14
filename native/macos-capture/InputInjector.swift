import AppKit
import CoreGraphics
import Foundation

// All calls are serialized by the helper's input queue. Dry-run is used only by
// native protocol fixtures and never posts to the operator's desktop.
final class InputInjector: @unchecked Sendable {
    private(set) var bounds: CGRect
    private let source = CGEventSource(stateID: .privateState)
    private(set) var position: CGPoint
    private(set) var heldButtons = Set<Int32>()
    private(set) var heldKeys = Set<UInt16>()
    private(set) var lastOrdinal: UInt64 = 0
    private(set) var generation: UInt64 = 1
    private var modifiers: UInt32 = 0
    private var scrollX = 0.0
    private var scrollY = 0.0
    let dryRun: Bool

    init(bounds: CGRect, dryRun: Bool = false) {
        self.bounds = bounds
        position = CGPoint(x: bounds.midX, y: bounds.midY)
        self.dryRun = dryRun
    }
    func update(bounds: CGRect, generation: UInt64) {
        releaseAll()
        self.bounds = bounds
        self.generation = generation
        position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    func handle(_ v: NativeInput) throws {
        if v.kind == "release_all" { releaseAll(); return }
        guard v.generation == generation || (v.generation == 0 && dryRun) else {
            throw CaptureError.invalidArgument("stale input display")
        }
        lastOrdinal = max(lastOrdinal, v.ordinal)
        switch v.kind {
        case "pointer_move":
            position = try point(v)
            let button = heldButtons.sorted().first ?? 1
            let type: CGEventType =
                heldButtons.isEmpty
                ? .mouseMoved
                : (button == 1 ? .leftMouseDragged : button == 2 ? .rightMouseDragged : .otherMouseDragged)
            mouse(type, button, 0)
        case "pointer_button":
            guard (1...5).contains(v.button) else { throw CaptureError.invalidArgument("button") }
            position = try point(v)
            modifiers = v.modifiers
            if v.down { heldButtons.insert(v.button) } else { heldButtons.remove(v.button) }
            mouse(
                v.button == 1
                    ? (v.down ? .leftMouseDown : .leftMouseUp)
                    : v.button == 2
                        ? (v.down ? .rightMouseDown : .rightMouseUp) : (v.down ? .otherMouseDown : .otherMouseUp),
                v.button, Int(v.clickCount))
        case "scroll":
            guard v.deltaX.isFinite, v.deltaY.isFinite, abs(v.deltaX) <= 100000, abs(v.deltaY) <= 100000 else {
                throw CaptureError.invalidArgument("scroll")
            }
            modifiers = v.modifiers
            scrollX += v.deltaX; scrollY += v.deltaY
            let dx = Int32(scrollX.rounded(.towardZero)); let dy = Int32(scrollY.rounded(.towardZero))
            scrollX -= Double(dx); scrollY -= Double(dy)
            if let event = CGEvent(
                scrollWheelEvent2Source: source, units: v.precise ? .pixel : .line, wheelCount: 2, wheel1: dy,
                wheel2: dx, wheel3: 0)
            {
                event.flags = flags()
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: v.precise ? 1 : 0)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(v.phase))
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(v.momentumPhase))
                post(event)
            }
        case "key":
            let code = v.physicalKey == 0 ? UInt16(exactly: v.keyCode) : RemoteDesktopKeyMap.hidToMac[v.physicalKey]
            guard let code, code <= 255 else { throw CaptureError.invalidArgument("physical key") }
            modifiers = v.modifiers
            if v.down { heldKeys.insert(code) } else { heldKeys.remove(code) }
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: v.down) {
                event.flags = flags()
                event.setIntegerValueField(.keyboardEventAutorepeat, value: v.repeat ? 1 : 0)
                post(event)
            }
        case "text":
            let text = Array(v.text.utf16)
            guard !text.isEmpty, text.count <= 1024 else { throw CaptureError.invalidArgument("text") }
            // Send committed text as Unicode; shortcuts remain physical key events.
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) {
                    text.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    post(event)
                }
            }
        default: throw CaptureError.invalidArgument("input kind")
        }
    }
    func releaseAll() {
        modifiers = 0
        for key in heldKeys.sorted() {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
                event.flags = []; post(event)
            }
        }
        heldKeys.removeAll()
        for button in heldButtons.sorted() {
            mouse(button == 1 ? .leftMouseUp : button == 2 ? .rightMouseUp : .otherMouseUp, button, 1)
        }
        heldButtons.removeAll()
        scrollX = 0; scrollY = 0
    }
    private func point(_ v: NativeInput) throws -> CGPoint {
        guard (0...1_000_000).contains(v.x), (0...1_000_000).contains(v.y) else {
            throw CaptureError.invalidArgument("coordinate")
        }
        return CGPoint(
            x: bounds.minX + min(bounds.width - 0.001, bounds.width * Double(v.x) / 1_000_000),
            y: bounds.minY + min(bounds.height - 0.001, bounds.height * Double(v.y) / 1_000_000))
    }
    private func mouse(_ type: CGEventType, _ button: Int32, _ clicks: Int) {
        if let b = CGMouseButton(rawValue: UInt32(button - 1)),
            let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: b)
        {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(0, min(3, clicks))))
            event.flags = flags(); post(event)
        }
    }
    private func post(_ event: CGEvent) { if !dryRun { event.post(tap: .cgSessionEventTap) } }
    private func flags() -> CGEventFlags {
        var result: CGEventFlags = []
        for (mask, flag): (UInt32, CGEventFlags) in [
            (1, .maskShift), (2, .maskControl), (4, .maskAlternate), (8, .maskCommand), (16, .maskAlphaShift),
            (32, .maskSecondaryFn),
        ] {
            if modifiers & mask != 0 { result.insert(flag) }
        }
        return result
    }
}
