import AppKit
import SwiftUI

/// Restores AppKit's standard title-bar zoom toggle when SwiftUI draws content
/// into the title bar with `.windowStyle(.hiddenTitleBar)`.
struct WindowTitleBarDoubleClickHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTitleBarDoubleClickView {
        WindowTitleBarDoubleClickView()
    }

    func updateNSView(_ nsView: WindowTitleBarDoubleClickView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowTitleBarDoubleClickView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

@MainActor
final class WindowTitleBarDoubleClickView: NSView {
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, Self.shouldZoom(for: event, in: window) else { return event }
            window.performZoom(nil)
            return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    static func shouldZoom(for event: NSEvent, in window: NSWindow) -> Bool {
        let windowButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let zoomButton = window.standardWindowButton(.zoomButton) else { return false }
        let buttonFrames = windowButtons.compactMap { type -> NSRect? in
            guard let button = window.standardWindowButton(type) else { return nil }
            return button.convert(button.bounds, to: nil)
        }
        return shouldZoom(
            eventType: event.type,
            clickCount: event.clickCount,
            eventBelongsToWindow: event.window === window,
            styleMask: window.styleMask,
            isSheet: window.isSheet,
            zoomButtonEnabled: zoomButton.isEnabled,
            zoomButtonHidden: zoomButton.isHidden,
            location: event.locationInWindow,
            contentLayoutMaxY: window.contentLayoutRect.maxY,
            windowButtonFrames: buttonFrames
        )
    }

    static func shouldZoom(
        eventType: NSEvent.EventType,
        clickCount: Int,
        eventBelongsToWindow: Bool,
        styleMask: NSWindow.StyleMask,
        isSheet: Bool,
        zoomButtonEnabled: Bool,
        zoomButtonHidden: Bool,
        location: NSPoint,
        contentLayoutMaxY: CGFloat,
        windowButtonFrames: [NSRect]
    ) -> Bool {
        guard eventType == .leftMouseDown,
              clickCount == 2,
              eventBelongsToWindow,
              styleMask.contains(.titled),
              styleMask.contains(.resizable),
              !styleMask.contains(.fullScreen),
              !isSheet,
              zoomButtonEnabled,
              !zoomButtonHidden,
              location.y >= contentLayoutMaxY
        else { return false }

        return !windowButtonFrames.contains {
            $0.insetBy(dx: -2, dy: -2).contains(location)
        }
    }
}
