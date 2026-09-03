import AppKit
import Testing
@testable import DieterMac

@MainActor
@Test func hiddenTitleBarDoubleClickIsRoutedToWindowZoom() {
    let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    let buttonFrames = [NSRect(x: 12, y: 612, width: 14, height: 14)]

    #expect(shouldZoom(
        clickCount: 2,
        styleMask: styleMask,
        location: NSPoint(x: 450, y: 608),
        buttonFrames: buttonFrames
    ))
    #expect(!shouldZoom(
        clickCount: 1,
        styleMask: styleMask,
        location: NSPoint(x: 450, y: 608),
        buttonFrames: buttonFrames
    ))
    #expect(!shouldZoom(
        clickCount: 2,
        styleMask: styleMask,
        location: NSPoint(x: 450, y: 592),
        buttonFrames: buttonFrames
    ))
}

@MainActor
@Test func trafficLightDoubleClickIsNotTreatedAsTitleBarZoom() {
    let zoomButtonFrame = NSRect(x: 50, y: 612, width: 14, height: 14)
    #expect(!shouldZoom(
        clickCount: 2,
        styleMask: [.titled, .resizable],
        location: NSPoint(x: zoomButtonFrame.midX, y: zoomButtonFrame.midY),
        buttonFrames: [zoomButtonFrame]
    ))
}

@MainActor
private func shouldZoom(
    clickCount: Int,
    styleMask: NSWindow.StyleMask,
    location: NSPoint,
    buttonFrames: [NSRect]
) -> Bool {
    WindowTitleBarDoubleClickView.shouldZoom(
        eventType: .leftMouseDown,
        clickCount: clickCount,
        eventBelongsToWindow: true,
        styleMask: styleMask,
        isSheet: false,
        zoomButtonEnabled: true,
        zoomButtonHidden: false,
        location: location,
        contentLayoutMaxY: 600,
        windowButtonFrames: buttonFrames
    )
}
