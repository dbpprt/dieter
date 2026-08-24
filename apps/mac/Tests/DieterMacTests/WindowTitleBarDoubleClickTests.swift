import AppKit
import Testing
@testable import DieterMac

@MainActor
@Test func hiddenTitleBarDoubleClickIsRoutedToWindowZoom() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true

    let titleBarPoint = NSPoint(x: window.contentLayoutRect.midX, y: window.contentLayoutRect.maxY + 8)
    let contentPoint = NSPoint(x: window.contentLayoutRect.midX, y: window.contentLayoutRect.maxY - 8)

    #expect(WindowTitleBarDoubleClickView.shouldZoom(
        for: try #require(mouseEvent(in: window, at: titleBarPoint, clickCount: 2)),
        in: window
    ))
    #expect(!WindowTitleBarDoubleClickView.shouldZoom(
        for: try #require(mouseEvent(in: window, at: titleBarPoint, clickCount: 1)),
        in: window
    ))
    #expect(!WindowTitleBarDoubleClickView.shouldZoom(
        for: try #require(mouseEvent(in: window, at: contentPoint, clickCount: 2)),
        in: window
    ))
}

@MainActor
@Test func trafficLightDoubleClickIsNotTreatedAsTitleBarZoom() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    let zoomButton = try #require(window.standardWindowButton(.zoomButton))
    let zoomButtonPoint = zoomButton.convert(
        NSPoint(x: zoomButton.bounds.midX, y: zoomButton.bounds.midY),
        to: nil
    )

    #expect(!WindowTitleBarDoubleClickView.shouldZoom(
        for: try #require(mouseEvent(in: window, at: zoomButtonPoint, clickCount: 2)),
        in: window
    ))
}

@MainActor
private func mouseEvent(in window: NSWindow, at point: NSPoint, clickCount: Int) -> NSEvent? {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1
    )
}
