import AppKit
import XCTest
@testable import DieterMac

final class WindowTitleBarDoubleClickTests: XCTestCase {
    func testHiddenTitleBarDoubleClickIsRoutedToWindowZoom() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let buttonFrames = [NSRect(x: 12, y: 612, width: 14, height: 14)]

        XCTAssertTrue(shouldZoom(
            clickCount: 2,
            styleMask: styleMask,
            location: NSPoint(x: 450, y: 608),
            buttonFrames: buttonFrames
        ))
        XCTAssertFalse(shouldZoom(
            clickCount: 1,
            styleMask: styleMask,
            location: NSPoint(x: 450, y: 608),
            buttonFrames: buttonFrames
        ))
        XCTAssertFalse(shouldZoom(
            clickCount: 2,
            styleMask: styleMask,
            location: NSPoint(x: 450, y: 592),
            buttonFrames: buttonFrames
        ))
    }

    func testTrafficLightDoubleClickIsNotTreatedAsTitleBarZoom() {
        let zoomButtonFrame = NSRect(x: 50, y: 612, width: 14, height: 14)
        XCTAssertFalse(shouldZoom(
            clickCount: 2,
            styleMask: [.titled, .resizable],
            location: NSPoint(x: zoomButtonFrame.midX, y: zoomButtonFrame.midY),
            buttonFrames: [zoomButtonFrame]
        ))
    }
}

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
